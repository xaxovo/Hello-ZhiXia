/// 仓储：把「操作日志 + 快照」包装成界面可以直接用的读写门面。
///
/// 所有写入都遵循同一条路径：**先落盘，再改内存状态，最后通知界面**。
/// 顺序不能反 —— 否则界面会显示一条实际上没有持久化成功的改动。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/hlc.dart';
import '../core/op.dart';
import '../core/op_store.dart';
import '../core/snapshot.dart';
import '../core/ulid.dart';
import 'entry.dart';
import 'ops.dart';

final class HxzRepository extends ChangeNotifier {
  HxzRepository._(this._store, this._clock, this._ulids, this._state, this._ops, this._snapshot);

  /// 日志条数超过这个值就压缩一次。
  static const int _compactThreshold = 200;

  /// 压缩后保留的尾部条数。留一小段历史便于排查，也保留了出问题时的恢复窗口。
  static const int _keepTail = 20;

  final OpStore _store;
  final HybridLogicalClock _clock;
  final UlidGenerator _ulids;

  Map<String, Object?> _state;
  List<Op> _ops;
  Snapshot? _snapshot;

  /// 打开（或初始化）一个数据目录。
  static Future<HxzRepository> open(Directory directory) async {
    final store = OpStore(directory);
    await store.ensureReady();

    final deviceId = await _loadOrCreateDeviceId(directory);
    final snapshot = await store.readSnapshot();
    final ops = await store.readOps();

    final state = restoreState(snapshot, ops, applyOp);

    final clock = HybridLogicalClock(deviceId: deviceId);
    final latest = OpStore.latestHlc(ops);
    if (latest != null) clock.observe(latest);

    return HxzRepository._(store, clock, UlidGenerator(), state, ops, snapshot);
  }

  // ---------------------------------------------------------------- 读取

  /// 全部条目，按更新时间倒序。
  List<Entry> get entries {
    final raw = (_state['entries'] as Map?) ?? const {};
    final list = raw.values
        .whereType<Map<String, Object?>>()
        .map(Entry.fromJson)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  List<Entry> byKind(EntryKind kind) => entries.where((e) => e.kind == kind).toList();

  /// 今天需要关注的东西：未完成的待办 + 今天到期的提醒。
  List<Entry> get today {
    final now = DateTime.now();
    final endOfDay = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    return entries.where((entry) {
      switch (entry.kind) {
        case EntryKind.task:
          if (entry.done) return false;
          final due = entry.dueAt;
          return due == null || due.isBefore(endOfDay);
        case EntryKind.reminder:
          if (entry.done) return false;
          final at = entry.dueAt;
          return at != null && at.isBefore(endOfDay);
        case EntryKind.note:
          return false;
      }
    }).toList()
      ..sort((a, b) {
        final da = a.dueAt;
        final db = b.dueAt;
        if (da == null && db == null) return b.updatedAt.compareTo(a.updatedAt);
        if (da == null) return 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });
  }

  int get opCount => _ops.length;

  // ---------------------------------------------------------------- 写入

  Future<Entry> create({
    required EntryKind kind,
    required String title,
    String body = '',
    DateTime? dueAt,
  }) async {
    final id = _ulids.next();
    final hlc = _clock.tick();
    await _emit(Op(
      opId: _ulids.next(),
      hlc: hlc,
      entityId: id,
      type: OpTypes.create,
      payload: {
        'kind': kind.id,
        'title': title.trim(),
        'body': body,
        'done': false,
        'dueAt': dueAt?.millisecondsSinceEpoch,
        'createdAt': hlc.wall,
      },
    ));
    return _find(id)!;
  }

  Future<void> update(
    String id, {
    String? title,
    String? body,
    bool? done,
    DateTime? dueAt,
    bool clearDueAt = false,
  }) async {
    final patch = <String, Object?>{};
    if (title != null) patch['title'] = title.trim();
    if (body != null) patch['body'] = body;
    if (done != null) patch['done'] = done;
    if (clearDueAt) {
      patch['dueAt'] = null;
    } else if (dueAt != null) {
      patch['dueAt'] = dueAt.millisecondsSinceEpoch;
    }
    if (patch.isEmpty) return;

    await _emit(Op(
      opId: _ulids.next(),
      hlc: _clock.tick(),
      entityId: id,
      type: OpTypes.update,
      payload: patch,
    ));
  }

  Future<void> delete(String id) async {
    if (_find(id) == null) return;
    await _emit(Op(
      opId: _ulids.next(),
      hlc: _clock.tick(),
      entityId: id,
      type: OpTypes.delete,
      payload: const {},
    ));
  }

  // ---------------------------------------------------------------- 内部

  Entry? _find(String id) {
    final raw = (_state['entries'] as Map?) ?? const {};
    final json = raw[id];
    return json is Map ? Entry.fromJson(Map<String, Object?>.from(json)) : null;
  }

  Future<void> _emit(Op op) async {
    await _store.append(op);
    _ops = [..._ops, op];
    _state = applyOp(_state, op);
    notifyListeners();
    await _maybeCompact();
  }

  /// 日志够长时压缩一次。
  ///
  /// 注意这里**必须**把 `base: _snapshot` 传进去。省略它会让每次压缩都从空状态
  /// 重新折叠，从而丢掉上一次压缩已经折进去的历史 —— 这是不可恢复的数据丢失。
  Future<void> _maybeCompact() async {
    if (_ops.length <= _compactThreshold + _keepTail) return;

    final frontier = _ops[_ops.length - _keepTail - 1].hlc;
    final snapshot = compactedSnapshot(
      base: _snapshot,
      ops: _ops,
      frontier: frontier,
      reduce: applyOp,
      schemaVersion: currentSchemaVersion,
    );
    final tail = opsAbove(_ops, frontier);

    await _store.compact(snapshot, tail);

    _snapshot = snapshot;
    _ops = tail;
  }

  static Future<String> _loadOrCreateDeviceId(Directory directory) async {
    final file = File('${directory.path}${Platform.pathSeparator}device_id');
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    final id = UlidGenerator().next();
    await file.writeAsString(id, flush: true);
    return id;
  }
}
