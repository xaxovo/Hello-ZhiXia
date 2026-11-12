/// 助手链路的集成测试：用一个假的 OpenAI 兼容服务端跑完整往返。
///
/// 这一层要证明的不是「解析 JSON 没写错」，而是**整条闭环成立**：
/// 模型要求调工具 → 工具真的把数据写进了仓储 → 结果回传给模型 → 模型给出答复。
/// 不需要真实 API Key，也不需要联网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/agent/assistant.dart';
import 'package:hello_zhixia/agent/llm.dart';
import 'package:hello_zhixia/agent/tools.dart';
import 'package:hello_zhixia/domain/entry.dart';
import 'package:hello_zhixia/domain/repository.dart';
import 'package:hello_zhixia/platform/settings.dart';

/// 服务端行为：正常按工具调用往返，或直接返回错误。
enum ServerMode { toolCallThenAnswer, unauthorized }

void main() {
  late HttpServer server;
  late Directory directory;
  late HxzRepository repository;
  late List<Map<String, Object?>> requests;
  late List<String> authorizationHeaders;
  late ServerMode mode;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('hzx_flow_');
    repository = await HxzRepository.open(directory);
    requests = [];
    authorizationHeaders = [];
    mode = ServerMode.toolCallThenAnswer;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      authorizationHeaders.add(request.headers.value('authorization') ?? '');
      final body = jsonDecode(raw) as Map<String, Object?>;
      requests.add(body);

      request.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');

      if (mode == ServerMode.unauthorized) {
        request.response.statusCode = 401;
        request.response.write(jsonEncode({'error': {'message': 'invalid api key'}}));
        await request.response.close();
        return;
      }

      final messages = body['messages']! as List<Object?>;
      final alreadyCalledTool = messages.any((m) => (m! as Map<Object?, Object?>)['role'] == 'tool');

      if (!alreadyCalledTool) {
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': null,
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'create_entry',
                      'arguments': jsonEncode({'kind': 'task', 'title': '买牛奶'}),
                    },
                  },
                ],
              },
            },
          ],
        }));
      } else {
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '已经帮你记下了：买牛奶。'},
            },
          ],
        }));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    repository.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  LlmClient clientFor() => LlmClient(
        settings: LlmSettings(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'test-key',
          model: 'fake-model',
        ),
      );

  test('一次提问完成「模型 → 工具 → 数据落库 → 模型答复」的闭环', () async {
    final assistant = Assistant(
      client: clientFor(),
      tools: ToolRegistry(repository),
    );

    final answer = await assistant.ask('帮我记一下买牛奶', onTurn: (_) {});

    expect(answer, '已经帮你记下了：买牛奶。');
    expect(repository.entries.single.title, '买牛奶');
    expect(repository.entries.single.kind, EntryKind.task);

    // 两次请求：第一次带工具、第二次带工具结果
    expect(requests.length, 2);
    expect(requests.first['model'], 'fake-model');
    expect(requests.first['tools'], isA<List<Object?>>());
    expect((requests.first['tools']! as List<Object?>).length, 5);

    final secondMessages = requests.last['messages']! as List<Object?>;
    final toolMessages = secondMessages
        .map((m) => m! as Map<Object?, Object?>)
        .where((m) => m['role'] == 'tool')
        .toList();
    expect(toolMessages.length, 1);
    expect(toolMessages.single['tool_call_id'], 'call_1');
  });

  test('鉴权头按配置发出，不带多余前缀', () async {
    final assistant = Assistant(client: clientFor(), tools: ToolRegistry(repository));
    await assistant.ask('随便问问', onTurn: (_) {});

    expect(authorizationHeaders, isNotEmpty);
    expect(authorizationHeaders.first, 'Bearer test-key');
  });

  test('工具轮次会被回报给界面', () async {
    final assistant = Assistant(client: clientFor(), tools: ToolRegistry(repository));
    final turns = <ChatTurn>[];

    await assistant.ask('帮我记一下买牛奶', onTurn: turns.add);

    expect(turns.single.toolNames, contains('create_entry'));
    expect(turns.single.text, contains('create_entry'));
  });

  test('接口报错时抛出可读的异常，而不是静默返回空', () async {
    mode = ServerMode.unauthorized;
    final assistant = Assistant(client: clientFor(), tools: ToolRegistry(repository));

    await expectLater(
      assistant.ask('你好', onTurn: (_) {}),
      throwsA(isA<LlmException>().having((e) => e.message, 'message', contains('401'))),
    );
    expect(repository.entries, isEmpty);
  });

  test('未配置密钥时直接给出提示，不发请求', () async {
    final assistant = Assistant(
      client: LlmClient(settings: const LlmSettings()),
      tools: ToolRegistry(repository),
    );

    await expectLater(
      assistant.ask('你好', onTurn: (_) {}),
      throwsA(isA<LlmException>().having((e) => e.message, 'message', contains('API Key'))),
    );
    expect(requests, isEmpty);
  });

  test('历史会被带上，且超长时只保留最近的若干条', () async {
    final assistant = Assistant(client: clientFor(), tools: ToolRegistry(repository));

    for (var i = 0; i < 15; i++) {
      await assistant.ask('第 $i 次', onTurn: (_) {});
    }

    final lastMessages = requests.last['messages']! as List<Object?>;
    // system + 最多 20 条历史 + 本轮 user + 本轮的 assistant(tool_calls) + 工具结果 = 24
    // 关键不是这个具体数字，而是它**不随轮次增长**。
    expect(lastMessages.length, lessThanOrEqualTo(24));
    expect((lastMessages.first as Map<Object?, Object?>)['role'], 'system');
  });
}
