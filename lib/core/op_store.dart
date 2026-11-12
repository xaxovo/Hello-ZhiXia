/// 操作日志的落盘实现。
///
/// 存储形态刻意做得极简：一个只追加的 `ops.jsonl` 加一份 `snapshot.json`。
/// 不引入数据库，因为这个规模下它的收益远小于它带来的依赖与迁移负担；
/// 需要换成 SQLite 时，只要替换本文件里的读写实现，上层契约不变。
///
/// 三条必须守住的规则：
/// 1. **先写快照，再截断日志** —— 顺序反了，中途崩溃就会丢数据
/// 2. **加载时过滤掉快照已覆盖的操作** —— 这样即使截断没做完也不会重复施加
/// 3. **容忍末尾的残缺行** —— 断电可能只写了半行 JSON，不能因此读不出全部数据
library;

import 'dart:convert';
import 'dart:io';

import 'hlc.dart';
import 'op.dart';
import 'snapshot.dart';

final class OpStore {
  OpStore(this.directory);

  final Directory directory;

  File get _logFile => File('${directory.path}${Platform.pathSeparator}ops.jsonl');
  File get _snapshotFile => File('${directory.path}${Platform.pathSeparator}snapshot.json');

  Future<void> ensureReady() => directory.create(recursive: true);

  /// 读快照。不存在或损坏时返回 `null`（等价于「从零重建」）。
  Future<Snapshot?> readSnapshot() async {
    if (!await _snapshotFile.exists()) return null;
    try {
      final raw = await _snapshotFile.readAsString();
      if (raw.trim().isEmpty) return null;
      return Snapshot.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on FormatException {
      return null;
    }
  }

  /// 读全部操作。单行损坏（例如断电截断）只跳过该行，不放弃整个文件。
  Future<List<Op>> readOps() async {
    if (!await _logFile.exists()) return const [];
    final lines = await _logFile.readAsLines();
    final ops = <Op>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        ops.add(Op.fromJson(jsonDecode(line) as Map<String, Object?>));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return sortOps(ops);
  }

  /// 追加一条操作，立即刷盘。返回后即可认为该操作已经持久化。
  Future<void> append(Op op) async {
    await ensureReady();
    final raf = await _logFile.open(mode: FileMode.append);
    try {
      await raf.writeString('${jsonEncode(op.toJson())}\n');
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// 压缩：**先写快照，再原子替换日志**。
  ///
  /// [snapshot] 必须是通过 `compactedSnapshot(base: 上一份快照, ...)` 得到的，
  /// 否则会丢掉更早的状态。这里不做校验，因为校验只能靠类型而不是运行期。
  Future<void> compact(Snapshot snapshot, List<Op> tail) async {
    await ensureReady();
    await _writeAtomically(_snapshotFile, jsonEncode(snapshot.toJson()));

    final buffer = StringBuffer();
    for (final op in sortOps(tail)) {
      buffer.writeln(jsonEncode(op.toJson()));
    }
    await _writeAtomically(_logFile, buffer.toString());
  }

  /// 写出到临时文件再 rename —— 保证任何时刻磁盘上的文件都是完整的。
  Future<void> _writeAtomically(File target, String content) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(target.path);
  }

  /// 启动时把时钟追赶到日志里的最大时间戳，保证新写入排在历史之后。
  static Hlc? latestHlc(Iterable<Op> ops) {
    Hlc? latest;
    for (final op in ops) {
      if (latest == null || op.hlc.compareTo(latest) > 0) latest = op.hlc;
    }
    return latest;
  }
}
