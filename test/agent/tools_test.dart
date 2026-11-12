import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/agent/llm.dart';
import 'package:hello_zhixia/agent/tools.dart';
import 'package:hello_zhixia/domain/entry.dart';
import 'package:hello_zhixia/domain/repository.dart';

ToolCall call(String name, Map<String, Object?> args) =>
    ToolCall(id: 'call-1', name: name, rawArguments: jsonEncode(args));

void main() {
  late Directory directory;
  late HxzRepository repository;
  late ToolRegistry tools;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('hzx_tools_');
    repository = await HxzRepository.open(directory);
    tools = ToolRegistry(repository);
  });

  tearDown(() {
    repository.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('工具声明是完整的 function schema', () {
    for (final spec in tools.specs) {
      expect(spec['type'], 'function');
      final function = spec['function']! as Map<String, Object?>;
      expect(function['name'], isA<String>());
      expect(function['description'], isA<String>());
      expect(function['parameters'], isA<Map<String, Object?>>());
    }
  });

  test('create_entry 真的写出了条目', () async {
    final result = jsonDecode(await tools.execute(call('create_entry', {
      'kind': 'note',
      'title': '读书笔记',
      'body': '第三章',
    }))) as Map<String, Object?>;

    expect(result['ok'], isTrue);
    expect(repository.entries.single.title, '读书笔记');
    expect(repository.entries.single.kind, EntryKind.note);
  });

  test('创建提醒必须带时间', () async {
    final result = jsonDecode(await tools.execute(call('create_entry', {
      'kind': 'reminder',
      'title': '没有时间的提醒',
    }))) as Map<String, Object?>;

    expect(result['error'], contains('due_at'));
    expect(repository.entries, isEmpty);
  });

  test('list_entries 支持按类型与关键词筛选', () async {
    await tools.execute(call('create_entry', {'kind': 'note', 'title': '买菜清单'}));
    await tools.execute(call('create_entry', {'kind': 'task', 'title': '买菜回程顺路加油'}));

    final all = jsonDecode(await tools.execute(call('list_entries', {}))) as Map<String, Object?>;
    expect(all['count'], 2);

    final tasks = jsonDecode(
      await tools.execute(call('list_entries', {'kind': 'task'})),
    ) as Map<String, Object?>;
    expect(tasks['count'], 1);

    final searched = jsonDecode(
      await tools.execute(call('list_entries', {'query': '买菜'})),
    ) as Map<String, Object?>;
    expect(searched['count'], 2);
  });

  test('update_entry 修改与清除时间', () async {
    final created = await repository.create(
      kind: EntryKind.task,
      title: '交周报',
      dueAt: DateTime(2030, 1, 1, 9),
    );

    await tools.execute(call('update_entry', {
      'id': created.id,
      'title': '交周报（已延期）',
      'done': true,
    }));
    expect(repository.entries.single.done, isTrue);
    expect(repository.entries.single.title, '交周报（已延期）');

    await tools.execute(call('update_entry', {'id': created.id, 'due_at': ''}));
    expect(repository.entries.single.dueAt, isNull);
  });

  test('delete_entry 移除条目', () async {
    final created = await repository.create(kind: EntryKind.note, title: '临时');
    await tools.execute(call('delete_entry', {'id': created.id}));

    expect(repository.entries, isEmpty);
  });

  test('now 返回当前时间与星期', () async {
    final result = jsonDecode(await tools.execute(call('now', {}))) as Map<String, Object?>;

    expect(result['now'], isA<String>());
    expect(result['now'] as String, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00$')));
    expect(result['weekday'] as String, startsWith('周'));
  });

  test('未知工具返回错误而不是抛异常', () async {
    final result = jsonDecode(await tools.execute(call('rm_rf', {}))) as Map<String, Object?>;

    expect(result['error'], isNotNull);
  });

  test('参数缺失时返回可读的错误', () async {
    final result = jsonDecode(await tools.execute(call('delete_entry', {}))) as Map<String, Object?>;

    expect(result['error'], contains('id'));
  });
}
