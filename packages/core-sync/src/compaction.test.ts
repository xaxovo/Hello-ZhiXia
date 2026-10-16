import { describe, expect, it } from "vitest";

import type { HlcTimestamp } from "./clock.js";
import {
  compact,
  coverageGap,
  createSnapshot,
  migrateSnapshot,
  opsAboveFrontier,
  opsWithin,
  restoreFromSnapshot,
  safeToCompact,
} from "./compaction.js";
import {
  advanceFromClaim,
  confirmedFrontier,
  frontierCovers,
  type Frontier,
} from "./frontier.js";
import { ulid } from "./id.js";
import {
  createMemoryOpLog,
  mergeOps,
  type Op,
  type Reducer,
} from "./op.js";
import { MigrationRegistry } from "./schema.js";

function hlc(wall: number, deviceId: string): HlcTimestamp {
  return { wall, counter: 0, deviceId };
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

const ids = (ops: readonly Op[]): string[] => ops.map((op) => op.opId);

/**
 * 一个**可交换且幂等**的折叠（取最大 wall），即 data-model.md 第七节要求的
 * CRDT / LWW 语义。快照重建的正确性依赖这个前提，因此测试里必须用它，
 * 而不是用「计数」这类不满足前提的折叠。
 */
const foldMaxWall: Reducer<number> = (state, op) => Math.max(state, op.hlc.wall);

// 一批固定操作：A 三条、B 一条
const a1 = makeOp("A", 100);
const a2 = makeOp("A", 200);
const a3 = makeOp("A", 300);
const b1 = makeOp("B", 150);

const ALL_OPS = [a1, a2, a3, b1];

/** A 是全量节点：有全部操作。 */
function fullLog() {
  const log = createMemoryOpLog();
  mergeOps(log, ALL_OPS);
  return log;
}

const frontierAll: Frontier = { A: a3.hlc, B: b1.hlc };

/** 落后的设备：少一条 a3。 */
const frontierBehindA3: Frontier = { A: a2.hlc, B: b1.hlc };

function snapshotOptions(byDevice: ReadonlyMap<string, Frontier | undefined>) {
  return {
    byDevice,
    snapshotId: ulid(1234),
    schemaVersion: 1,
    initial: 0,
    fold: foldMaxWall,
  };
}

describe("safeToCompact", () => {
  it("逐来源取所有设备都已确认的那段", () => {
    const safe = safeToCompact(
      new Map<string, Frontier | undefined>([
        ["A", frontierAll],
        ["B", frontierBehindA3],
      ]),
    );

    expect(safe.A).toEqual(a2.hlc);
    expect(safe.B).toEqual(b1.hlc);
  });

  it("有设备尚未上报时返回空前沿（宁可不动，也不猜）", () => {
    const safe = safeToCompact(
      new Map<string, Frontier | undefined>([
        ["A", frontierAll],
        ["B", undefined],
      ]),
    );

    expect(safe).toEqual({});
  });

  it("空配对列表返回空前沿", () => {
    expect(safeToCompact(new Map())).toEqual({});
  });
});

describe("opsWithin / opsAboveFrontier —— 对账被前沿分成两段", () => {
  it("前沿之下与之上正好把日志分成两段，不重不漏", () => {
    const log = fullLog();
    const safe = safeToCompact(
      new Map<string, Frontier | undefined>([
        ["A", frontierAll],
        ["B", frontierBehindA3],
      ]),
    );

    // 返回顺序是操作的全序（按 HLC），不是创建顺序：b1 在 a2 之前
    expect(ids(opsWithin(log, safe))).toEqual(ids([a1, b1, a2]));
    expect(ids(opsAboveFrontier(log, safe))).toEqual(ids([a3]));
  });

  it("前沿之下的操作，每个已上报设备都必然已确认 —— 这正是压缩的前提", () => {
    const log = fullLog();
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);
    const safe = safeToCompact(byDevice);

    for (const frontier of byDevice.values()) {
      expect(frontier).toBeDefined();
      for (const op of opsWithin(log, safe)) {
        expect(frontierCovers(frontier!, op.hlc.deviceId, op.hlc)).toBe(true);
      }
    }
  });

  it("对端在中间漏了一条时，它的前沿停在洞之前 —— 洞之后的日志不会被压掉", () => {
    const log = fullLog();
    // B 有 a1 与 a3，漏了 a2：它的连续前缀只能停在 a1
    const frontierWithHole: Frontier = { A: a1.hlc, B: b1.hlc };
    const safe = safeToCompact(
      new Map<string, Frontier | undefined>([
        ["A", frontierAll],
        ["B", frontierWithHole],
      ]),
    );

    expect(safe.A).toEqual(a1.hlc);
    expect(frontierCovers(safe, "A", a2.hlc)).toBe(false);

    const { removed } = compact(log, snapshotOptions(new Map([["A", frontierAll], ["B", frontierWithHole]])));

    expect(removed).toBe(2); // a1 与 b1
    expect(log.has(a2.opId)).toBe(true);
    expect(log.has(a3.opId)).toBe(true);
    // 补齐时不漏：洞以及洞之后的都在「前沿之上」
    expect(ids(opsAboveFrontier(log, frontierWithHole))).toEqual(ids([a2, a3]));
  });

  it("前沿之下的操作对端必然已有，因此压缩不会让它缺数据", () => {
    const log = fullLog();
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);
    const { safe } = compact(log, snapshotOptions(byDevice));

    // B 说自己缺什么时，答案里永远不会出现被压掉的那一段（它本来就有）
    expect(ids(opsAboveFrontier(log, frontierBehindA3))).toEqual(ids([a3]));
    expect(coverageGap(safe, frontierBehindA3)).toEqual([]);
  });
});

describe("compact", () => {
  it("先折叠再删除：快照覆盖的正是被删掉的那些操作", () => {
    const log = fullLog();
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);

    const { snapshot, safe, removed } = compact(log, snapshotOptions(byDevice));

    expect(removed).toBe(3);
    expect(log.size).toBe(1);
    expect(snapshot.frontier).toEqual(safe);
    // 折叠结果等于被删掉那三条的折叠
    expect(snapshot.state).toBe(foldMaxWall(foldMaxWall(foldMaxWall(0, a1), a2), b1));
  });

  it("createSnapshot 是只读的，不清空日志", () => {
    const log = fullLog();
    const before = ids(log.all());

    createSnapshot(log, { A: a2.hlc }, {
      snapshotId: ulid(99),
      schemaVersion: 1,
      initial: 0,
      fold: foldMaxWall,
    });

    expect(ids(log.all())).toEqual(before);
  });

  it("有设备没上报时一条都不压", () => {
    const log = fullLog();
    const { safe, removed } = compact(
      log,
      snapshotOptions(new Map<string, Frontier | undefined>([
        ["A", frontierAll],
        ["B", undefined],
      ])),
    );

    expect(safe).toEqual({});
    expect(removed).toBe(0);
    expect(log.size).toBe(4);
  });

  it("retain 保住的 pin 墓碑留在日志里（可以继续传播），且不会被当成缺失的操作", () => {
    const log = fullLog();
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);

    const { snapshot, removed } = compact(log, {
      ...snapshotOptions(byDevice),
      // 假设 a1 是一条 pin 住的墓碑：彻底删除流程进行中，必须继续带着它
      retain: (op) => op.opId === a1.opId,
    });

    expect(removed).toBe(2);
    expect(log.has(a1.opId)).toBe(true);
    // 它已经折进快照，因此不该再出现在「尾部」里被重复施加
    expect(ids(opsAboveFrontier(log, snapshot.frontier))).toEqual(ids([a3]));
  });

  it("结果与到达顺序、重复投递无关（#13 的第 1、2 条约束）", () => {
    const forward = fullLog();
    const backward = createMemoryOpLog();
    mergeOps(backward, [b1, a3, a2, a1, a1]); // 乱序 + 重复

    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);

    expect(ids(backward.all())).toEqual(ids(forward.all()));

    const left = compact(forward, snapshotOptions(byDevice));
    const right = compact(backward, snapshotOptions(byDevice));

    expect(right.removed).toBe(left.removed);
    expect(right.snapshot.state).toBe(left.snapshot.state);
    expect(right.safe).toEqual(left.safe);
  });
});

describe("restoreFromSnapshot", () => {
  it("快照 + 前沿之上的尾部 = 与全量折叠完全一致", () => {
    const log = fullLog();
    const original = log.all();
    const expected = original.reduce<number>((state, op) => foldMaxWall(state, op), 0);

    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);
    const { snapshot } = compact(log, snapshotOptions(byDevice));

    expect(restoreFromSnapshot(snapshot, log, foldMaxWall)).toBe(expected);
  });

  it("retain 留下的操作会影响不到重建结果（它在快照里已经算过一次）", () => {
    const log = fullLog();
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);
    const { snapshot } = compact(log, {
      ...snapshotOptions(byDevice),
      retain: (op) => op.opId === a2.opId,
    });

    // a2 仍在日志里，但重建只折叠前沿之上的操作 → 不会出现偏差
    expect(log.has(a2.opId)).toBe(true);
    expect(restoreFromSnapshot(snapshot, log, foldMaxWall)).toBe(300);
  });
});

describe("coverageGap —— 什么时候必须传快照", () => {
  it("新配对的设备（前沿为空）追不上被压缩的区间", () => {
    const log = fullLog();
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierAll],
    ]);
    const { snapshot } = compact(log, snapshotOptions(byDevice));

    expect(coverageGap(snapshot.frontier, {})).toEqual(["A", "B"]);
  });

  it("已经确认过安全水位的设备可以直接用尾部追上，不需要快照", () => {
    const log = fullLog();
    const byDevice = new Map<string, Frontier | undefined>([
      ["A", frontierAll],
      ["B", frontierBehindA3],
    ]);
    const { snapshot } = compact(log, snapshotOptions(byDevice));

    expect(coverageGap(snapshot.frontier, frontierBehindA3)).toEqual([]);
  });
});

describe("采纳快照后的前沿推进（压缩区间的补齐路径）", () => {
  it("采纳快照等价于把前沿直接推进到快照前沿", () => {
    // 这是 #13 第 4 条里最难的那一步：被压掉的操作没法逐条补，
    // 但快照本身就是「这一段我都收全了」的证书 —— 采纳它即可推进前沿。
    // 这里走一遍真实的 compact，避免手搓出一个和实现不一致的前沿。
    const log = fullLog();
    const { snapshot } = compact(
      log,
      snapshotOptions(
        new Map<string, Frontier | undefined>([
          ["A", frontierAll],
          ["B", frontierAll],
        ]),
      ),
    );

    const before: Frontier = {};
    const after: Frontier = { ...snapshot.frontier };

    expect(frontierCovers(before, "A", a3.hlc)).toBe(false);
    expect(frontierCovers(after, "A", a3.hlc)).toBe(true);
    expect(frontierCovers(after, "B", b1.hlc)).toBe(true);
  });
});

describe("migrateSnapshot —— 快照也受 schema 版本化约束（#13 第 5 条）", () => {
  const registry = new MigrationRegistry()
    .register({ from: 0, to: 1, migrate: (value) => (typeof value === "number" ? value + 1 : value) })
    .register({ from: 1, to: 2, migrate: (value) => (typeof value === "number" ? value * 10 : value) });

  it("沿迁移链把快照迁到最新版本", () => {
    const snapshot = createSnapshot(fullLog(), { A: a1.hlc }, {
      snapshotId: ulid(5),
      schemaVersion: 0,
      initial: 0,
      fold: foldMaxWall,
    });

    const migrated = migrateSnapshot(snapshot, registry);

    expect(migrated.schemaVersion).toBe(2);
    expect(migrated.state).toBe((snapshot.state + 1) * 10);
    expect(migrated.frontier).toEqual(snapshot.frontier);
  });

  it("已是最新版本时原样返回", () => {
    const snapshot = createSnapshot(fullLog(), { A: a1.hlc }, {
      snapshotId: ulid(6),
      schemaVersion: 2,
      initial: 0,
      fold: foldMaxWall,
    });

    expect(migrateSnapshot(snapshot, registry)).toBe(snapshot);
  });

  it("快照版本高于本端时抛错，而不是按旧 schema 静默解释", () => {
    const fromFuture = {
      snapshotId: ulid(8),
      frontier: {},
      schemaVersion: 9,
      state: 1,
    };

    expect(() => migrateSnapshot(fromFuture, registry)).toThrow();
  });
});

describe("前沿推进与压缩的配合", () => {
  it("用声明推进出的前沿可以直接当作压缩水位使用", () => {
    // 对端上报「我手上有 A 的全部 3 条」，本地据此推进前沿，再算安全水位
    const reported = advanceFromClaim({}, [a1, a2, a3], {
      source: "A",
      count: 3,
      head: a3.hlc,
    });
    const safe = confirmedFrontier(
      new Map<string, Frontier | undefined>([
        ["A", frontierAll],
        ["B", reported],
      ]),
    );

    expect(safe.A).toEqual(a3.hlc);
  });
});
