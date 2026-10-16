import { describe, expect, it } from "vitest";

import type { HlcTimestamp } from "./clock.js";
import {
  advanceFromClaim,
  advanceFrontier,
  allFrontiersCover,
  claimFor,
  confirmedFrontier,
  emptyFrontier,
  frontierCovers,
  frontierEquals,
  latestSeenPerSource,
  mergeFrontier,
  minFrontier,
  type Frontier,
  type SourceClaim,
} from "./frontier.js";
import { ulid } from "./id.js";
import type { Op } from "./op.js";

function hlc(wall: number, deviceId: string, counter = 0): HlcTimestamp {
  return { wall, counter, deviceId };
}

let seq = 0;

function makeOp(deviceId: string, wall: number): Op {
  seq += 1;
  return {
    opId: ulid(seq),
    hlc: hlc(wall, deviceId),
    entityId: ulid(7),
    type: "t",
    payload: null,
    schemaVersion: 1,
  };
}

describe("advanceFrontier", () => {
  it("按来源归档，且只前进不回退", () => {
    const early = hlc(100, "A");
    const late = hlc(200, "A");

    const advanced = advanceFrontier(advanceFrontier(emptyFrontier(), "A", early), "A", late);
    expect(frontierCovers(advanced, "A", early)).toBe(true);
    expect(frontierCovers(advanced, "A", late)).toBe(true);

    // 更早的时间戳不会让前沿倒退，且原对象被直接返回（无谓的复制没有必要）
    const regressed = advanceFrontier(advanced, "A", early);
    expect(regressed).toBe(advanced);
    expect(frontierCovers(regressed, "A", late)).toBe(true);
  });

  it("拒绝把时间戳记到别的来源名下", () => {
    expect(() => advanceFrontier(emptyFrontier(), "B", hlc(100, "A"))).toThrow();
  });

  it("未知来源一律不覆盖", () => {
    expect(frontierCovers(emptyFrontier(), "A", hlc(1, "A"))).toBe(false);
    expect(frontierCovers({ A: hlc(10, "A") }, "A", hlc(11, "A"))).toBe(false);
    expect(frontierCovers({ A: hlc(10, "A") }, "A", hlc(10, "A"))).toBe(true);
    // 覆盖判断用三元组全序，counter 与 deviceId 都参与
    expect(frontierCovers({ A: hlc(10, "A", 0) }, "A", hlc(10, "A", 1))).toBe(false);
  });

  it("mergeFrontier 逐来源取最大值", () => {
    const merged = mergeFrontier({ A: hlc(10, "A") }, { A: hlc(20, "A"), B: hlc(5, "B") });

    expect(merged.A?.wall).toBe(20);
    expect(merged.B?.wall).toBe(5);
  });
});

describe("allFrontiersCover", () => {
  it("空集合返回 false ——「没有任何设备确认」不是确认", () => {
    // 数学上的「空集全称真」在这里是危险的方向：它会让一个空配对列表放行裁剪
    expect(allFrontiersCover([], "A", hlc(1, "A"))).toBe(false);
  });

  it("只要有一台没覆盖到就返回 false", () => {
    const frontiers: Frontier[] = [{ A: hlc(100, "A") }, { A: hlc(99, "A") }];

    expect(allFrontiersCover(frontiers, "A", hlc(99, "A"))).toBe(true);
    expect(allFrontiersCover(frontiers, "A", hlc(100, "A"))).toBe(false);
  });

  it("某台设备的前沿里没有这个来源时也算没覆盖", () => {
    const frontiers: Frontier[] = [{ A: hlc(100, "A") }, { B: hlc(100, "B") }];

    expect(allFrontiersCover(frontiers, "A", hlc(1, "A"))).toBe(false);
  });
});

describe("minFrontier / confirmedFrontier", () => {
  it("逐来源取最小", () => {
    const min = minFrontier([
      { A: hlc(100, "A"), B: hlc(50, "B") },
      { A: hlc(80, "A"), B: hlc(90, "B") },
    ]);

    expect(min.A?.wall).toBe(80);
    expect(min.B?.wall).toBe(50);
  });

  it("某来源只有部分设备覆盖时，该来源整个被排除", () => {
    // 一半人说有 A、另一半人只说有 B：A 与 B 都不可安全压缩
    expect(minFrontier([{ A: hlc(100, "A") }, { B: hlc(100, "B") }])).toEqual({});
  });

  it("空数组 → 空前沿（什么都不可动）", () => {
    expect(minFrontier([])).toEqual({});
  });

  it("有设备尚未上报时安全前沿为空", () => {
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", { A: hlc(100, "A") }],
      ["B", undefined],
    ]);

    expect(confirmedFrontier(byDevice)).toEqual({});
  });

  it("全部上报时给出所有设备都覆盖的那一段", () => {
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", { A: hlc(100, "A"), B: hlc(30, "B") }],
      ["B", { A: hlc(90, "A"), B: hlc(30, "B") }],
    ]);

    const safe = confirmedFrontier(byDevice);
    expect(safe.A?.wall).toBe(90);
    expect(safe.B?.wall).toBe(30);
  });

  it("空配对列表 → 空前沿", () => {
    expect(confirmedFrontier(new Map())).toEqual({});
  });
});

describe("latestSeenPerSource 为什么不能当安全判据（#15 的坑）", () => {
  it("有洞时它照样报出最大值，于是对缺失的那条产生假阳性覆盖", () => {
    // 收到了 A 的 h1 与 h3，漏了 h2
    const seen = latestSeenPerSource([makeOp("A", 100), makeOp("A", 300)]);

    expect(seen.A?.wall).toBe(300);
    // ⚠️ 下面这个断言记录的是**危险行为**，不是期望行为：
    // 它会声称「h2（wall=200）也覆盖到了」，而实际上 h2 从来没有收到过。
    // 这正是「最新 HLC」不能用来判断「对端收到了某条操作」的原因，
    // 也是墓碑裁剪必须改用同步前沿的理由。若有人想「优化」掉这个行为，
    // 请先读完 frontier.ts 的模块说明。
    expect(frontierCovers(seen, "A", hlc(200, "A"))).toBe(true);
  });
});

describe("advanceFromClaim —— 连续前缀的证明", () => {
  const a1 = makeOp("A", 1);
  const a2 = makeOp("A", 2);
  const a3 = makeOp("A", 3);
  const complete: Op[] = [a1, a2, a3];
  const claim: SourceClaim = { source: "A", count: 3, head: a3.hlc };

  it("条数与 head 都吻合 → 推进到 head，且此前的一切都被覆盖", () => {
    const frontier = advanceFromClaim(emptyFrontier(), complete, claim);

    expect(frontierCovers(frontier, "A", a1.hlc)).toBe(true);
    expect(frontierCovers(frontier, "A", a2.hlc)).toBe(true);
    expect(frontierCovers(frontier, "A", a3.hlc)).toBe(true);
    expect(frontier.A).toEqual(a3.hlc);
  });

  it("过期的声明：条数凑巧相同、但最大 HLC 对不上 → 拒绝推进", () => {
    // 手里是 a1 与 a3（漏了 a2），条数正好也是 2 —— 只比条数就会被骗过
    const stale: SourceClaim = { source: "A", count: 2, head: a2.hlc };

    expect(advanceFromClaim(emptyFrontier(), [a1, a3], stale)).toEqual({});
  });

  it("条数不足 → 拒绝推进", () => {
    expect(advanceFromClaim(emptyFrontier(), [a1], claim)).toEqual({});
  });

  it("重复投递同一条操作不会让条数虚高 → 仍然正确推进", () => {
    // 若不去重，条数会算成 3 而声明说 1，就会平白拒绝一次合法的推进
    const frontier = advanceFromClaim(emptyFrontier(), [a1, a1, a1], {
      source: "A",
      count: 1,
      head: a1.hlc,
    });

    expect(frontierCovers(frontier, "A", a1.hlc)).toBe(true);
  });

  it("声明与来源不自洽 → 拒绝推进", () => {
    const bogus: SourceClaim = { source: "A", count: 3, head: hlc(3, "B") };

    expect(advanceFromClaim(emptyFrontier(), complete, bogus)).toEqual({});
  });

  it("推进只影响该来源，其他来源保持原样", () => {
    const start: Frontier = { B: hlc(50, "B") };
    const frontier = advanceFromClaim(start, complete, claim);

    expect(frontier.B).toEqual(hlc(50, "B"));
    expect(frontier.A).toEqual(a3.hlc);
  });

  it("claimFor 的计数与 head 与操作集合一致；无该来源时返回 undefined", () => {
    expect(claimFor(complete, "A")).toEqual({ source: "A", count: 3, head: a3.hlc });
    expect(claimFor(complete, "Z")).toBeUndefined();
  });
});

describe("序列化与比较", () => {
  it("前沿是可序列化的普通对象（协议字段，不能是 Map）", () => {
    const frontier: Frontier = { A: hlc(10, "A", 2), B: hlc(20, "B") };
    const roundTripped = JSON.parse(JSON.stringify(frontier)) as Frontier;

    expect(roundTripped).toEqual(frontier);
    expect(frontierEquals(roundTripped, frontier)).toBe(true);
  });

  it("frontierEquals 逐来源比较", () => {
    expect(frontierEquals({}, {})).toBe(true);
    expect(frontierEquals({ A: hlc(1, "A") }, { A: hlc(1, "A") })).toBe(true);
    expect(frontierEquals({ A: hlc(1, "A") }, { A: hlc(2, "A") })).toBe(false);
    expect(frontierEquals({ A: hlc(1, "A") }, {})).toBe(false);
    expect(frontierEquals({ A: hlc(1, "A") }, { A: hlc(1, "A"), B: hlc(1, "B") })).toBe(false);
  });
});
