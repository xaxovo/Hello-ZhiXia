# 知夏生活（Hello-ZhiXia）

跨平台的个人 agent 兼日常助手。**本地优先**：数据存在你自己的设备上，不经过任何服务器。

Windows / Linux / Android 共用**一套 Flutter 代码**。

---

## 这一版能做什么

| 能力 | 状态 |
| --- | --- |
| 笔记、待办、提醒的统一管理 | ✅ |
| 到点提醒（Android 走系统闹钟，关闭应用后仍会响） | ✅ |
| 与云端模型对话，由它帮你记录与查询 | ✅ |
| 数据全部落在本地，可离线使用 | ✅ |
| 跨设备同步 | ❌ 未实现 |
| 多端算力调度与知识库 | ❌ 未实现 |

> 当前是 **MVP**。详见 [doc/decisions/0016-flutter-unified-client.md](doc/decisions/0016-flutter-unified-client.md) 里记下的取舍与待偿还项。

## 跑起来

需要 Flutter 3.50 或更高。

```bash
flutter pub get
flutter run -d windows    # 或 linux / android
```

模型不是必须的：不配置也能正常记录笔记与待办。要用助手，到「设置」里填入任意
**OpenAI 兼容**接口的地址、密钥与模型名（默认指向 DeepSeek）。

## 数据在哪里

| 平台 | 位置 |
| --- | --- |
| Windows | `%APPDATA%\com.zhixia\hello_zhixia\store\` |
| Linux | `~/.local/share/com.zhixia/hello_zhixia/store/` |
| Android | 应用私有目录 |

里面只有三个文件，都是可读的纯文本：

- `ops.jsonl` —— 只追加的操作日志，每一行是一条不可变操作
- `snapshot.json` —— 压缩后的状态快照
- `device_id` —— 本机标识

## 代码结构

```
lib/
├─ main.dart              入口
├─ app.dart               装配：数据层 + 平台层 + 助手 → 单个 ChangeNotifier
├─ theme.dart
├─ core/                  与业务无关的内核（纯 Dart，不依赖运行时）
│  ├─ ulid.dart           有序的唯一标识
│  ├─ hlc.dart            混合逻辑时钟
│  ├─ op.dart             操作与折叠
│  ├─ snapshot.dart       快照与压缩（纯逻辑）
│  └─ op_store.dart       落盘实现
├─ domain/                领域
│  ├─ entry.dart          笔记 / 待办 / 提醒的统一模型
│  ├─ ops.dart            操作类型与折叠函数
│  └─ repository.dart     仓储门面
├─ agent/                 助手
│  ├─ llm.dart            OpenAI 兼容客户端
│  ├─ tools.dart          助手可用的工具（唯一的数据写入通道）
│  └─ assistant.dart      工具调用循环
├─ platform/              平台差异
│  ├─ settings.dart       本机设置
│  └─ reminders.dart      提醒调度（Android 用系统闹钟，桌面用进程内定时器）
└─ ui/                    界面
```

**分层规则**：`core/` 不依赖 `domain/`，`domain/` 不依赖 `agent/` 与 `ui/`；
只有 `ui/` 能碰 Flutter 的控件。这条规则让数据层能被纯粹地测试。

## 测试

```bash
flutter analyze     # 应为 No issues found
flutter test        # 35 个用例
```

重点覆盖的不是「界面能点」，而是三处**出错就不可恢复**的地方：

1. HLC 的四分支 `observe` —— 少一个分支，重放顺序就会错
2. 压缩的可重入性（`压缩两次 == 压缩一次`）—— 写错就是静默丢数据
3. 日志末尾被截断时仍能读出其余数据 —— 断电不该让整份历史报废

## 架构文档

设计取舍与决策记录在 [doc/](doc/)。已经定下的包括：

- [ADR-0005](doc/decisions/0005-crdt-sync-basis.md) 同步基座选 CRDT 而非 LWW
- [ADR-0011](doc/decisions/0011-reminder-exactly-once.md) 提醒下放给系统闹钟
- [ADR-0016](doc/decisions/0016-flutter-unified-client.md) 统一到 Flutter，MVP 不引入 pi

早先的 TypeScript 数据层实现（4148 行、含多节点同步模拟器）保留在 git 历史
（提交 `5e93ffc`）中，作为本版数据层的规格来源。

## 许可

保留所有权利（All Rights Reserved）。
