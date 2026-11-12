/// 快照与日志压缩 —— **纯逻辑，不做 I/O**，因此可以被完全确定地测试。
///
/// 日志只追加就意味着它会一直长。快照把「日志的前缀」折叠成一份状态，
/// 之后只保留前沿之上的那一段尾部，启动时不再重放全部历史。
///
/// 这里有一个很容易写错、且错了以后**不可恢复**的地方：
/// 压缩必须是可重入的 —— 第二次压缩必须在第一次的结果之上继续折叠。
/// 如果每次都从空状态开始折叠「日志里剩下的那些」，那么第一次被压缩掉的
/// 操作就永远丢失了。`compactedSnapshot` 用 `base` 参数把这条性质钉在类型上。
library;

import 'hlc.dart';
import 'op.dart';

/// 一份状态快照。
final class Snapshot {
  const Snapshot({
    required this.frontier,
    required this.schemaVersion,
    required this.state,
  });

  /// 快照覆盖到哪一条为止：**时间戳不晚于 frontier 的操作都已经折进 [state] 了**。
  final Hlc frontier;

  final int schemaVersion;

  /// 折叠后的领域状态。必须可 JSON 序列化，因为它要落盘。
  final Map<String, Object?> state;

  Map<String, Object?> toJson() => {
        'frontier': frontier.toJson(),
        'schemaVersion': schemaVersion,
        'state': state,
      };

  factory Snapshot.fromJson(Map<String, Object?> json) => Snapshot(
        frontier: Hlc.fromJson(json['frontier']! as Map<String, Object?>),
        schemaVersion: json['schemaVersion']! as int,
        state: Map<String, Object?>.from(json['state']! as Map),
      );

  /// 给快照换一个前沿（用于「数据没变，但边界前移」的情况）。
  Snapshot withFrontier(Hlc frontier) => Snapshot(
        frontier: frontier,
        schemaVersion: schemaVersion,
        state: state,
      );
}

/// 严格晚于 [frontier] 的操作 —— 即「快照还没覆盖的那部分」。
List<Op> opsAbove(Iterable<Op> ops, Hlc frontier) =>
    sortOps(ops.where((op) => op.hlc.compareTo(frontier) > 0));

/// 折叠出一份新快照。
///
/// - [base] 是上一份快照；传 `null` 表示从空状态开始。
/// - 折叠范围是 **`base.frontier` 之后到 `frontier` 为止**的操作。
/// - 因此连续调用 `compactedSnapshot` 与一次性折叠整个日志结果完全一致，
///   见 test/core/snapshot_test.dart 的「压缩两次 == 压缩一次」。
Snapshot compactedSnapshot({
  required Snapshot? base,
  required Iterable<Op> ops,
  required Hlc frontier,
  required Reducer<Map<String, Object?>> reduce,
  required int schemaVersion,
}) {
  final baseFrontier = base?.frontier;
  final covered = sortOps(
    ops.where((op) {
      if (op.hlc.compareTo(frontier) > 0) return false;
      if (baseFrontier != null && op.hlc.compareTo(baseFrontier) <= 0) return false;
      return true;
    }),
  );

  final state = foldOps(covered, base?.state ?? const {}, reduce);

  return Snapshot(frontier: frontier, schemaVersion: schemaVersion, state: state);
}

/// 从「快照 + 尾部操作」重建完整状态。
///
/// 关键约束：**只能折叠前沿之上的操作**。前沿之下的操作已经折进快照了，
/// 再叠一次就是重复施加，会得到错误结果。
Map<String, Object?> restoreState(
  Snapshot? snapshot,
  Iterable<Op> ops,
  Reducer<Map<String, Object?>> reduce,
) {
  if (snapshot == null) {
    return foldOps(ops, const {}, reduce);
  }
  return foldOps(opsAbove(ops, snapshot.frontier), snapshot.state, reduce);
}
