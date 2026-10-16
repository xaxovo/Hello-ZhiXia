/**
 * 操作日志（op log）—— 状态变更的唯一表达形式。
 *
 * 见 data-model.md 第三节：**任何状态变更都表达为一个不可变操作**，
 * 追加进日志；当前状态由日志折叠（fold）得出。
 *
 * 为什么不是「直接改字段」：直接改字段是**状态覆盖**，它无法表达两个并发的意图，
 * 因此两端各改一次之后无法合并。操作日志是**意图追加**，可以被合并、重放、审计。
 *
 * 禁止：跨设备直接 UPDATE 字段。
 */

import { compareHlc, type HlcTimestamp } from "./clock.js";
import { frontierCovers, type Frontier } from "./frontier.js";
import type { Ulid } from "./id.js";

export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

/** 操作类型命名约定：`<实体类型>.<动作>`，例如 `note.setTitle`、`reminder.fire`。 */
export type OpType = string;

export interface Op<P extends JsonValue = JsonValue> {
  readonly opId: Ulid;
  readonly hlc: HlcTimestamp;
  readonly entityId: Ulid;
  readonly type: OpType;
  readonly payload: P;
  /** 该 payload 遵循的 schema 版本，见 schema.ts。 */
  readonly schemaVersion: number;
  /**
   * **产生这条操作之前**，本设备已知的同步前沿（见 frontier.ts）。
   *
   * 光有 HLC 无法判定两条操作是否**并发**：HLC 给的是全序，而全序不等于因果序。
   * 例如 A 在 wall=100 counter=0 写入，B 在 wall=101 counter=0 写入 ——
   * 无论 B 有没有见过 A 的那条，都会得到同样的时间戳（wall 前进时 counter 归零）。
   * 因此必须把「写入时我知道什么」记下来，{@link areConcurrent} 才有依据。
   *
   * 这是**可选**字段：缺省时并发性不可判定，而不是被假定为「并发」或「非并发」。
   * 缺省会让相关位置的冲突变成「不可判定」并如实报告给上层（见 conflict.ts），
   * 而不会静默地当成没有冲突。
   */
  readonly causalContext?: Frontier | undefined;
}

/** 给一条操作盖上因果上下文。见 {@link Op.causalContext}。 */
export function withCausalContext<P extends JsonValue>(op: Op<P>, context: Frontier): Op<P> {
  return { ...op, causalContext: context };
}

/**
 * 操作的全序比较。
 *
 * 先比 HLC 三元组；理论上同一设备在同一毫秒同一 counter 上只会产生一个时间戳，
 * 因此 HLC 相同意味着是同一个操作。仍用 opId 兜底，保证比较是**确定性**的
 * ——这一点很关键：多端必须对同一批操作排出完全相同的顺序，否则状态会分叉。
 */
export function compareOps(a: Op, b: Op): number {
  const byHlc = compareHlc(a.hlc, b.hlc);
  if (byHlc !== 0) return byHlc;
  if (a.opId === b.opId) return 0;
  return a.opId < b.opId ? -1 : 1;
}

export function sortOps(ops: readonly Op[]): Op[] {
  return [...ops].sort(compareOps);
}

/** 折叠函数：`(状态, 操作) -> 新状态`。必须是纯函数。 */
export type Reducer<S> = (state: S, op: Op) => S;

/** 按全序折叠出一份状态。 */
export function foldOps<S>(ops: readonly Op[], initial: S, reducer: Reducer<S>): S {
  let state = initial;
  for (const op of sortOps(ops)) {
    state = reducer(state, op);
  }
  return state;
}

export interface OpLog {
  /**
   * 追加一个操作。**同 opId 重复追加必须是静默无操作**——
   * 同步会重复投递，幂等是这里的硬要求。
   */
  append(op: Op): void;
  /** 全部操作，按全序排列。 */
  all(): readonly Op[];
  /** HLC 严格大于 `after` 的操作，按全序排列。用于增量同步。 */
  since(after: HlcTimestamp | undefined): readonly Op[];
  has(opId: Ulid): boolean;
  get size(): number;
}

export interface PruneOptions {
  /**
   * 返回 `true` 的操作即便位于安全水位之下也**必须保留**。
   *
   * 存在的理由：pin 住的墓碑（彻底删除流程进行中）不能被压缩掉，
   * 否则删除意图就无法再传播给离线设备 —— 那是「不能与墓碑裁剪打架」这条约束
   * （open-questions #13）的落点。见 deletion.ts 与 ADR-0014。
   */
  readonly retain?: ((op: Op) => boolean) | undefined;
}

/**
 * 支持压缩的日志（open-questions #13）。
 *
 * `OpLog` 是给**读取方**的最小契约（折叠、增量、判重）；压缩是额外的能力，
 * 单独放在这个接口里，避免所有只读代码都被迫面对「日志会变短」这件事。
 *
 * 快照与压缩的语义见 compaction.ts —— 这里只提供「按安全水位删掉一批操作」这一步。
 */
export interface CompactableOpLog extends OpLog {
  /**
   * 删除安全水位 `safe` 覆盖的操作（即每个来源的连续前缀之内、且所有配对设备
   * 都已确认的那一段），返回删除条数。
   *
   * - `safe` 为空前沿时**什么都不删** —— 这是构造上的安全性，不是特判。
   * - {@link PruneOptions.retain} 命中的操作会被跳过。
   * - 调用方必须**先**把这一段折叠成快照，否则数据就真的丢了。
   */
  prune(safe: Frontier, options?: PruneOptions): number;
}

/** 内存实现。用于测试与多节点模拟器；生产环境应换成持久化实现。 */
export function createMemoryOpLog(): CompactableOpLog {
  const byId = new Map<string, Op>();

  const sorted = (): Op[] => sortOps([...byId.values()]);

  return {
    append(op: Op): void {
      if (byId.has(op.opId)) return;
      byId.set(op.opId, op);
    },
    all(): readonly Op[] {
      return sorted();
    },
    since(after: HlcTimestamp | undefined): readonly Op[] {
      const list = sorted();
      if (after === undefined) return list;
      return list.filter((op) => compareHlc(op.hlc, after) > 0);
    },
    has(opId: Ulid): boolean {
      return byId.has(opId);
    },
    get size(): number {
      return byId.size;
    },
    prune(safe: Frontier, options: PruneOptions = {}): number {
      const retain = options.retain;
      let removed = 0;
      // 先快照键值再删除：直接遍历 Map 时删除会让迭代器行为依赖实现细节
      for (const [opId, op] of [...byId]) {
        if (!frontierCovers(safe, op.hlc.deviceId, op.hlc)) continue;
        if (retain?.(op) === true) continue;
        byId.delete(opId);
        removed += 1;
      }
      return removed;
    },
  };
}

/**
 * 把一批远端操作合并进本地日志，返回**新增**条数。
 *
 * 这是同步的核心契约，两个性质不可妥协：
 *
 * 1. **幂等** —— 同一条操作重复投递不产生任何副作用。
 *    同步必然重复投递：重连、重试、anti-entropy 都会重复发。
 * 2. **与到达顺序无关** —— 网络会乱序，重连会重放旧数据。
 *    合并结果只取决于「最终收到了哪些操作」，不取决于收到的顺序。
 */
export function mergeOps(target: OpLog, incoming: readonly Op[]): number {
  let added = 0;
  for (const op of incoming) {
    if (target.has(op.opId)) continue;
    target.append(op);
    added += 1;
  }
  return added;
}

/** 日志中已知的最大 HLC。空日志返回 `undefined`。 */
export function maxHlc(log: OpLog): HlcTimestamp | undefined {
  const all = log.all();
  return all.length === 0 ? undefined : all[all.length - 1]!.hlc;
}

/** 本地已知的全部 opId，按全序排列。用于与对端交换摘要。 */
export function knownOpIds(log: OpLog): readonly Ulid[] {
  return log.all().map((op) => op.opId);
}

/**
 * 从一批操作中筛出对端摘要中**没有**的那些。
 *
 * 这是 anti-entropy 的应答侧。注意它用的是**完整摘要**（全部 opId）而不是
 * 「最大 HLC 水位」—— 后者在丢包与乱序下会漏数据：
 * 若某设备先收到来自 X 的 h3、错过了 h2，水位就会停在 h3，h2 永远补不回来。
 * 完整摘要虽然带宽是 O(n)，但它**无条件正确**，适合作为正确性的基准实现。
 *
 * 压缩（compaction.ts）之后这里有一个必须守住的边界：完整摘要只需要跑在
 * **对端前沿之上的那段尾部**，因为前沿之下的区间由快照负责补齐。
 * 见 {@link opsAboveFrontier} —— 直接对整个日志调用本函数在压缩后仍然正确，
 * 但对端将无法区分「我没有这条」与「我这条已经被压缩掉了」。
 */
export function opsMissingFrom(incoming: readonly Op[], known: ReadonlySet<string>): Op[] {
  return incoming.filter((op) => !known.has(op.opId));
}
