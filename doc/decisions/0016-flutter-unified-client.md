# ADR-0016：以 Flutter 统一三端客户端，MVP 不再引入 pi

- **Status**: Accepted
- **Date**: 2026-11-12
- **Supersedes**: [ADR-0003](./0003-pi-as-agent-kernel.md) 在 MVP 范围内的适用性

## Context

需求方给出了一条新的硬约束：**整体使用 Flutter 开发**，同时要求「软件内容不得臃肿杂乱，文件规范整洁」，并直接进入 MVP 制作。

这条约束与之前的三项决策正面冲突，必须显式处理，不能假装它们还能同时成立：

| 既有决策 | 与 Flutter 的冲突 |
| --- | --- |
| ADR-0003：pi 作为 agent 内核 | pi 是 Node.js + TypeScript，Flutter 运行时里没有 Node |
| ADR-0010：三端各自最小可行个体 | Electron（Windows/Linux）+ 原生或 Capacitor（Android）是三套技术栈 |
| core-sync 的 TypeScript 实现（4148 行） | Dart 无法直接引用 |

同时也要看到 Flutter 带来的**真实收益**，它不只是妥协：

- 一套代码覆盖 Windows、Linux、Android —— 正好是 ADR-0002 圈定的三个目标平台
- 数据层只有**一份实现**。这直接消解了 ADR-0006 遗留的那个大坑：原先 Android 若走原生 Kotlin，就等于要把 ULID / HLC / 折叠顺序用另一种语言重写一遍，两套实现必须比特级一致，否则设备会静默分叉
- UI 与数据同语言，不需要 IPC 或 FFI 桥接

## Decision

1. **客户端统一为 Flutter 单代码库**，目标平台 Windows / Linux / Android。原 TypeScript monorepo 从 `main` 移除，保留在 git 历史（提交 `5e93ffc`）中作为数据层的规格来源。

2. **数据层在 Dart 内重写**，但**只移植 MVP 真正需要的部分**：

   | 保留 | 理由 |
   | --- | --- |
   | ULID、单调工厂 | 日志需要有序且唯一的标识 |
   | HLC 及 `observe` 的四个分支 | 「后写的覆盖先写的」不能依赖物理时钟准确性 |
   | 操作日志 + 折叠 | 它是本项目的身份，也是日后合并的基础 |
   | 快照与压缩（含 `base` 链） | 否则启动时间随使用天数单调恶化 |

   | 暂不移植 | 理由 |
   | --- | --- |
   | 同步前沿、`SourceClaim`、墓碑裁剪 | 单机不存在并发与离线设备，实现了也没有验证对象 |
   | 冲突表达与 `causalContext` | 单机不可能并发；字段是可选设计，日后补上不破坏兼容 |

3. **Agent 层不引入 pi**，改为直接对接 OpenAI 兼容的 `/chat/completions`，工具调用循环自行实现（约 60 行）。这与 ADR-0007「全部云端 API」的结论一致，且省掉了「pi 需要 Node」这个全部风险的地基。

4. **MVP 不做跨设备同步**。这与 ADR-0010「先做各端最小可行个体，最后做互联」本来就是一回事，不是新的妥协。

## Consequences

**正面**

- 三端同一份代码，数据层只有一处实现，「两套实现静默分叉」这个最坏失败模式被结构性消除
- 依赖数量压到 4 个（通知 / 时间时区 / 路径 / HTTP），没有 SDK、没有状态管理框架
- 数据层仍然写着操作日志，日后恢复同步时**不需要重写存储**，只需要加上前沿与合并

**负面与待偿还**

- **pi 的能力没有了**：多步规划、子 agent、durable 会话恢复都需要自己补，或者日后以「本地 sidecar 服务」的形式请回来。这一条的代价是真实的，不该被淡化
- **提醒能力在桌面端是降级的**：Android 走 `AlarmManager`，关闭应用后仍会响；Windows/Linux 只有进程内定时器，需要应用在运行。界面上如实写明了这一点
- **多端同步仍然缺失**，而它是产品的核心承诺之一。ADR-0005 的 CRDT 结论仍然有效，只是尚未落地
- 压缩与快照的正确性依赖 `compactedSnapshot` 的 `base` 参数被正确传递。这一点已由 `test/core/snapshot_test.dart` 的「压缩两次 == 压缩一次」钉住

## Alternatives considered

**Flutter UI + Node sidecar 跑 pi** — 能保留 agent 能力。被否决作为 MVP 方案：三端各自打包与守护一个 Node 进程，与「安装即用」和「不臃肿」直接冲突，且首先要把 pi 的 RPC 模式啃下来。

**保留 TypeScript 数据层，用 FFI 给 Flutter 调用** — 数据层只写一遍。被否决：Dart FFI 需要把 TypeScript 编译成 C ABI，工程复杂度远高于重写 400 行的 Dart 版本。

**继续 Electron + Capacitor + Kotlin** — 三个技术栈三份 UI。被否决：与「整体使用 Flutter」的明确要求冲突。

## 相关

- [ADR-0002](./0002-target-platforms.md) 的目标平台未变
- [ADR-0005](./0005-crdt-sync-basis.md) 的 CRDT 结论仍然有效，待同步功能落地时启用
- [ADR-0006](./0006-android-thin-client.md) 中「Android 需要另写一份数据层」的隐患，由本决策消除
- [ADR-0011](./0011-reminder-exactly-once.md) 的「下放给系统闹钟」结论保留，但桌面端只能部分实现
