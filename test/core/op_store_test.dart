import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/core/op.dart';
import 'package:hello_zhixia/core/op_store.dart';
import 'package:hello_zhixia/core/snapshot.dart';

import '../support/factories.dart';

Map<String, Object?> counterReducer(Map<String, Object?> state, Op op) {
  final counts = Map<String, Object?>.from((state['counts'] as Map?) ?? const {});
  if (op.type == 'entry.create') {
    counts[op.entityId] = 1;
  } else if (op.type == 'entry.update') {
    counts[op.entityId] = ((counts[op.entityId] as int?) ?? 0) + 1;
  }
  return {'counts': counts};
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('hzx_store_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('追加的操作能原样读回，且按全序排列', () async {
    final store = OpStore(directory);
    await store.append(createOp(id: 'b', at: hlc(2000), title: 'B'));
    await store.append(createOp(id: 'a', at: hlc(1000), title: 'A'));

    final ops = await store.readOps();

    expect(ops.map((op) => op.entityId), ['a', 'b']);
  });

  test('末尾残缺行被跳过，其余数据照常读出', () async {
    final store = OpStore(directory);
    await store.append(createOp(id: 'a', at: hlc(1000), title: 'A'));

    // 模拟断电：只写出了半行 JSON
    final log = File('${directory.path}${Platform.pathSeparator}ops.jsonl');
    await log.writeAsString('{"opId":"half', mode: FileMode.append);

    final ops = await store.readOps();
    expect(ops.length, 1, reason: '一行损坏不应该让整份历史读不出来');
  });

  test('损坏的快照文件退化为「从零重建」而不是启动失败', () async {
    final store = OpStore(directory);
    await File('${directory.path}${Platform.pathSeparator}snapshot.json')
        .writeAsString('not json at all');

    expect(await store.readSnapshot(), isNull);
  });

  test('压缩之后重建的状态与从未压缩过完全一致', () async {
    final store = OpStore(directory);
    final ops = [
      createOp(id: 'a', at: hlc(1000), title: 'A'),
      createOp(id: 'b', at: hlc(2000), title: 'B'),
      updateOp(id: 'a', at: hlc(3000), patch: const {'title': 'A2'}),
      updateOp(id: 'a', at: hlc(4000), patch: const {'title': 'A3'}),
    ];
    for (final op in ops) {
      await store.append(op);
    }

    final expected = restoreState(null, ops, counterReducer);

    final snapshot = compactedSnapshot(
      base: null,
      ops: ops,
      frontier: hlc(3000),
      reduce: counterReducer,
      schemaVersion: 1,
    );
    await store.compact(snapshot, opsAbove(ops, hlc(3000)));

    final reloadedSnapshot = await store.readSnapshot();
    final reloadedOps = await store.readOps();
    final actual = restoreState(reloadedSnapshot, reloadedOps, counterReducer);

    expect(reloadedOps.length, 1, reason: '只应剩下 frontier 之上的那一条');
    expect(actual, expected);
  });

  test('压缩两次之后状态依然完整（可重入）', () async {
    final store = OpStore(directory);
    final ops = [
      createOp(id: 'a', at: hlc(1000), title: 'A'),
      createOp(id: 'b', at: hlc(2000), title: 'B'),
      updateOp(id: 'a', at: hlc(3000), patch: const {'title': 'A2'}),
      updateOp(id: 'b', at: hlc(4000), patch: const {'title': 'B2'}),
    ];
    final expected = restoreState(null, ops, counterReducer);

    for (final op in ops.take(2)) {
      await store.append(op);
    }
    final first = compactedSnapshot(
      base: null,
      ops: ops.take(2),
      frontier: hlc(2000),
      reduce: counterReducer,
      schemaVersion: 1,
    );
    await store.compact(first, const []);

    for (final op in ops.skip(2)) {
      await store.append(op);
    }
    final second = compactedSnapshot(
      base: await store.readSnapshot(),
      ops: await store.readOps(),
      frontier: hlc(4000),
      reduce: counterReducer,
      schemaVersion: 1,
    );
    await store.compact(second, const []);

    final actual = restoreState(await store.readSnapshot(), await store.readOps(), counterReducer);
    expect(actual, expected);
  });

  test('落盘的是合法 JSON，可以被人直接读出来检查', () async {
    final store = OpStore(directory);
    await store.append(createOp(id: 'a', at: hlc(1000), title: 'A'));

    final raw = await File('${directory.path}${Platform.pathSeparator}ops.jsonl').readAsString();
    final decoded = jsonDecode(raw.trim()) as Map<String, Object?>;

    expect(decoded['entityId'], 'a');
    expect(decoded['type'], 'entry.create');
  });
}
