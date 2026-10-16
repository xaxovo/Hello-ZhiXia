/**
 * 删除语义 —— 两级模型，见 ADR-0014。
 *
 * 在无中心的全量复制系统里，「删除」是一个分布式问题：
 * 物理删除会让**离线设备重连后把数据复活**，所以删除必须写墓碑。
 * 但墓碑不能永久保留，否则元数据无限增长（与 ADR-0013 的体积预算冲突）。
 *
 * 于是分成两级，并把**能兑现的承诺**与**不能兑现的承诺**明确区分开：
 *
 * | 主张 | 能否 100% 兑现 |
 * | --- | --- |
 * | 服务方任何时候都无法读取你的数据 | ✅ 可以（只转发密文） |
 * | 删除后数据在所有地方彻底消失 | ❌ 取决于设备是否在线 |
 *
 * ## 裁剪的两个必要条件（都不可省）
 *
 * 判断「墓碑能不能丢掉」需要两件**互不替代**的事，混为一谈正是 #15 的成因：
 *
 * 1. **保留期已过** —— 用「各设备自身进度的最小值」当墙钟，绝不用本机墙钟。
 *    某台设备时钟快了 180 天就会把刚创建的墓碑判成可裁剪；一旦裁掉，
 *    那台真正离线很久的设备重连后就把数据复活了。
 * 2. **每台配对设备都真的收到了这条墓碑** —— 这一条**不能**用「最新 HLC」代替。
 *
 * 第 2 条容易写错，且错得很隐蔽：一台设备的「最新 HLC」只反映它自己的时钟与
 * 本地写入，**不能证明它收到了某条特定的墓碑**。设想 A 删除笔记 N 产生墓碑 T，
 * 此后 A 与 B 再没成功同步过、但各自持续本地写入；180 天后两边的最新 HLC 都远超 T，
 * 于是「A 裁掉 T → B 重连 → N 复活」。所以这里必须用**同步前沿**
 * （frontier.ts 的连续前缀声明），而不是最新 HLC。
 *
 * 于是本模块要求调用方提供 {@link PruneWatermark}，由**每台配对设备各自上报的
 * 同步前沿**构造。只要有设备没上报，水位就不完整，裁剪一律被拒。
 */

import type { HlcTimestamp } from "./clock.js";
import { allFrontiersCover, type Frontier } from "./frontier.js";
import type { Ulid } from "./id.js";

/** 墓碑保留期（天）。见 ADR-0014：远大于「设备正常离线」的典型时长。 */
export const TOMBSTONE_RETENTION_DAYS = 180;

export const TOMBSTONE_RETENTION_MS = TOMBSTONE_RETENTION_DAYS * 24 * 60 * 60 * 1000;

export interface Tombstone {
  readonly entityId: Ulid;
  readonly deletedAt: HlcTimestamp;
  /** 执行删除的设备。 */
  readonly deletedBy: string;
  /**
   * 是否豁免快照裁剪。
   * 彻底删除流程进行中的墓碑必须 pin 住，否则裁剪后无法向离线设备传播删除意图。
   */
  readonly pinned?: boolean;
}

/**
 * 裁剪安全水位 —— 由**每台配对设备上报的同步前沿**构造。
 *
 * 用 {@link pruneWatermark} 构造，不要手工拼：`byDevice`、`reported`、`complete`
 * 必须如实反映「还有几台设备没确认」，`wall` 必须真正是各设备自身进度的最小值。
 */
export interface PruneWatermark {
  /**
   * 设备 id → 该设备上报的**同步前沿**。
   *
   * 键存在但值为 `undefined` 表示「它在配对列表里，但尚未上报」——
   * 这是必须显式表达的状态，见 {@link pruneWatermark}。
   */
  readonly byDevice: ReadonlyMap<string, Frontier | undefined>;
  /**
   * **仅用于保留期判定**的安全墙钟：各设备**自身**进度的最小值。
   *
   * 它**不是**「收到确认」的依据 —— 那由 {@link tombstoneConfirmed} 负责。
   * 只有在 {@link PruneWatermark.complete} 为 true 时它才有意义。
   */
  readonly wall: number;
  /** 已上报过前沿的设备数。 */
  readonly reported: number;
  /** 配对列表中的设备总数。 */
  readonly expected: number;
  /** `reported === expected` 且配对列表非空。为 false 表示水位不可信。 */
  readonly complete: boolean;
}

/**
 * 由「每台配对设备的同步前沿」构造裁剪安全水位。
 *
 * **尚未上报过的设备必须显式出现在 map 里、值为 `undefined`**，不能省略。
 * 省略会被当成「这台设备根本不在配对列表里」，于是 `expected` 被算小、
 * 水位被错误地判定为完整 —— 而新配对或长期离线的设备恰恰是最可能
 * 让数据复活的那一台。
 *
 * 参数名从 `latestByDevice` 改成了 `frontiersByDevice`：旧名字太容易被理解成
 * 「最新 HLC」，而这两者的区别正是 #15 的全部内容（见 frontier.ts）。
 */
export function pruneWatermark(
  frontiersByDevice: ReadonlyMap<string, Frontier | undefined>,
): PruneWatermark {
  let wall = Number.POSITIVE_INFINITY;
  let reported = 0;

  for (const [deviceId, frontier] of frontiersByDevice) {
    if (frontier === undefined) continue;
    reported += 1;
    // 只用该设备**对自己**的进度当墙钟：这才等价于「它自己走到了哪」。
    // 取不到就退化成 -Infinity，即保留期永远不到 —— 保守，不猜。
    const own = frontier[deviceId];
    const ownWall = own === undefined ? Number.NEGATIVE_INFINITY : own.wall;
    if (ownWall < wall) wall = ownWall;
  }

  const expected = frontiersByDevice.size;
  return {
    byDevice: frontiersByDevice,
    // 一台都没上报时给 -Infinity：与任何 deletedAt 的差值都是 -Infinity，
    // 于是任何「年龄 ≥ 保留期」的判定自然为 false，不需要额外的特判分支。
    wall: reported === 0 ? Number.NEGATIVE_INFINITY : wall,
    reported,
    expected,
    // 空配对列表不算「完整」：没有任何设备可以确认，就不该放行裁剪。
    complete: expected > 0 && reported === expected,
  };
}

/**
 * 是否**每台配对设备都已确认收到**这条墓碑。
 *
 * 判据是前沿覆盖（`frontier_d[墓碑来源] ≥ 墓碑 HLC`），不是「最新 HLC 超过了它」。
 * 墓碑的归属来源取 `deletedAt.deviceId` —— 参与前沿比较的必须是这个值，
 * `deletedBy` 只是可读记录，二者在正常构造下相同。
 */
export function tombstoneConfirmed(tombstone: Tombstone, watermark: PruneWatermark): boolean {
  const frontiers: Frontier[] = [];
  for (const frontier of watermark.byDevice.values()) {
    if (frontier === undefined) return false;
    frontiers.push(frontier);
  }
  // allFrontiersCover 对空集合返回 false：没有任何设备确认 ≠ 所有设备确认。
  return allFrontiersCover(frontiers, tombstone.deletedAt.deviceId, tombstone.deletedAt);
}

/**
 * 墓碑相对水位的年龄。
 * 水位不可信（不完整）时返回 `-Infinity`，即「永远不到期」。
 */
function tombstoneAge(tombstone: Tombstone, watermark: PruneWatermark): number {
  if (!watermark.complete) return Number.NEGATIVE_INFINITY;
  return watermark.wall - tombstone.deletedAt.wall;
}

/**
 * 墓碑是否已可以从快照中裁剪掉。
 *
 * 四个条件缺一不可：
 *
 * 1. 未被 pin（彻底删除流程进行中不能丢）
 * 2. 水位**完整** —— 只要有一台配对设备没上报，就一律不裁剪
 * 3. 年龄 ≥ 保留期（保留期用各设备自身进度的最小值度量）
 * 4. **每台配对设备都已确认收到这条墓碑**（前沿覆盖，见 {@link tombstoneConfirmed}）
 *
 * 第 4 条是 #15 的修复：它是第 3 条**不能**替代的。一台设备的最新 HLC 可以远超
 * 墓碑、却从未收到过它。
 *
 * 注意这仍是**保守**判断：裁剪早于「设备可能离线的最长时间」会导致数据复活，
 * 因此宁可多留。
 */
export function isTombstonePrunable(tombstone: Tombstone, watermark: PruneWatermark): boolean {
  if (tombstone.pinned === true) return false;
  if (tombstoneAge(tombstone, watermark) < TOMBSTONE_RETENTION_MS) return false;
  return tombstoneConfirmed(tombstone, watermark);
}

/**
 * 墓碑是否「可能失效」—— 即无法排除某台设备重连后复活该数据。
 *
 * 判据是**是否有设备没能确认这条墓碑**，而不是墓碑的年龄。两种情况都算：
 *
 * - 有设备从未上报前沿（水位不完整）
 * - 水位完整，但某台设备的前沿**没有覆盖这条墓碑** —— 这正是 #15 里那台
 *   「一直在本地写、却再没同步过」的设备，也是最容易漏判的一种
 *
 * 但也不必对每一个新建的墓碑都报警（那只会淹没真正的问题），
 * 因此只在它「本该可以裁剪、却因为确认不齐而裁不掉」时才提示 ——
 * 这正是「存在某台设备离线过久」的可观测信号。UI 应当如实呈现，
 * 而不是把「已请求删除」显示成「已彻底消失」。
 *
 * 与 {@link isTombstonePrunable} **恰好互斥**：保留期已过的前提下，
 * 可裁剪要求确认齐全，有风险要求确认不齐，二者不可能同时成立。
 */
export function isTombstoneAtRisk(tombstone: Tombstone, watermark: PruneWatermark): boolean {
  if (tombstone.pinned === true) return false;
  if (watermark.wall - tombstone.deletedAt.wall < TOMBSTONE_RETENTION_MS) return false;
  return !tombstoneConfirmed(tombstone, watermark);
}

/** 彻底删除请求（第二级删除）。 */
export interface PurgeRequest {
  readonly purgeId: Ulid;
  readonly requestedAt: HlcTimestamp;
  /** 配对列表中所有已知设备。 */
  readonly targets: readonly string[];
  /** 已确认执行的设备。 */
  readonly confirmed: readonly string[];
}

export interface PurgeProgress {
  readonly confirmed: readonly string[];
  /** 尚未确认的设备。非空表示**无法立即宣称数据已彻底消失**。 */
  readonly pending: readonly string[];
  readonly canComplete: boolean;
}

export function purgeProgress(request: PurgeRequest): PurgeProgress {
  const confirmedSet = new Set(request.confirmed);
  const confirmed = request.targets.filter((deviceId) => confirmedSet.has(deviceId));
  const pending = request.targets.filter((deviceId) => !confirmedSet.has(deviceId));
  return { confirmed, pending, canComplete: pending.length === 0 };
}

/** 记录一台设备的确认。重复确认是幂等的。 */
export function confirmPurge(request: PurgeRequest, deviceId: string): PurgeRequest {
  if (!request.targets.includes(deviceId)) {
    throw new Error(`设备 ${deviceId} 不在彻底删除的目标列表中`);
  }
  if (request.confirmed.includes(deviceId)) return request;
  return { ...request, confirmed: [...request.confirmed, deviceId] };
}

export interface ForcePurgeResult {
  readonly request: PurgeRequest;
  /**
   * 因长期离线而被移出配对列表的设备。
   * **它们上面的数据无法从物理上删除** —— 这一事实必须如实告知用户，不能用文案掩盖。
   */
  readonly revokedDevices: readonly string[];
}

/**
 * 强制清除：不再等待离线设备，把它们从配对列表移除。
 * 这些设备将来必须重新配对才能加入。
 */
export function forcePurge(request: PurgeRequest): ForcePurgeResult {
  const { confirmed, pending } = purgeProgress(request);
  return {
    request: { ...request, targets: confirmed, confirmed },
    revokedDevices: pending,
  };
}
