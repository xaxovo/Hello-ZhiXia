/**
 * 冲突表达 —— open-questions #14。
 *
 * ## 为什么需要这个类型
 *
 * ADR-0012 与 `ui-shared` 的要求是明确的：**冲突宁可可见，不可静默**。
 * 日程时间、金额这类数据的冲突必须呈现在 UI 上，而不是被 LWW 悄悄覆盖。
 * 但在此之前，这条要求只写在注释里 —— 仓库里没有任何类型能表达「两个并发写入
 * 冲突了」，于是 UI 层无从呈现，也没有任何代码能产出它。
 *
 * ## 为什么不是「一套冲突解决框架」
 *
 * **解决策略留给实体模型自己决定**，core-sync 只负责两件事：
 *
 * 1. 给出冲突的**形状**：位置 + 参与的操作 + 是否已自动解决
 * 2. 给出**并发性的判定**：{@link areConcurrent}，因为判定并发是纯逻辑，
 *    与「这个字段该 LWW 还是该让人选」无关
 *
 * 这样得到的类型有生产者（实体模型的 reducer 在折叠时调用 {@link detectConflicts}）
 * 也有消费者（UI 直接渲染），不会变成一个死类型。
 *
 * ## 位置为什么用 JSON Pointer
 *
 * 备选是「字段名」或「字段路径数组」。选 RFC 6901 JSON Pointer 的理由：
 *
 * - 嵌套字段能表达（`/attendees/0/email`），字段名做不到
 * - 是标准，序列化后仍然是字符串，跨端与落盘都无歧义
 * - 与实体模型解耦：core-sync 不需要知道实体长什么样，只要求实体提供一个
 *   `pathOf(op)`
 *
 * 但**具体哪个字段是哪个路径，只有实体模型知道**，所以 `pathOf` 必须由调用方提供。
 */

import { frontierCovers } from "./frontier.js";
import type { Ulid } from "./id.js";
import { compareOps, type Op } from "./op.js";

/** RFC 6901 JSON Pointer。空串 `""` 表示**整个实体**（而不是「没有位置」）。 */
export type JsonPointer = string;

/** 是否符合 RFC 6901：空串，或以 `/` 开头且 `~` 只作为 `~0` / `~1` 出现。 */
export function isJsonPointer(path: string): boolean {
  if (path === "") return true;
  if (!path.startsWith("/")) return false;
  return !/~(?![01])/.test(path);
}

/** 把 JSON Pointer 拆成已反转义的字段段。非法指针抛错。 */
export function pointerSegments(path: JsonPointer): string[] {
  if (!isJsonPointer(path)) {
    throw new Error(`不是合法的 JSON Pointer：${JSON.stringify(path)}`);
  }
  if (path === "") return [];
  // 反转义顺序不可颠倒：`~01` 应解出 `~1`，先解 `~1` 再解 `~0` 才正确（RFC 6901 §4）。
  return path
    .slice(1)
    .split("/")
    .map((segment) => segment.replace(/~1/g, "/").replace(/~0/g, "~"));
}

/** 由字段段拼出 JSON Pointer，自动转义。`joinPointer()` 得到 `""`。 */
export function joinPointer(...segments: readonly string[]): JsonPointer {
  return segments
    .map((segment) => `/${segment.replace(/~/g, "~0").replace(/\//g, "~1")}`)
    .join("");
}

/**
 * 一处冲突。
 *
 * 注意 `resolution: "auto"` **不代表可以不呈现** —— ADR-0012 的要求是冲突可见。
 * 它只表示「系统已经按某个确定性策略选出了结果」，UI 仍然应当让用户知道
 * 「这里发生过并发写入、我们替你选了一个」。`"manual"` 表示必须由人来选。
 */
export interface Conflict {
  readonly entityId: Ulid;
  /** 冲突位置。`""` 表示整个实体。 */
  readonly path: JsonPointer;
  /** 参与冲突的操作，按全序排列（多端结论一致）。 */
  readonly opIds: readonly Ulid[];
  readonly resolution: "auto" | "manual";
}

/**
 * 两条操作是否**并发**（互相都没见过对方）。
 *
 * 判定依据是操作携带的因果上下文（`Op.causalContext`），而不是 HLC 的先后：
 * HLC 给的是全序，全序里「后」并不意味着「因果在后」。A 在 wall=100 写入、
 * B 在 wall=101 写入，二者可能是并发的，也可能 B 见过 A —— 只比时间戳区分不了。
 *
 * 返回 `undefined` 表示**无法判定**（至少一方缺因果上下文）。
 * 这是一个刻意的三态返回值：把「不知道」当成「没有冲突」会让冲突静默消失，
 * 而这正是本模块存在的理由。
 */
export function areConcurrent(a: Op, b: Op): boolean | undefined {
  if (a.opId === b.opId) return false;
  if (a.causalContext === undefined || b.causalContext === undefined) return undefined;
  if (a.hlc.deviceId === b.hlc.deviceId) {
    // 同一设备自己产生的操作是全序的，不存在并发
    return false;
  }
  const aSeesB = frontierCovers(a.causalContext, b.hlc.deviceId, b.hlc);
  const bSeesA = frontierCovers(b.causalContext, a.hlc.deviceId, a.hlc);
  return !aSeesB && !bSeesA;
}

export interface ConflictScanOptions {
  /** 这条操作属于哪个实体。默认取 `op.entityId`。 */
  readonly entityIdOf?: ((op: Op) => Ulid) | undefined;
  /**
   * 这条操作写了哪个位置。**必须由实体模型提供** —— 只有它知道
   * `note.setTitle` 写的是 `/title` 还是 `/meta/title`。
   */
  readonly pathOf: (op: Op) => JsonPointer;
  /**
   * 该位置是否已由自动策略解决。默认 `"manual"` ——
   * 没声明过策略的位置一律交给人，这是保守的那一边。
   */
  readonly resolutionOf?: ((path: JsonPointer) => Conflict["resolution"]) | undefined;
}

export interface ConflictScanResult {
  readonly conflicts: readonly Conflict[];
  /**
   * 因缺少因果上下文而**无法判定**的操作对数量。
   *
   * 上层应当把它当成一个可观测信号（「有 reducer 没有盖章」），
   * 而不是忽略：忽略等于把一批潜在冲突静默丢掉了。
   */
  readonly undecidable: number;
}

/**
 * 扫出一批操作里的冲突。**位置相同的操作之间，只要有并发就报一处冲突。**
 *
 * 同一个位置上的操作按实体模型分组；组内每一对操作用 {@link areConcurrent} 判定：
 *
 * - 判定为并发 → 两条都计入该冲突的 `opIds`
 * - 判定为不可判定（缺因果上下文）→ 计入 `undecidable`，并**不**当作冲突
 * - 判定为非并发 → 正常的先后写入，不是冲突
 *
 * 每处冲突只出现一次，且只在组内确实存在并发时才产生。
 */
export function detectConflicts(
  ops: readonly Op[],
  options: ConflictScanOptions,
): ConflictScanResult {
  const entityIdOf = options.entityIdOf ?? ((op: Op): Ulid => op.entityId);
  const resolutionOf = options.resolutionOf ?? ((): Conflict["resolution"] => "manual");

  interface Group {
    readonly entityId: Ulid;
    readonly path: JsonPointer;
    readonly ops: Op[];
  }

  const groups = new Map<string, Group>();
  for (const op of ops) {
    const path = options.pathOf(op);
    if (!isJsonPointer(path)) {
      throw new Error(`pathOf 返回的不是合法 JSON Pointer：${JSON.stringify(path)}`);
    }
    const entityId = entityIdOf(op);
    const key = `${entityId}\u0000${path}`;
    const existing = groups.get(key);
    if (existing === undefined) groups.set(key, { entityId, path, ops: [op] });
    else existing.ops.push(op);
  }

  const conflicts: Conflict[] = [];
  let undecidable = 0;

  for (const group of groups.values()) {
    if (group.ops.length < 2) continue;

    const sorted = [...group.ops].sort(compareOps);
    const participating = new Set<string>();

    for (let i = 0; i < sorted.length; i += 1) {
      for (let j = i + 1; j < sorted.length; j += 1) {
        const verdict = areConcurrent(sorted[i]!, sorted[j]!);
        if (verdict === undefined) {
          undecidable += 1;
          continue;
        }
        if (!verdict) continue;
        participating.add(sorted[i]!.opId);
        participating.add(sorted[j]!.opId);
      }
    }

    if (participating.size === 0) continue;

    conflicts.push({
      entityId: group.entityId,
      path: group.path,
      opIds: sorted.filter((op) => participating.has(op.opId)).map((op) => op.opId),
      resolution: resolutionOf(group.path),
    });
  }

  return { conflicts, undecidable };
}
