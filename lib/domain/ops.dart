/// 操作类型与折叠函数。
///
/// 折叠函数作用在**原始 JSON 状态**上而不是类型化对象上，理由是：
/// 快照要原样落盘、将来要在设备之间原样传输，全程保持 `Map<String, Object?>`
/// 可以避免「序列化 → 反序列化」这一层无意义转换，也避免了往返不一致。
/// 类型化只发生在仓储层读出状态的那一刻。
library;

import '../core/op.dart';

abstract final class OpTypes {
  static const String create = 'entry.create';
  static const String update = 'entry.update';
  static const String delete = 'entry.delete';
}

/// 空状态。
Map<String, Object?> emptyState() => {'entries': <String, Object?>{}};

/// 折叠一条操作。
///
/// 三条性质是硬要求：
/// - **纯函数**：不修改入参，相同输入必须得到相同输出
/// - **幂等**：同一条 op 施加两次与一次结果相同（`create` 已存在时不再覆盖创建时间）
/// - **未知类型不报错**：旧版本遇到新版本的 op 时保持状态不变，
///   但 op 本身仍然留在日志里 —— 升级后的版本照样能折叠它，不会丢数据
Map<String, Object?> applyOp(Map<String, Object?> state, Op op) {
  final entries = Map<String, Object?>.from((state['entries'] as Map?) ?? const {});
  final id = op.entityId;

  switch (op.type) {
    case OpTypes.create:
      if (entries.containsKey(id)) return state;
      entries[id] = {
        'id': id,
        'kind': op.payload['kind'],
        'title': op.payload['title'] ?? '',
        'body': op.payload['body'] ?? '',
        'done': op.payload['done'] ?? false,
        'dueAt': op.payload['dueAt'],
        'createdAt': op.payload['createdAt'] ?? op.hlc.wall,
        'updatedAt': op.payload['createdAt'] ?? op.hlc.wall,
      };
      return {'entries': entries};

    case OpTypes.update:
      final existing = entries[id];
      if (existing is! Map) return state;
      final patched = Map<String, Object?>.from(existing);
      for (final field in const ['title', 'body', 'done', 'dueAt']) {
        if (op.payload.containsKey(field)) patched[field] = op.payload[field];
      }
      patched['updatedAt'] = op.hlc.wall;
      entries[id] = patched;
      return {'entries': entries};

    case OpTypes.delete:
      if (!entries.containsKey(id)) return state;
      entries.remove(id);
      return {'entries': entries};

    default:
      return state;
  }
}
