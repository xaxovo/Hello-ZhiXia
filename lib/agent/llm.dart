/// 与云端模型通讯的最小客户端。
///
/// 刻意只实现 OpenAI 兼容的 `/chat/completions` 一种协议，不引入任何 SDK：
/// 这一层要能用两三百行看明白，而不是被第三方抽象包住。
/// 换模型服务方只需要改设置里的地址与模型名。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../platform/settings.dart';

final class ToolCall {
  const ToolCall({required this.id, required this.name, required this.rawArguments});

  final String id;
  final String name;

  /// 模型返回的原始参数字符串。保留原文是为了原样回传，避免二次编码导致不一致。
  final String rawArguments;

  Map<String, Object?> get arguments {
    if (rawArguments.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(rawArguments);
      return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
    } on FormatException {
      return const {};
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': rawArguments},
      };
}

final class ChatMessage {
  const ChatMessage({
    required this.role,
    this.content,
    this.toolCalls = const [],
    this.toolCallId,
  });

  final String role;
  final String? content;
  final List<ToolCall> toolCalls;
  final String? toolCallId;

  factory ChatMessage.system(String text) => ChatMessage(role: 'system', content: text);
  factory ChatMessage.user(String text) => ChatMessage(role: 'user', content: text);

  factory ChatMessage.assistant(String? text, [List<ToolCall> calls = const []]) =>
      ChatMessage(role: 'assistant', content: text, toolCalls: calls);

  factory ChatMessage.tool(String callId, String text) =>
      ChatMessage(role: 'tool', content: text, toolCallId: callId);

  Map<String, Object?> toJson() => {
        'role': role,
        if (content != null) 'content': content,
        if (toolCalls.isNotEmpty) 'tool_calls': toolCalls.map((c) => c.toJson()).toList(),
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

final class LlmException implements Exception {
  LlmException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class LlmClient {
  LlmClient({required this.settings, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final LlmSettings settings;
  final http.Client _http;

  /// 单次请求的超时。模型响应慢是常态，但要有一个上限，否则界面会一直转圈。
  static const Duration _timeout = Duration(seconds: 90);

  Future<({String? text, List<ToolCall> toolCalls})> complete(
    List<ChatMessage> messages, {
    required List<Map<String, Object?>> tools,
  }) async {
    if (!settings.isConfigured) {
      throw LlmException('还没有配置 API Key，请到「设置」里填写。');
    }

    final uri = Uri.parse('${settings.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
    final body = <String, Object?>{
      'model': settings.model,
      'messages': messages.map((m) => m.toJson()).toList(),
      if (tools.isNotEmpty) ...{'tools': tools, 'tool_choice': 'auto'},
    };

    final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${settings.apiKey}',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on Object catch (error) {
      throw LlmException('请求失败：$error');
    }

    if (response.statusCode != 200) {
      throw LlmException('接口返回 ${response.statusCode}：${_shorten(response.body)}');
    }

    final Map<String, Object?> decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>;
    } on Object {
      throw LlmException('接口返回的不是合法 JSON：${_shorten(response.body)}');
    }

    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmException('接口没有返回任何结果');
    }
    final message = ((choices.first as Map)['message'] as Map?) ?? const {};
    final content = message['content'] as String?;
    final rawCalls = message['tool_calls'];

    final calls = <ToolCall>[];
    if (rawCalls is List) {
      for (final raw in rawCalls) {
        if (raw is! Map) continue;
        final function = raw['function'];
        if (function is! Map) continue;
        calls.add(ToolCall(
          id: (raw['id'] as String?) ?? '',
          name: (function['name'] as String?) ?? '',
          rawArguments: (function['arguments'] as String?) ?? '{}',
        ));
      }
    }

    return (text: content, toolCalls: calls);
  }

  void dispose() => _http.close();

  static String _shorten(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';
}
