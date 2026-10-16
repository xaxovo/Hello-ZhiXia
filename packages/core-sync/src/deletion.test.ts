import { describe, expect, it } from "vitest";

import { compareHlc, type HlcTimestamp } from "./clock.js";
import {
  confirmPurge,
  forcePurge,
  isTombstoneAtRisk,
  isTombstonePrunable,
  pruneWatermark,
  purgeProgress,
  TOMBSTONE_RETENTION_MS,
  type PruneWatermark,
  type PurgeRequest,
  type Tombstone,
} from "./deletion.js";
import type { Frontier } from "./frontier.js";
import { ulid } from "./id.js";

const NOW = 1_700_000_000_000;

function hlc(wall: number, deviceId = "A"): HlcTimestamp {
  return { wall, counter: 0, deviceId };
}

function tombstone(deletedAtWall: number, pinned?: boolean): Tombstone {
  const base: Tombstone = {
    entityId: ulid(deletedAtWall),
    deletedAt: hlc(deletedAtWall),
    deletedBy: "A",
  };
  return pinned === true ? { ...base, pinned: true } : base;
}

/** 一个把 `sources` 全部推进到 `wall` 的前沿 —— 相当于「这些来源我都收全了」。 */
function frontier(sources: readonly string[], wall: number): Frontier {
  const result: Record<string, HlcTimestamp> = {};
  for (const source of sources) result[source] = hlc(wall, source);
  return result;
}

/** 每台设备都已上报、且各自都覆盖了全部来源的完整水位。 */
function completeWatermark(devices: readonly string[], wall = NOW): PruneWatermark {
  // 返回类型必须显式写成元组：`.map()` 的返回值不会获得 `new Map()` 的
  // 上下文元组推断，否则会推出 `(string | Frontier)[][]` 而无法赋值。
  const entries = devices.map((id): [string, Frontier] => [id, frontier(devices, wall)]);
  return pruneWatermark(new Map(entries));
}

/** 有一台设备从未上报 —— 水位不完整，裁剪必须被拒。 */
function incompleteWatermark(wall = NOW): PruneWatermark {
  return pruneWatermark(
    new Map<string, Frontier | undefined>([
      ["A", frontier(["A", "offline"], wall)],
      ["offline", undefined],
    ]),
  );
}

describe("pruneWatermark", () => {
  it("保留期墙钟取各设备**自身**进度的最小值", () => {
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([
        ["A", frontier(["A"], NOW)],
        ["B", frontier(["B"], NOW - 5_000)],
      ]),
    );

    expect(watermark.wall).toBe(NOW - 5_000);
    expect(watermark.reported).toBe(2);
    expect(watermark.expected).toBe(2);
    expect(watermark.complete).toBe(true);
  });

  it("设备前沿里没有它自己的条目时墙钟退化为 -Infinity（保守，不猜）", () => {
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([["A", frontier(["B"], NOW)]]),
    );

    expect(watermark.wall).toBe(Number.NEGATIVE_INFINITY);
  });

  it("有设备从未上报时水位不完整", () => {
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([
        ["A", frontier(["A"], NOW)],
        ["B", undefined],
      ]),
    );

    expect(watermark.complete).toBe(false);
    expect(watermark.reported).toBe(1);
    expect(watermark.expected).toBe(2);
  });

  it("一台都没上报时，再旧的墓碑也不能裁剪", () => {
    const watermark = pruneWatermark(new Map<string, Frontier | undefined>([["A", undefined]]));

    expect(watermark.complete).toBe(false);
    expect(watermark.reported).toBe(0);
    expect(isTombstonePrunable(tombstone(NOW - TOMBSTONE_RETENTION_MS * 100), watermark)).toBe(false);
  });

  it("空配对列表不算完整水位（没有任何设备可以确认）", () => {
    expect(pruneWatermark(new Map()).complete).toBe(false);
  });
});

/**
 * open-questions #15：水位必须是「同步前沿」，不能是「最新 HLC」。
 *
 * 下面这组用例全部针对「最新 HLC 判据会放行、前沿判据会拦住」的形态。
 */
describe("墓碑确认必须来自同步前沿（#15）", () => {
  const DELETED_AT = NOW - TOMBSTONE_RETENTION_MS * 2;

  it("某台设备从未收到墓碑时，即使所有设备的最新 HLC 都远超它，也不可裁剪", () => {
    // A 删除笔记 N，产生墓碑 T（HLC = DELETED_AT）。
    // 此后 A 与 B 再没有成功同步过，但各自都在本地持续写入到 NOW ——
    // 于是两边的「最新 HLC」都远超 T，按旧判据 T 早已可裁剪。
    const tomb = tombstone(DELETED_AT);
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([
        ["A", { A: hlc(NOW, "A"), B: hlc(NOW, "B") }],
        ["B", frontier(["B"], NOW)],
      ]),
    );

    // 水位是完整的，保留期也早就过了 —— 旧判据会放行
    expect(watermark.complete).toBe(true);
    expect(watermark.reported).toBe(2);
    expect(watermark.wall - DELETED_AT).toBeGreaterThanOrEqual(TOMBSTONE_RETENTION_MS);

    // 但 B 的前沿里根本没有 A 的墓碑 → 裁掉它，B 重连后 N 就复活了
    expect(isTombstonePrunable(tomb, watermark)).toBe(false);
    // 并且必须如实报警，而不是显示成「已彻底消失」
    expect(isTombstoneAtRisk(tomb, watermark)).toBe(true);
  });

  it("某台设备只差墓碑这一条也不算确认（连续前缀，差一条就是没收到）", () => {
    const tomb = tombstone(DELETED_AT);
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([
        ["A", { A: hlc(NOW, "A"), B: hlc(NOW, "B") }],
        ["B", { A: hlc(DELETED_AT - 1, "A"), B: hlc(NOW, "B") }],
      ]),
    );

    expect(watermark.complete).toBe(true);
    expect(watermark.wall - DELETED_AT).toBeGreaterThanOrEqual(TOMBSTONE_RETENTION_MS);
    expect(isTombstonePrunable(tomb, watermark)).toBe(false);
  });

  it("全部设备都覆盖墓碑、且保留期已过，才可裁剪", () => {
    const tomb = tombstone(DELETED_AT);
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([
        ["A", frontier(["A", "B"], NOW)],
        ["B", frontier(["A", "B"], NOW)],
      ]),
    );

    expect(isTombstonePrunable(tomb, watermark)).toBe(true);
    expect(isTombstoneAtRisk(tomb, watermark)).toBe(false);
  });

  it("被裁剪的风险与确认互斥：确认不齐时只报警、不放行", () => {
    const tomb = tombstone(DELETED_AT);
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([
        ["A", { A: hlc(NOW, "A"), B: hlc(NOW, "B") }],
        ["B", frontier(["B"], NOW)],
      ]),
    );

    expect(isTombstonePrunable(tomb, watermark)).toBe(false);
    expect(isTombstoneAtRisk(tomb, watermark)).toBe(true);
  });
});

describe("墓碑保留期", () => {
  it("保留期未到不可裁剪", () => {
    expect(isTombstonePrunable(tombstone(NOW - 1_000), completeWatermark(["A", "B"]))).toBe(false);
  });

  it("保留期已到可以裁剪", () => {
    const old = tombstone(NOW - TOMBSTONE_RETENTION_MS - 1);
    expect(isTombstonePrunable(old, completeWatermark(["A", "B"]))).toBe(true);
  });

  it("恰好到达保留期即可裁剪（与风险判定的边界一致）", () => {
    const boundary = tombstone(NOW - TOMBSTONE_RETENTION_MS);
    expect(isTombstonePrunable(boundary, completeWatermark(["A", "B"]))).toBe(true);
  });

  it("pinned 的墓碑永不裁剪（彻底删除流程进行中必须保留）", () => {
    const old = tombstone(NOW - TOMBSTONE_RETENTION_MS * 10, true);
    expect(isTombstonePrunable(old, completeWatermark(["A", "B"]))).toBe(false);
  });

  it("水位不完整时一律不裁剪，哪怕墓碑已经非常旧", () => {
    // 本次修复的核心：曾经用本机墙钟判断，只要本机时钟够快就会放行裁剪。
    const veryOld = tombstone(NOW - TOMBSTONE_RETENTION_MS * 10);
    expect(isTombstonePrunable(veryOld, incompleteWatermark())).toBe(false);
  });

  it("一台时钟快 180 天的设备不再能提前裁剪掉刚创建的墓碑", () => {
    // 修复前的可复现路径：isTombstonePrunable(tombstone(NOW), NOW + RETENTION + 1) === true。
    // 那台设备上的「刚删除」会被判定为可裁剪，而另一台真正离线很久的设备
    // 重连后会把数据复活。
    const watermark = pruneWatermark(
      new Map<string, Frontier | undefined>([
        ["fast", frontier(["fast"], NOW + TOMBSTONE_RETENTION_MS + 1)],
        ["offline", undefined],
      ]),
    );

    expect(isTombstonePrunable(tombstone(NOW), watermark)).toBe(false);
  });
});

describe("墓碑风险提示", () => {
  it("水位完整时不存在「可能复活」", () => {
    const old = tombstone(NOW - TOMBSTONE_RETENTION_MS * 2);
    expect(isTombstoneAtRisk(old, completeWatermark(["A", "B"]))).toBe(false);
  });

  it("水位不完整且墓碑已超过保留期时如实提示风险", () => {
    const old = tombstone(NOW - TOMBSTONE_RETENTION_MS - 1);
    expect(isTombstoneAtRisk(old, incompleteWatermark())).toBe(true);
  });

  it("新建的墓碑不报警，避免噪声淹没真正的问题", () => {
    expect(isTombstoneAtRisk(tombstone(NOW - 1_000), incompleteWatermark())).toBe(false);
  });

  it("pin 住的处理中墓碑不算风险", () => {
    const old = tombstone(NOW - TOMBSTONE_RETENTION_MS * 2, true);
    expect(isTombstoneAtRisk(old, incompleteWatermark())).toBe(false);
  });

  it("「可裁剪」与「有风险」互斥", () => {
    const old = tombstone(NOW - TOMBSTONE_RETENTION_MS - 1);
    const complete = completeWatermark(["A", "B"]);

    expect(isTombstonePrunable(old, complete)).toBe(true);
    expect(isTombstoneAtRisk(old, complete)).toBe(false);
    expect(isTombstonePrunable(old, incompleteWatermark())).toBe(false);
    expect(isTombstoneAtRisk(old, incompleteWatermark())).toBe(true);
  });
});

describe("彻底删除流程", () => {
  function request(targets: readonly string[], confirmed: readonly string[] = []): PurgeRequest {
    return {
      purgeId: ulid(NOW),
      requestedAt: hlc(NOW),
      targets,
      confirmed,
    };
  }

  it("区分已确认与未确认设备", () => {
    const progress = purgeProgress(request(["A", "B", "C"], ["A", "C"]));

    expect(progress.confirmed).toEqual(["A", "C"]);
    expect(progress.pending).toEqual(["B"]);
    expect(progress.canComplete).toBe(false);
  });

  it("全部确认后才能完成", () => {
    expect(purgeProgress(request(["A", "B"], ["A", "B"])).canComplete).toBe(true);
  });

  it("重复确认是幂等的", () => {
    const once = confirmPurge(request(["A", "B"]), "A");
    const twice = confirmPurge(once, "A");

    expect(once.confirmed).toEqual(["A"]);
    expect(twice.confirmed).toEqual(["A"]);
    expect(twice).toBe(once);
  });

  it("拒绝非目标设备的确认", () => {
    expect(() => confirmPurge(request(["A"]), "Z")).toThrow();
  });

  it("强制清除会移出未确认设备，并如实报告被撤销的设备", () => {
    const result = forcePurge(request(["A", "B", "C"], ["A"]));

    expect(result.revokedDevices).toEqual(["B", "C"]);
    expect(result.request.targets).toEqual(["A"]);
    expect(purgeProgress(result.request).canComplete).toBe(true);
  });

  it("全部已确认时强制清除不撤销任何设备", () => {
    const result = forcePurge(request(["A", "B"], ["A", "B"]));

    expect(result.revokedDevices).toEqual([]);
    expect(result.request.targets).toEqual(["A", "B"]);
  });
});

describe("HLC 与墓碑时间戳", () => {
  it("墓碑的 deletedAt 是全序可比较的 HLC（而不是裸墙钟）", () => {
    const earlier = tombstone(NOW).deletedAt;
    const later = hlc(NOW + 1);

    expect(compareHlc(earlier, later)).toBeLessThan(0);
  });
});
