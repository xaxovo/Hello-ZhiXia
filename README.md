# Hello-ZhiXia

> **知夏生活（HZX）**

---

## 项目简介

Hello-ZhiXia（知夏生活，简称 **HZX**）是一个**跨平台、多设备自动同步、无中心数据服务器**的个人 agent 兼日常助手。

- **跨平台** — Windows、Linux、Android 三端，同一套数据与能力
- **多设备同步** — 任一端的改动自动出现在其他端，各端持有完整的结构化数据副本
- **无中心** — 用户数据不经过服务方；见面点只能看到密文与连接元数据
- **日常助手** — 日程、提醒、闹钟、笔记、文件、知识库、自动化

架构设计与决策依据见 **[doc/](doc/README.md)** —— 包含 15 篇 ADR、数据层契约与未决问题清单。
源码注释里引用的 `ADR-00xx`、`data-model.md`、`open-questions #n` 都可以在那里找到。

## 目录结构

```
Hello-ZhiXia/
├── package.json           # pnpm workspace 根
├── pnpm-workspace.yaml
├── tsconfig.base.json     # 三端共享的 TS 配置
├── doc/                   # 架构设计与决策记录（15 篇 ADR）
├── packages/
│   ├── core-sync/         # 数据层契约：ULID / HLC / 操作日志 / 同步前沿 / 快照压缩 / 冲突 / 墓碑 / schema 版本化
│   ├── core-agent/        # pi 封装：工具注册、权限门、会话管理
│   ├── core-mesh/         # 协调层：设备身份、发现、传输、写权租约
│   ├── platform-adapters/ # 平台适配接口（文件 / 通知 / 闹钟 / 钥匙串）
│   └── ui-shared/         # 三端共享的 UI 与状态绑定
├── apps/
│   ├── desktop/           # Electron 桌面应用（Windows / Linux）
│   └── android/           # Android 瘦客户端（技术选型待定）
└── services/
    └── rendezvous/        # 自建 rendezvous / relay
```

## 快速开始

```bash
git clone https://github.com/xaxovo/Hello-ZhiXia.git
cd Hello-ZhiXia
```

**技术栈**

判断某个依赖是否**真的存在**，请以各 `package.json` 为准。下表把「已经落到依赖里」
与「只是决策、尚未引入」分开标注 —— 否则照表 `import` 会直接失败。

| 层 | 选型 | 状态 |
| --- | --- | --- |
| Agent 内核 | [pi](https://pi.dev)（MIT 许可）：`pi-agent-core` · `pi-ai` · `pi-durable` | 规划中 |
| 实时会话流 | `@earendil-works/chord` | 规划中 |
| 数据同步 | 操作日志（op log）+ HLC；冲突合并（Yjs / Automerge 或自研） | op log / HLC 已实现，合并语义规划中 |
| 桌面壳 | Electron（Windows / Linux） | 规划中 |
| 移动端 | Android 瘦客户端——持有完整数据副本，不执行 agent | 规划中 |
| 语言与包管理 | TypeScript 7 · pnpm 12 workspace | ✅ 已引入 |
| 测试 | Vitest 5 | ✅ 已引入 |

**Node 版本**

仓库里有三个 Node 版本数字，含义不同，不要混用：

| 出处 | 值 | 含义 |
| --- | --- | --- |
| `package.json` → `engines.node` | `>=22.19.0` | **最低支持版本**：发布物承诺能跑的下限 |
| `.nvmrc` | `26.7.0` | **开发版本**：贡献者 `nvm use` 用的 |
| `devDependencies` → `@types/node` | `^26.6.5` | 跟随**开发版本**，不是下限 |

> ⚠️ `@types/node` 跟的是开发版本，因此**它不能用来判断某个 API 在 22.19 上是否可用**。
> 一旦用到 Node 内置 API，请以 `engines.node` 为准自行确认。当前 `@hzx/core-sync`
> 刻意不依赖任何 Node 内置模块（`globalThis.crypto` 也是按结构化类型取的），
> 所以还没有实际暴露在这个风险下。

### 开发

```bash
pnpm install        # 安装依赖
pnpm typecheck      # 类型检查（含测试文件）
pnpm test           # 运行单元测试
pnpm build          # 构建全部包
```

> `@hzx/core-sync/sim` 提供**确定性多节点同步模拟器**：同一进程内跑多台虚拟设备，
> 可注入网络分区、丢包、乱序与时钟偏移。相同种子必然得到相同的执行轨迹，
> 因此失败的同步用例可以精确重放。

> ⚠️ 项目处于**早期阶段**：`@hzx/core-sync`（数据层契约）已实现并有测试覆盖；
> 其余包都是空骨架，只写了职责说明与受哪些决策约束。

**Windows 开发者注意**：monorepo 的 `node_modules` 层级很深，请先执行
`git config --global core.longpaths true`，否则可能撞上 260 字符路径限制。

## 贡献指南

1. Fork 本仓库
2. 新建分支：`git checkout -b feature/your-feature`
3. 提交改动：`git commit -m "feat: your feature"`
4. 推送分支：`git push origin feature/your-feature`
5. 发起 Pull Request

## 许可证

本项目**未授予开源许可证**，保留所有权利（All Rights Reserved）。

未经作者书面许可，不得使用、复制、修改或分发本项目的任何部分。

---

**别名**：知夏生活（HZX）
