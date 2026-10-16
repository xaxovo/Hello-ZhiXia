# 架构文档

本目录记录 **Hello-ZhiXia（知夏生活 / HZX）** 的架构设计与决策依据。

这些文档的存在本身就是为了解决一个问题：**决策会随着时间被遗忘**。三个月后没人记得「为什么不用中心服务器」，于是重新讨论一遍，或者更糟——有人按自己的想法实现了另一套。所以每一项重要取舍都留下 Context（当时面对什么）和 Consequences（我们接受了什么代价）。

## 文档索引

| 文档 | 内容 | 什么时候看 |
| --- | --- | --- |
| [overview.md](./overview.md) | 架构总览：目标、非目标、硬约束、分层、关键数据流、安全模型 | 第一次了解本项目；做任何跨模块设计前 |
| [data-model.md](./data-model.md) | 数据层契约：标识符、逻辑时钟、操作日志、删除语义、数据分类 | 写任何一行碰数据的代码前 |
| [decisions/](./decisions/) | 架构决策记录（ADR），一篇一个决策 | 想改某个既有设计时，先读对应 ADR |
| [open-questions.md](./open-questions.md) | 尚未决定的问题与已知风险 | 决定下一步做什么时 |

## ADR 格式

每篇 ADR 遵循同一结构：

- **Status** — `Proposed` / `Accepted` / `Superseded by ADR-XXXX` / `Deprecated`
- **Date** — 决策日期
- **Context** — 当时面对的问题与约束
- **Decision** — 决定了什么
- **Consequences** — 正面与负面后果（负面必须写，否则 ADR 没有价值）
- **Alternatives considered** — 考虑过但未采用的方案，以及为什么

## 如何新增 ADR

1. 取号：`decisions/` 下最大编号 + 1，写成四位数，例如 `0016-xxxx.md`
2. 复制任意一篇作为模板
3. 只写**已经决定**的事。还没定的写进 `open-questions.md`
4. 修改既有决策时**不要改原文件**，而是新增一篇并在旧文里标注 `Superseded by ADR-XXXX`

编号一旦分配就永不复用，即使那篇 ADR 后来被推翻。
