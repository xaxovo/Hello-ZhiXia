/**
 * @hzx/core-sync —— 数据层契约。
 *
 * 这个包是**三端共用**的（Windows / Linux / Android）。它只包含类型、纯函数与
 * 不依赖具体平台的实现，因此可以被任何一端的运行时直接引用。
 *
 * 分成八个部分，对应 data-model.md 的「第一天必须做对」的约定：
 *
 * | 模块 | 对应约定 |
 * | --- | --- |
 * | `id.ts` | 标识符：ULID |
 * | `clock.ts` | 逻辑时钟：HLC |
 * | `op.ts` | 写入方式：只追加操作日志 |
 * | `frontier.ts` | 同步前沿：连续前缀的因果摘要 —— 裁剪与压缩共用的安全判据 |
 * | `compaction.ts` | 快照与日志压缩，以及压缩之后的对账契约 |
 * | `conflict.ts` | 冲突表达与并发判定 |
 * | `deletion.ts` | 删除：墓碑与两级删除语义 |
 * | `schema.ts` | Schema 版本化 |
 *
 * 最后一条约定的「三端共用同一个数据层包」，就是这个包本身。
 *
 * `frontier.ts` / `compaction.ts` / `conflict.ts` 三个模块合起来回答了
 * open-questions 的 #13、#14、#15 —— 那三个问题看起来是三件事，
 * 实际问的是同一个问题：**「这台设备到底确凿收到了哪些操作？」**
 */

export * from "./clock.js";
export * from "./compaction.js";
export * from "./conflict.js";
export * from "./deletion.js";
export * from "./frontier.js";
export * from "./id.js";
export * from "./op.js";
export * from "./schema.js";
