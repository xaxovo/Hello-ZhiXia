/**
 * 同步前沿（sync frontier）—— **连续前缀**的因果摘要。
 *
 * 这是 open-questions #13（日志压缩）、#14（冲突判定）、#15（裁剪水位）共同缺失的
 * 那个原语。三者看起来是三个问题，实际问的是同一件事：
 *
 * > **「这台设备到底确凿收到了哪些操作？」**
 *
 * ## 与「最新 HLC」的区别（这是 #15 的要害）
 *
 * `frontier[source] = h` 的含义是：**我收到了 source 产生的、HLC ≤ h 的全部操作** ——
 * 一个**连续前缀**的声明。
 *
 * 它**不是**「我见过 source 的最大 HLC」。后者只是「见过」，中间可以有洞：
 * 先收到 h3、错过 h2，最大值就停在 h3，而此时 h2 缺失。用「见过」当作安全判据，
 * 会让裁剪放行一台其实没收到该墓碑的设备，那台设备重连后就把已删除的数据复活了。
 *
 * 因此本模块刻意把两者分开命名：
 *
 * | 函数 | 语义 | 能否作为安全判据 |
 * | --- | --- | --- |
 * | {@link advanceFromClaim} / 快照采纳 | 连续前缀 | ✅ 可以 |
 * | {@link latestSeenPerSource} | 见过的最大值 | ❌ **不可以**，只用于展示与调试 |
 *
 * ## 前沿如何推进（两条路径，都是可证明的）
 *
 * 1. **批量证明**（{@link advanceFromClaim}）：来源设备声明「我共有 `count` 条操作，
 *    最后一条是 `head`」。接收方只要手里的该来源操作**条数相等且最大 HLC 恰好等于 head**，
 *    就证明了「我持有的正是全部那 count 条」—— 因为 opId 唯一，子集与全集等势即相等。
 *    两个条件缺一不可：只比条数会被过期声明骗过（可能持有 {1..11, 15}），
 *    只比 head 则无法排除中间有洞。
 * 2. **采纳快照**：快照本身就是「前沿之前的全部操作已折叠」的证书，
 *    因此采纳后前沿直接跳到快照的前沿（见 compaction.ts）。
 *
 * 关键性质：前沿对因果序是**单调**的。并且它是可序列化的普通对象
 * （不是 `Map`），因为它要作为协议字段在设备之间传输。
 */

import { compareHlc, type HlcTimestamp } from "./clock.js";
import type { Op } from "./op.js";

/**
 * 设备 id → 该来源的连续前缀上界。
 *
 * 键不存在 与 值为 `undefined` 都表示「该来源一无所知」，调用方一律按「没有」处理。
 */
export type Frontier = Readonly<Record<string, HlcTimestamp>>;

export function emptyFrontier(): Frontier {
  return {};
}

/** 两个前沿是否逐来源相等。用于协议里跳过无变化的推送。 */
export function frontierEquals(a: Frontier, b: Frontier): boolean {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const key of keys) {
    const left = a[key];
    const right = b[key];
    if (left === undefined || right === undefined) {
      if (left !== right) return false;
      continue;
    }
    if (compareHlc(left, right) !== 0) return false;
  }
  return true;
}

/**
 * 把 `source` 的前沿推进到 `upTo`（只前进，不回退）。
 *
 * `source` 必须等于 `upTo.deviceId`：前沿是「某来源自己的操作」的摘要，
 * 把一条 A 的时间戳记到 B 的名下会让所有覆盖判断失效。这个断言很便宜，
 * 而它拦下的错误极难从现象上反推。
 */
export function advanceFrontier(frontier: Frontier, source: string, upTo: HlcTimestamp): Frontier {
  if (upTo.deviceId !== source) {
    throw new Error(
      `前沿必须按来源归档：source=${source} 与时间戳归属 ${upTo.deviceId} 不一致`,
    );
  }
  const current = frontier[source];
  if (current !== undefined && compareHlc(current, upTo) >= 0) return frontier;
  return { ...frontier, [source]: upTo };
}

/** `frontier` 是否覆盖 `(source, hlc)`：即该来源此前的操作是否**全部**已收到。 */
export function frontierCovers(frontier: Frontier, source: string, hlc: HlcTimestamp): boolean {
  const reached = frontier[source];
  return reached !== undefined && compareHlc(reached, hlc) >= 0;
}

/**
 * 所有给定前沿是否都覆盖 `(source, hlc)`。
 *
 * **空集合返回 `false`**，不返回 `true`。数学上的「空集全称真」在这里是危险的：
 * 「没有任何设备确认」绝不能被当成「所有设备都确认了」—— 一个空配对列表
 * 就能让裁剪放行，而那正是数据复活最常见的入口。
 */
export function allFrontiersCover(
  frontiers: Iterable<Frontier>,
  source: string,
  hlc: HlcTimestamp,
): boolean {
  let any = false;
  for (const frontier of frontiers) {
    any = true;
    if (!frontierCovers(frontier, source, hlc)) return false;
  }
  return any;
}

/** 逐来源取最大值。合并两台设备各自报告的前沿时使用。 */
export function mergeFrontier(a: Frontier, b: Frontier): Frontier {
  let result = a;
  for (const [source, hlc] of Object.entries(b)) {
    result = advanceFrontier(result, source, hlc);
  }
  return result;
}

/**
 * 逐来源取最小值 —— **压缩安全水位**的形状。
 *
 * 只有**所有**前沿都覆盖到的来源才会出现在结果里：某来源只要有一台设备落在后面
 * （或该设备的前沿里根本没有这个来源），这个来源就无法安全压缩，因为那台设备
 * 将来还需要这些操作。
 *
 * 与 {@link allFrontiersCover} 同一套语义，只是换成了「一次算出一个前沿」的形态。
 * 空数组同样返回空前沿（什么都不可压缩）。
 */
export function minFrontier(frontiers: readonly Frontier[]): Frontier {
  if (frontiers.length === 0) return {};

  const first = frontiers[0]!;
  const result: Record<string, HlcTimestamp> = {};

  for (const [source, hlc] of Object.entries(first)) {
    let lowest = hlc;
    let covered = true;
    for (let i = 1; i < frontiers.length; i += 1) {
      const other = frontiers[i]![source];
      if (other === undefined) {
        covered = false;
        break;
      }
      if (compareHlc(other, lowest) < 0) lowest = other;
    }
    if (covered) result[source] = lowest;
  }

  return result;
}

/**
 * 每个来源**见过**的最大 HLC。
 *
 * ⚠️ 这是「见过」，不是「收全了」——**不能**拿它当裁剪或压缩的安全判据
 * （open-questions #15 的成因）。它只适合展示、调试与进度估算。
 * 需要安全判据时用 {@link advanceFromClaim} 或快照前沿。
 */
export function latestSeenPerSource(ops: readonly Op[]): Frontier {
  let frontier: Frontier = {};
  for (const op of ops) {
    frontier = advanceFrontier(frontier, op.hlc.deviceId, op.hlc);
  }
  return frontier;
}

/**
 * **所有配对设备都已确认**的那段前沿 —— 裁剪与压缩共用的安全水位。
 *
 * 这是 #13 与 #15 的交汇点：两条不同的安全判断（「这条墓碑能不能丢」与
 * 「这段操作能不能压缩」）其实是同一个谓词 —— 「每台设备是否都覆盖到了这里」。
 *
 * 两条保守规则：
 *
 * - **只要有设备没上报**（值为 `undefined`）→ 返回空前沿，什么都不可动。
 *   不知道它有什么，就不能假定它有。
 * - 某来源只有部分设备覆盖 → 该来源不出现在结果里（见 {@link minFrontier}）。
 *
 * 传入**显式的 `undefined`** 表示「这台设备在我的配对列表里但尚未上报」。
 * 省略键则意味着「它不在配对列表里」，两者语义完全不同。
 */
export function confirmedFrontier(
  byDevice: ReadonlyMap<string, Frontier | undefined>,
): Frontier {
  const frontiers: Frontier[] = [];
  for (const frontier of byDevice.values()) {
    if (frontier === undefined) return {};
    frontiers.push(frontier);
  }
  return minFrontier(frontiers);
}

/**
 * 一台设备对自己操作总数的声明。见 {@link advanceFromClaim}：`count` 与 `head`
 * 共同构成「连续前缀」的证明，缺一不可。
 */
export interface SourceClaim {
  readonly source: string;
  /** 该来源产生的操作**总数**。 */
  readonly count: number;
  /** 该来源最后一条操作的时间戳。 */
  readonly head: HlcTimestamp;
}

/** 为一组操作里的某个来源构造声明。该来源没有操作时返回 `undefined`。 */
export function claimFor(ops: readonly Op[], source: string): SourceClaim | undefined {
  let count = 0;
  let head: HlcTimestamp | undefined;
  for (const op of ops) {
    if (op.hlc.deviceId !== source) continue;
    count += 1;
    if (head === undefined || compareHlc(op.hlc, head) > 0) head = op.hlc;
  }
  if (head === undefined) return undefined;
  return { source, count, head };
}

/**
 * 用对端的 {@link SourceClaim} 尝试推进前沿 —— **这是「连续前缀」的唯一证明入口**。
 *
 * 只有同时满足以下三条才推进，否则原样返回（保守，绝不猜）：
 *
 * 1. `claim.head.deviceId === claim.source`（声明自洽）
 * 2. 本端持有的该来源操作**去重后条数**等于 `claim.count`
 * 3. 本端持有的该来源**最大 HLC 正好等于** `claim.head`
 *
 * 第 2 条单独不够：声明可能过期，本端可能持有 {1..11, 15} —— 条数同为 12，
 * 中间却有洞。加上第 3 条后，条数为 12 且最大值为第 12 条的集合**只可能是 {1..12}**，
 * 因为 opId 唯一、且全部来自同一来源。
 */
export function advanceFromClaim(
  frontier: Frontier,
  ops: readonly Op[],
  claim: SourceClaim,
): Frontier {
  if (claim.head.deviceId !== claim.source) return frontier;

  const seen = new Map<string, HlcTimestamp>();
  for (const op of ops) {
    if (op.hlc.deviceId !== claim.source) continue;
    seen.set(op.opId, op.hlc);
  }
  if (seen.size !== claim.count) return frontier;

  let max: HlcTimestamp | undefined;
  for (const hlc of seen.values()) {
    if (max === undefined || compareHlc(hlc, max) > 0) max = hlc;
  }
  if (max === undefined || compareHlc(max, claim.head) !== 0) return frontier;

  return advanceFrontier(frontier, claim.source, claim.head);
}
