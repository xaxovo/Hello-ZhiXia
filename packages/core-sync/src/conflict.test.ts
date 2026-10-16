import { describe, expect, it } from "vitest";

import { compareHlc, type HlcTimestamp } from "./clock.js";
import {
  areConcurrent,
  detectConflicts,
  isJsonPointer,
  joinPointer,
  pointerSegments,
  type JsonPointer,
} from "./conflict.js";
import { emptyFrontier, type Frontier } from "./frontier.js";
import { ulid, type Ulid } from "./id.js";
import { withCausalContext, type Op } from "./op.js";

function hlc(wall: number, deviceId: string): HlcTimestamp {
  return { wall, counter: 0, deviceId };
}

const ENTITY: Ulid = ulid(42);
const OTHER_ENTITY: Ulid = ulid(43);

let seq = 0;

interface OpSpec {
  readonly deviceId: string;
  readonly wall: number;
  readonly type?: string;
  readonly entityId?: Ulid;
  /** 传 `undefined` 表示**没有**盖因果上下文（用于验证「不可判定」路径）。 */
  readonly context?: Frontier;
}

function makeOp(spec: OpSpec): Op {
  seq += 1;
  const op: Op = {
    opId: ulid(seq),
    hlc: hlc(spec.wall, spec.deviceId),
    entityId: spec.entityId ?? ENTITY,
    type: spec.type ?? "note.setTitle",
    payload: null,
    schemaVersion: 1,
  };
  return spec.context === undefined ? op : withCausalContext(op, spec.context);
}

/** 测试用的「实体模型」：由操作类型决定它写了哪个位置。 */
function pathOf(op: Op): JsonPointer {
  if (op.type === "note.setTitle") return "/title";
  if (op.type === "note.setBody") return "/body";
  return "";
}

describe("JSON Pointer（冲突位置的寻址方式）", () => {
  it("空串表示整个实体，是合法指针", () => {
    expect(isJsonPointer("")).toBe(true);
    expect(pointerSegments("")).toEqual([]);
    expect(joinPointer()).toBe("");
  });

  it("非空指针必须以 / 开头", () => {
    expect(isJsonPointer("/title")).toBe(true);
    expect(isJsonPointer("title")).toBe(false);
  });

  it("~ 只能作为 ~0 / ~1 出现", () => {
    expect(isJsonPointer("/a~0b")).toBe(true);
    expect(isJsonPointer("/a~1b")).toBe(true);
    expect(isJsonPointer("/a~2b")).toBe(false);
    expect(isJsonPointer("/a~")).toBe(false);
  });

  it("转义与反转义互逆", () => {
    expect(joinPointer("a/b", "c~d")).toBe("/a~1b/c~0d");
    expect(pointerSegments("/a~1b/c~0d")).toEqual(["a/b", "c~d"]);
    expect(pointerSegments(joinPointer("x/y", "z~w", ""))).toEqual(["x/y", "z~w", ""]);
  });

  it("反转义顺序符合 RFC 6901：~01 解出 ~1（先解 ~1 再解 ~0）", () => {
    expect(pointerSegments("/a~01b")).toEqual(["a~1b"]);
  });

  it("非法指针抛错，而不是被静默当成别的路径", () => {
    expect(() => pointerSegments("nope")).toThrow();
  });
});

describe("areConcurrent", () => {
  it("缺少因果上下文时返回 undefined ——「不可判定」不等于「不并发」", () => {
    const a = makeOp({ deviceId: "A", wall: 100 });
    const b = makeOp({ deviceId: "B", wall: 101 });

    expect(areConcurrent(a, b)).toBeUndefined();
  });

  it("HLC 更晚并不蕴含因果更晚：只比时间戳无法判定并发", () => {
    const earlier = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const later = makeOp({ deviceId: "B", wall: 101, context: emptyFrontier() });

    // 时间戳确实更大……
    expect(compareHlc(later.hlc, earlier.hlc)).toBeGreaterThan(0);
    // ……但它并没有见过 earlier，所以二者是并发的。
    // 这正是 #14 需要 `causalContext` 的原因：HLC 给的是全序，不是因果序。
    expect(areConcurrent(later, earlier)).toBe(true);
  });

  it("a 见过 b → 不并发", () => {
    const b = makeOp({ deviceId: "B", wall: 100, context: emptyFrontier() });
    const a = makeOp({ deviceId: "A", wall: 200, context: { B: b.hlc } });

    expect(areConcurrent(a, b)).toBe(false);
  });

  it("互相都没见过 → 并发", () => {
    const a = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const b = makeOp({ deviceId: "B", wall: 200, context: emptyFrontier() });

    expect(areConcurrent(a, b)).toBe(true);
  });

  it("同一设备自己产生的操作永不并发", () => {
    const first = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const second = makeOp({ deviceId: "A", wall: 200, context: emptyFrontier() });

    expect(areConcurrent(first, second)).toBe(false);
  });

  it("同一条操作与自己是非并发", () => {
    const a = makeOp({ deviceId: "A", wall: 1, context: emptyFrontier() });

    expect(areConcurrent(a, a)).toBe(false);
  });
});

describe("detectConflicts", () => {
  it("同一位置的并发写入报一处冲突，操作按全序排列", () => {
    const a = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const b = makeOp({ deviceId: "B", wall: 200, context: emptyFrontier() });

    const { conflicts, undecidable } = detectConflicts([b, a], { pathOf });

    expect(undecidable).toBe(0);
    expect(conflicts).toHaveLength(1);
    expect(conflicts[0]!.entityId).toBe(ENTITY);
    expect(conflicts[0]!.path).toBe("/title");
    expect(conflicts[0]!.opIds).toEqual([a.opId, b.opId]);
    // 没声明策略的位置一律交给人 —— 保守的那一边
    expect(conflicts[0]!.resolution).toBe("manual");
  });

  it("因果有序的两次写入不是冲突（顺序修改同一个字段）", () => {
    const first = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const second = makeOp({ deviceId: "B", wall: 200, context: { A: first.hlc } });

    expect(detectConflicts([first, second], { pathOf }).conflicts).toEqual([]);
  });

  it("只有参与并发的那几条被列进冲突，之后的顺序写入不被牵连", () => {
    const a = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const b = makeOp({ deviceId: "B", wall: 200, context: emptyFrontier() });
    const c = makeOp({ deviceId: "C", wall: 300, context: { A: a.hlc, B: b.hlc } });

    const { conflicts } = detectConflicts([a, b, c], { pathOf });

    expect(conflicts).toHaveLength(1);
    expect(conflicts[0]!.opIds).toEqual([a.opId, b.opId]);
  });

  it("三方并发写同一位置只报一处冲突，且包含全部三方", () => {
    const a = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const b = makeOp({ deviceId: "B", wall: 200, context: emptyFrontier() });
    const c = makeOp({ deviceId: "C", wall: 300, context: emptyFrontier() });

    const { conflicts } = detectConflicts([a, b, c], { pathOf });

    expect(conflicts).toHaveLength(1);
    expect(conflicts[0]!.opIds).toEqual([a.opId, b.opId, c.opId]);
  });

  it("不同位置、不同实体都不算冲突", () => {
    const title = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const body = makeOp({ deviceId: "B", wall: 200, type: "note.setBody", context: emptyFrontier() });
    const elsewhere = makeOp({
      deviceId: "C",
      wall: 300,
      entityId: OTHER_ENTITY,
      context: emptyFrontier(),
    });

    expect(detectConflicts([title, body, elsewhere], { pathOf }).conflicts).toEqual([]);
  });

  it("缺因果上下文时不产生冲突，但如实计入 undecidable（不静默）", () => {
    const a = makeOp({ deviceId: "A", wall: 100 });
    const b = makeOp({ deviceId: "B", wall: 200 });

    const result = detectConflicts([a, b], { pathOf });

    expect(result.conflicts).toEqual([]);
    expect(result.undecidable).toBe(1);
  });

  it("已由自动策略解决的位置仍然产生条目 —— 可见性不因「自动解决」而豁免", () => {
    // ADR-0012 的要求：冲突宁可可见。resolution=auto 只说明「我们替你选了一个」，
    // 不说明「这件事不必让用户知道」。
    const a = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const b = makeOp({ deviceId: "B", wall: 200, context: emptyFrontier() });

    const { conflicts } = detectConflicts([a, b], {
      pathOf,
      resolutionOf: (path) => (path === "/title" ? "auto" : "manual"),
    });

    expect(conflicts).toHaveLength(1);
    expect(conflicts[0]!.resolution).toBe("auto");
  });

  it("entityIdOf 可以覆盖分组依据", () => {
    const a = makeOp({ deviceId: "A", wall: 100, context: emptyFrontier() });
    const b = makeOp({ deviceId: "B", wall: 200, context: emptyFrontier() });
    const other: Ulid = ulid(777);

    const result = detectConflicts([a, b], {
      pathOf,
      entityIdOf: (op) => (op.hlc.deviceId === "A" ? ENTITY : other),
    });

    expect(result.conflicts).toEqual([]);
  });

  it("pathOf 返回非法指针时抛错，而不是静默归到某个位置", () => {
    const a = makeOp({ deviceId: "A", wall: 100 });

    expect(() => detectConflicts([a], { pathOf: () => "title" })).toThrow();
  });
});
