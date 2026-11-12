/// 操作（op）—— 状态变更的唯一表达形式。
///
/// 任何写操作都表达为一条不可变的 op，追加进日志；当前状态由日志折叠得出。
///
/// 为什么不是「直接改字段」：直接改字段是**状态覆盖**，它无法表达两个并发的意图。
/// op 是**意图追加**，可以被重放、审计、撤销，也是日后多设备合并的基础。
/// 见 doc/data-model.md 第三节。
library;

import 'hlc.dart';

/// 当前 schema 版本。任何 payload 结构的变化都必须递增它，
/// 并补一条从旧版本迁移过来的纯函数。
const int currentSchemaVersion = 1;

/// 一条操作。
final class Op {
  const Op({
    required this.opId,
    required this.hlc,
    required this.entityId,
    required this.type,
    required this.payload,
  });

  /// 全局唯一且有序的 ID，同时用于幂等去重。
  final String opId;

  /// 产生这条操作时的逻辑时间戳。
  final Hlc hlc;

  /// 这条操作作用于哪个实体。
  final String entityId;

  /// 操作类型，命名约定 `<实体>.<动作>`，例如 `note.update`。
  final String type;

  /// 操作携带的数据。必须可 JSON 序列化 —— 它要落盘。
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
        'opId': opId,
        'hlc': hlc.toJson(),
        'entityId': entityId,
        'type': type,
        'payload': payload,
        'schemaVersion': currentSchemaVersion,
      };

  factory Op.fromJson(Map<String, Object?> json) => Op(
        opId: json['opId']! as String,
        hlc: Hlc.fromJson(json['hlc']! as Map<String, Object?>),
        entityId: json['entityId']! as String,
        type: json['type']! as String,
        payload: Map<String, Object?>.from(json['payload']! as Map),
      );

  @override
  String toString() => '$type($entityId) @$hlc';
}

/// op 的全序比较。
///
/// 先比 HLC 三元组，再用 opId 兜底。必须**确定性**：
/// 同一批 op 在任何设备上折叠出的顺序都要完全一致，否则状态会分叉。
int compareOps(Op a, Op b) {
  final byHlc = a.hlc.compareTo(b.hlc);
  if (byHlc != 0) return byHlc;
  return a.opId.compareTo(b.opId);
}

List<Op> sortOps(Iterable<Op> ops) => ops.toList()..sort(compareOps);

/// 折叠函数：`(状态, 操作) -> 新状态`，必须是纯函数。
typedef Reducer<S> = S Function(S state, Op op);

/// 按全序折叠出一份状态。
S foldOps<S>(Iterable<Op> ops, S initial, Reducer<S> reduce) {
  var state = initial;
  for (final op in sortOps(ops)) {
    state = reduce(state, op);
  }
  return state;
}
