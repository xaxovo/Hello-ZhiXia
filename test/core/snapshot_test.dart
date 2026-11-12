import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/core/op.dart';
import 'package:hello_zhixia/core/snapshot.dart';
import 'package:hello_zhixia/domain/ops.dart';

import '../support/factories.dart';

/// 一个「按 id 累计计数」的玩具 reducer：它的结果直接暴露重复折叠与漏折叠。
Map<String, Object?> counterReducer(Map<String, Object?> state, Op op) {
  final counts = Map<String, Object?>.from((state['counts'] as Map?) ?? const {});
  if (op.type == OpTypes.create) {
    counts[op.entityId] = 1;
  } else if (op.type == OpTypes.update) {
    counts[op.entityId] = ((counts[op.entityId] as int?) ?? 0) + 1;
  }
  return {'counts': counts};
}

void main() {
  group('compactedSnapshot', () {
    test('压缩两次 == 压缩一次（这条不成立就等于静默丢数据）', () {
      final ops = [
        createOp(id: 'a', at: hlc(1000), title: 'A'),
        createOp(id: 'b', at: hlc(2000), title: 'B'),
        updateOp(id: 'a', at: hlc(3000), patch: const {'title': 'A2'}),
        createOp(id: 'c', at: hlc(4000), title: 'C'),
        updateOp(id: 'a', at: hlc(5000), patch: const {'title': 'A3'}),
      ];

      final once = compactedSnapshot(
        base: null,
        ops: ops,
        frontier: hlc(5000),
        reduce: counterReducer,
        schemaVersion: 1,
      );

      final firstHalf = compactedSnapshot(
        base: null,
        ops: ops.take(3),
        frontier: hlc(3000),
        reduce: counterReducer,
        schemaVersion: 1,
      );
      // 第二次压缩只喂「剩余的那部分」，这正是把日志截断之后的真实情形
      final twice = compactedSnapshot(
        base: firstHalf,
        ops: ops.skip(3),
        frontier: hlc(5000),
        reduce: counterReducer,
        schemaVersion: 1,
      );

      expect(twice.state, once.state);
      expect((twice.state['counts']! as Map)['a'], 3);
    });

    test('base 之前与 frontier 之后的操作都不被折叠', () {
      final ops = [
        createOp(id: 'a', at: hlc(1000), title: 'A'),
        createOp(id: 'b', at: hlc(2000), title: 'B'),
        createOp(id: 'c', at: hlc(3000), title: 'C'),
      ];
      final base = compactedSnapshot(
        base: null,
        ops: ops,
        frontier: hlc(1000),
        reduce: counterReducer,
        schemaVersion: 1,
      );

      final next = compactedSnapshot(
        base: base,
        ops: ops,
        frontier: hlc(2000),
        reduce: counterReducer,
        schemaVersion: 1,
      );

      final counts = next.state['counts']! as Map;
      expect(counts.keys, containsAll(<String>['a', 'b']));
      expect(counts.containsKey('c'), isFalse, reason: 'frontier 之后的不能被折叠进来');
    });
  });

  group('restoreState', () {
    test('没有快照时折叠全部操作', () {
      final ops = [
        createOp(id: 'a', at: hlc(1000), title: 'A'),
        updateOp(id: 'a', at: hlc(2000), patch: const {'title': 'A2'}),
      ];
      final state = restoreState(null, ops, counterReducer);
      expect((state['counts']! as Map)['a'], 2);
    });

    test('有快照时只折叠前沿之上的操作，不重复施加', () {
      final ops = [
        createOp(id: 'a', at: hlc(1000), title: 'A'),
        updateOp(id: 'a', at: hlc(2000), patch: const {'title': 'A2'}),
        updateOp(id: 'a', at: hlc(3000), patch: const {'title': 'A3'}),
      ];
      final snapshot = compactedSnapshot(
        base: null,
        ops: ops.take(2),
        frontier: hlc(2000),
        reduce: counterReducer,
        schemaVersion: 1,
      );

      final state = restoreState(snapshot, ops, counterReducer);

      expect((state['counts']! as Map)['a'], 3, reason: '若重复施加，这里会变成 4');
    });
  });

  group('opsAbove', () {
    test('严格大于前沿，等于前沿的不算', () {
      final ops = [
        createOp(id: 'a', at: hlc(1000), title: 'A'),
        createOp(id: 'b', at: hlc(2000), title: 'B'),
      ];
      final above = opsAbove(ops, hlc(1000));
      expect(above.map((op) => op.entityId), ['b']);
    });
  });
}
