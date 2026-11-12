import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/core/op.dart';
import 'package:hello_zhixia/domain/ops.dart';

import '../support/factories.dart';

void main() {
  group('entry.create', () {
    test('建立条目并记下创建时间', () {
      final state = applyOp(emptyState(), createOp(id: 'a', at: hlc(1000), title: '买菜'));
      final entry = (state['entries']! as Map)['a']! as Map;

      expect(entry['title'], '买菜');
      expect(entry['kind'], 'note');
      expect(entry['createdAt'], 1000);
      expect(entry['updatedAt'], 1000);
    });

    test('同一条操作施加两次结果相同（幂等）', () {
      final op = createOp(id: 'a', at: hlc(1000), title: '买菜');
      final once = applyOp(emptyState(), op);
      final twice = applyOp(once, op);

      expect(twice, once);
    });
  });

  group('entry.update', () {
    test('只改传入的字段', () {
      var state = applyOp(emptyState(), createOp(id: 'a', at: hlc(1000), title: '旧'));
      state = applyOp(state, updateOp(id: 'a', at: hlc(2000), patch: const {'title': '新'}));
      final entry = (state['entries']! as Map)['a']! as Map;

      expect(entry['title'], '新');
      expect(entry['updatedAt'], 2000);
    });

    test('正文可以为 null，表示清除', () {
      var state = applyOp(emptyState(), createOp(id: 'a', at: hlc(1000), title: 'T'));
      state = applyOp(state, updateOp(id: 'a', at: hlc(2000), patch: const {'dueAt': null}));
      final entry = (state['entries']! as Map)['a']! as Map;

      expect(entry['dueAt'], isNull);
    });

    test('作用于不存在的实体时被忽略，不抛错', () {
      final state = applyOp(emptyState(), updateOp(id: 'ghost', at: hlc(1000), patch: const {'title': 'x'}));

      expect((state['entries']! as Map), isEmpty);
    });
  });

  group('entry.delete', () {
    test('移除条目', () {
      var state = applyOp(emptyState(), createOp(id: 'a', at: hlc(1000), title: 'T'));
      state = applyOp(state, Op(
        opId: 'op-del',
        hlc: hlc(2000),
        entityId: 'a',
        type: OpTypes.delete,
        payload: const {},
      ));

      expect((state['entries']! as Map), isEmpty);
    });

    test('重复删除不抛错', () {
      final state = applyOp(emptyState(), Op(
        opId: 'op-del',
        hlc: hlc(2000),
        entityId: 'a',
        type: OpTypes.delete,
        payload: const {},
      ));

      expect((state['entries']! as Map), isEmpty);
    });
  });

  group('前向兼容', () {
    test('未知操作类型不改变状态，也不抛错', () {
      final base = applyOp(emptyState(), createOp(id: 'a', at: hlc(1000), title: 'T'));
      final after = applyOp(base, Op(
        opId: 'op-future',
        hlc: hlc(2000),
        entityId: 'a',
        type: 'entry.somethingNew',
        payload: const {'x': 1},
      ));

      expect(after, base, reason: '旧版本遇到新版本的 op 必须原样保留状态，op 本身仍在日志里');
    });
  });

  group('纯函数性质', () {
    test('不修改入参', () {
      final before = applyOp(emptyState(), createOp(id: 'a', at: hlc(1000), title: 'T'));
      final snapshot = Map<String, Object?>.from(before);

      applyOp(before, updateOp(id: 'a', at: hlc(2000), patch: const {'title': 'X'}));

      expect(before, snapshot);
    });
  });
}
