/**
 * 快照与日志压缩 —— open-questions #13。
 *
 * ## 问题
 *
 * `OpLog` 只追加、不收缩，而每台设备持有**全量副本**、个人助手又要常年运行，
 * 所以日志增长没有上限。但压缩有一个绕不过去的约束（#13 的第 4 条）：
 *
 * > 必须保住「对端还缺哪些操作」的判断能力。
 *
 * `opsMissingFrom` 刻意用**完整 opId 摘要**而不是「最大 HLC 水位」，因为水位在
 * 丢包与乱序下会漏数据。压缩掉操作之后，这个能力从哪来？
 *
 * ## 答案：把对账分成两段，各自有各自的正确依据
 *
 * ```
 *        已压缩区间            未压缩尾部
 *   ├──────────────────┤├──────────────────────┤
 *   由「前沿」负责          由「完整 opId 摘要」负责
 *   （可证明的连续前缀）      （无条件正确，但只跑在有界的一段上）
 *   ↑
 *   安全水位 = 所有配对设备都已确认的前沿
 * ```
 *
 * - **前沿之下**：每台配对设备都已确认收全（这是压缩的**前提条件**，
 *   见 {@link confirmedFrontier}）。因此对端说自己缺这一段，只可能是它搞错了 ——
 *   我们不需要、也没法把这段重发。对端若真的落后，走**快照**补齐。
 * - **前沿之上**：这一段没有被压缩，`opsMissingFrom` 的完整摘要照旧适用，
 *   丢包与乱序都不会漏数据。
 *
 * 关键点在于**压缩不会削弱任何判断**：压缩的前提就是「所有设备都已有这一段」，
 * 所以「对端缺这一段」这个判断在新协议里根本不会出现。这不是近似，
 * 而是把「谁有什么」从 O(n) 的逐 op 摘要升级成了可证明的前沿比较。
 *
 * ## 快照的语义（与「某个时刻的状态」不同）
 *
 * 快照携带的是**前沿**，不是单个 HLC：它等价于「本前沿覆盖的全部操作都已折叠」。
 * 这一点让 #13 的第 5 条（快照自身受 schema 版本化约束）也能落实 ——
 * {@link migrateSnapshot} 用既有的迁移链把快照迁到最新版本。
 */

import { foldOps, type CompactableOpLog, type JsonValue, type Op, type OpLog, type Reducer } from "./op.js";
import { confirmedFrontier, frontierCovers, type Frontier } from "./frontier.js";
import type { Ulid } from "./id.js";
import type { MigrationRegistry } from "./schema.js";

/**
 * 一份状态快照。
 *
 * `S extends JsonValue` 是刻意的约束：快照要落盘、还要在设备之间传输，
 * 因此它必须可序列化。把它约束在类型上，比在文档里写一句「请确保可序列化」可靠。
 */
export interface Snapshot<S extends JsonValue = JsonValue> {
  readonly snapshotId: Ulid;
  /**
   * 本快照覆盖的前沿：**该前沿覆盖的全部操作都已折叠进 `state`**。
   *
   * 采纳这份快照的对端可以据此把自己的前沿直接推进到这里 —— 这正是压缩
   * 之后「怎么补上被丢掉的操作」的答案。
   */
  readonly frontier: Frontier;
  readonly schemaVersion: number;
  readonly state: S;
}

export interface CompactOptions<S extends JsonValue> {
  /**
   * 配对设备 → 该设备上报的同步前沿。
   *
   * **尚未上报的设备必须以显式 `undefined` 出现**，不能省略键 ——
   * 省略意味着「它不在配对列表里」，会让安全水位被错误地算大。
   */
  readonly byDevice: ReadonlyMap<string, Frontier | undefined>;
  readonly snapshotId: Ulid;
  readonly schemaVersion: number;
  readonly initial: S;
  readonly fold: Reducer<S>;
  /**
   * 见 {@link PruneOptions.retain}：pin 住的墓碑必须在这里被保住。
   *
   * 被保住的操作用途只有一个 —— **继续向尚未收到它的设备传播**。
   * 它的效果**已经**在快照里（快照忠实折叠了整个安全区间），
   * 因此在本地重建状态时不能让快照再叠加它一次，见 {@link restoreFromSnapshot}。
   */
  readonly retain?: ((op: Op) => boolean) | undefined;
}

export interface CompactResult<S extends JsonValue> {
  readonly snapshot: Snapshot<S>;
  /** 安全水位。对账时用它区分「已压缩区间」与「未压缩尾部」。 */
  readonly safe: Frontier;
  /** 实际从日志里删除的操作条数。被 `retain` 保住的那些不计入。 */
  readonly removed: number;
}

/**
 * 安全水位：可以安全压缩掉的那段前沿。
 *
 * 直接转调 {@link confirmedFrontier} —— 语义与「墓碑能否裁剪」完全一致，
 * 两者共用同一个谓词是刻意为之（见 #13 的第 3 条：不能与墓碑裁剪打架）。
 */
export function safeToCompact(byDevice: ReadonlyMap<string, Frontier | undefined>): Frontier {
  return confirmedFrontier(byDevice);
}

/** 前沿覆盖的操作，即「已压缩区间」的候选。按全序排列。 */
export function opsWithin(log: OpLog, frontier: Frontier): Op[] {
  return log
    .all()
    .filter((op) => frontierCovers(frontier, op.hlc.deviceId, op.hlc));
}

/**
 * 对端前沿**之上**、且不在它摘要里的操作 —— anti-entropy 应答侧在压缩之后的正确定义。
 *
 * 与 {@link opsMissingFrom} 的关系：`opsMissingFrom` 是它的特例
 * （`remote` 为空前沿时两者完全等价）。多出来的那一步是：
 * **对端前沿之下的操作一概不发**，因为可证明它已经有了。
 *
 * `known` 摘要只需要针对这段尾部交换 —— 它是有界的，而整个日志不是。
 */
export function opsAboveFrontier(
  log: OpLog,
  remote: Frontier,
  known: ReadonlySet<string> = new Set(),
): Op[] {
  return log
    .all()
    .filter(
      (op) =>
        !frontierCovers(remote, op.hlc.deviceId, op.hlc) && !known.has(op.opId),
    );
}

/**
 * 对端落在我的快照前沿之后的来源 —— 即「光发操作补不上，必须发快照」的那些。
 *
 * 返回空数组表示对端可以直接用「前沿之上的操作」追上，不必传快照。
 * 这是压缩之后对账协议必须能回答的问题：**什么时候要退化成传快照**。
 */
export function coverageGap(snapshotFrontier: Frontier, remote: Frontier): string[] {
  const gaps: string[] = [];
  for (const [source, hlc] of Object.entries(snapshotFrontier)) {
    if (!frontierCovers(remote, source, hlc)) gaps.push(source);
  }
  return gaps.sort();
}

/**
 * 把安全水位覆盖的操作折叠成快照。**不修改日志**。
 *
 * 折叠顺序是操作的全序（与 {@link foldOps} 一致），因此结果确定 ——
 * 任何设备对同一批操作都会得到同一份状态。
 */
export function createSnapshot<S extends JsonValue>(
  log: OpLog,
  safe: Frontier,
  options: {
    readonly snapshotId: Ulid;
    readonly schemaVersion: number;
    readonly initial: S;
    readonly fold: Reducer<S>;
  },
): Snapshot<S> {
  const covered = opsWithin(log, safe);
  return {
    snapshotId: options.snapshotId,
    frontier: safe,
    schemaVersion: options.schemaVersion,
    state: foldOps(covered, options.initial, options.fold),
  };
}

/**
 * 一步完成「折叠 → 删日志」。
 *
 * 顺序不可颠倒：**先折叠再删除**。反过来的话，一旦中间失败，
 * 那段操作就既不在日志里、也不在快照里 —— 那是不可恢复的数据丢失，
 * 而 `oplog/` 按 data-model.md 第八节是唯一真相来源。
 */
export function compact<S extends JsonValue>(
  log: CompactableOpLog,
  options: CompactOptions<S>,
): CompactResult<S> {
  const safe = safeToCompact(options.byDevice);
  const snapshot = createSnapshot(log, safe, {
    snapshotId: options.snapshotId,
    schemaVersion: options.schemaVersion,
    initial: options.initial,
    fold: options.fold,
  });
  const removed = log.prune(safe, options.retain === undefined ? {} : { retain: options.retain });

  return { snapshot, safe, removed };
}

/**
 * 从「快照 + 前沿之上的尾部操作」重建状态。
 *
 * **必须只折叠前沿之上的操作**，不能图省事折叠整个日志：安全区间内的操作已经
 * 折进快照了，再叠一次就是重复施加。被 `retain` 保住、留在日志里继续传播的
 * 那些操作同样位于前沿之下，因此由这条规则**自动**被排除，不需要特判。
 *
 * 前提：折叠必须**可交换且幂等**（即 data-model.md 第七节的 CRDT / LWW 语义）。
 * 原因不是「重复施加」，而是**顺序**：尾部的某条操作可能来自一台落后设备，
 * 它的 HLC 比安全区间里另一台设备的操作更早。折叠是 join 时顺序无关，
 * `snapshot ⊕ tail` 才等于全量折叠。这个前提本来就由数据模型强制要求，
 * 不是这里额外加的限制。
 */
export function restoreFromSnapshot<S extends JsonValue>(
  snapshot: Snapshot<S>,
  log: OpLog,
  fold: Reducer<S>,
): S {
  return foldOps(opsAboveFrontier(log, snapshot.frontier), snapshot.state, fold);
}

/**
 * 把快照迁移到本端已知的最新 schema 版本（#13 的第 5 条）。
 *
 * 快照是**派生态**，但它同样受 data-model.md 第五节的约束：
 * 新设备必须能解析任意历史版本的快照，因此迁移必须沿迁移链逐版本进行。
 * 快照来自更高版本时 {@link MigrationRegistry.migrate} 会抛错，
 * 而不是按旧 schema 静默解释 —— 那会损坏数据。
 */
export function migrateSnapshot<S extends JsonValue>(
  snapshot: Snapshot<S>,
  registry: MigrationRegistry,
): Snapshot<S> {
  const latest = registry.latestVersion();
  if (snapshot.schemaVersion === latest) return snapshot;

  return {
    ...snapshot,
    schemaVersion: latest,
    state: registry.migrate(snapshot.state, snapshot.schemaVersion) as S,
  };
}
