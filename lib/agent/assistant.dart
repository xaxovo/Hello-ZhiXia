/// 助手：模型与工具之间的往返循环。
///
/// 一轮对话的形态是：把历史与用户输入发出去 → 模型可能要求调用若干工具 →
/// 本地执行工具、把结果回填 → 再次请求 → 直到模型给出文字答复。
///
/// 这里刻意设了轮数上限：模型偶尔会陷入「不停地调工具」的循环，
/// 没有上限的话界面会永远停在「思考中」。
library;

import 'llm.dart';
import 'tools.dart';

/// 一条用于界面展示的消息。
final class ChatTurn {
  ChatTurn({required this.role, required this.text, this.toolNames = const []});

  /// `user` / `assistant` / `tool`
  final String role;
  final String text;

  /// 这一轮触发了哪些工具，用于让用户看见「助手做了什么」。
  final List<String> toolNames;

  bool get isUser => role == 'user';
}

final class Assistant {
  Assistant({required this.client, required this.tools});

  final LlmClient client;
  final ToolRegistry tools;

  /// 单次提问内最多往返几轮工具调用。
  static const int _maxRounds = 8;

  /// 保留多少条历史消息作为上下文。太长会让每次请求都变贵。
  static const int _historyLimit = 20;

  final List<ChatMessage> _history = [];

  String _systemPrompt() {
    final now = DateTime.now();
    final weekday = const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][now.weekday - 1];
    return '''
你是「知夏」，一个运行在用户自己设备上的日常助手。你可以通过工具读写用户的笔记、待办和提醒。

规则：
1. 用户提到时间时，先调用 now 确认今天日期（今天是 ${now.year}-${_two(now.month)}-${_two(now.day)}，$weekday），再换算成具体的 ISO 时间。
2. 要修改或删除条目时，先用 list_entries 找到确切的 id，不要臆测。
3. 删除不可撤销，执行前确认 id 是对的。
4. 只有用户明确要求时才创建条目，不要把随口说的话都存成待办。
5. 回答用中文，简洁，不要罗列工具调用过程。
''';
  }

  /// 发一轮提问，返回助手最终的答复文本。
  Future<String> ask(String input, {required void Function(ChatTurn turn) onTurn}) async {
    final messages = <ChatMessage>[
      ChatMessage.system(_systemPrompt()),
      ..._history,
      ChatMessage.user(input),
    ];

    final usedTools = <String>[];

    for (var round = 0; round < _maxRounds; round++) {
      final reply = await client.complete(messages, tools: tools.specs);

      if (reply.toolCalls.isEmpty) {
        final text = reply.text?.trim() ?? '';
        _appendHistory(ChatMessage.user(input));
        _appendHistory(ChatMessage.assistant(text));
        if (usedTools.isNotEmpty) {
          onTurn(ChatTurn(role: 'tool', text: '使用了工具：${usedTools.join('、')}', toolNames: usedTools));
        }
        return text.isEmpty ? '（模型没有返回内容）' : text;
      }

      messages.add(ChatMessage.assistant(reply.text, reply.toolCalls));
      usedTools.addAll(reply.toolCalls.map((c) => c.name));

      for (final call in reply.toolCalls) {
        final result = await tools.execute(call);
        messages.add(ChatMessage.tool(call.id, result));
      }
    }

    onTurn(ChatTurn(role: 'tool', text: '工具调用轮数达到上限，已停止。', toolNames: usedTools));
    return '这一轮工具调用次数过多，我先停下了。可以换个说法再试，或者告诉我具体要做什么。';
  }

  void _appendHistory(ChatMessage message) {
    _history.add(message);
    while (_history.length > _historyLimit) {
      _history.removeAt(0);
    }
  }

  void reset() => _history.clear();


  static String _two(int value) => value.toString().padLeft(2, '0');
}
