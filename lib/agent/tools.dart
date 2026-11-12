/// 助手可以调用的工具。
///
/// 工具是助手**唯一**能改变用户数据的方式 —— 它没有直接写数据库的通道。
/// 每个工具都必须有副作用边界清晰的签名，因为这是「默认拒绝 + 显式白名单」
/// 这条安全约定唯一的落点；本项目不引入通用代码执行或任意 HTTP 请求。
library;

import 'dart:convert';

import '../domain/entry.dart';
import '../domain/repository.dart';
import 'llm.dart';

final class ToolRegistry {
  ToolRegistry(this._repository);

  final HxzRepository _repository;

  List<Map<String, Object?>> get specs => const [
        {
          'type': 'function',
          'function': {
            'name': 'create_entry',
            'description': '新建一条笔记、待办或提醒。涉及具体时间时，先用 now 工具确认当前时间。',
            'parameters': {
              'type': 'object',
              'properties': {
                'kind': {
                  'type': 'string',
                  'enum': ['note', 'task', 'reminder'],
                  'description': 'note=笔记，task=待办，reminder=到点提醒',
                },
                'title': {'type': 'string', 'description': '标题，一句话说清是什么'},
                'body': {'type': 'string', 'description': '正文，仅笔记需要'},
                'due_at': {
                  'type': 'string',
                  'description': '本地时间的 ISO 8601 字符串，例如 2026-11-13T09:00:00。'
                      '待办表示截止时间，提醒表示响铃时间。',
                },
              },
              'required': ['kind', 'title'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'list_entries',
            'description': '列出条目。不传参数则返回全部。',
            'parameters': {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string', 'enum': ['note', 'task', 'reminder']},
                'query': {'type': 'string', 'description': '标题或正文包含的关键词'},
              },
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'update_entry',
            'description': '修改条目。只需要传要改的字段。',
            'parameters': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string', 'description': '条目 ID，可由 list_entries 得到'},
                'title': {'type': 'string'},
                'body': {'type': 'string'},
                'done': {'type': 'boolean'},
                'due_at': {
                  'type': 'string',
                  'description': '本地时间 ISO 8601；传空字符串表示清除时间',
                },
              },
              'required': ['id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'delete_entry',
            'description': '删除条目。这是不可撤销的操作，执行前应确认 id 正确。',
            'parameters': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
              },
              'required': ['id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'now',
            'description': '返回当前本地日期时间与星期，用于把「明天下午三点」换算成具体时间。',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
      ];

  Future<String> execute(ToolCall call) async {
    try {
      switch (call.name) {
        case 'create_entry':
          return await _createEntry(call.arguments);
        case 'list_entries':
          return _listEntries(call.arguments);
        case 'update_entry':
          return await _updateEntry(call.arguments);
        case 'delete_entry':
          return await _deleteEntry(call.arguments);
        case 'now':
          return jsonEncode({'now': _iso(DateTime.now()), 'weekday': _weekday(DateTime.now())});
        default:
          return jsonEncode({'error': '未知工具 ${call.name}'});
      }
    } on Object catch (error) {
      return jsonEncode({'error': '$error'});
    }
  }

  Future<String> _createEntry(Map<String, Object?> args) async {
    final kindName = args['kind'] as String?;
    final title = (args['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return jsonEncode({'error': 'title 不能为空'});

    final kind = EntryKind.parse(kindName ?? 'note');
    final dueAt = _parseTime(args['due_at']);
    if (kind == EntryKind.reminder && dueAt == null) {
      return jsonEncode({'error': '创建提醒必须给出 due_at'});
    }

    final entry = await _repository.create(
      kind: kind,
      title: title,
      body: (args['body'] as String?) ?? '',
      dueAt: dueAt,
    );
    return jsonEncode({'ok': true, 'entry': _brief(entry)});
  }

  String _listEntries(Map<String, Object?> args) {
    final kindName = args['kind'] as String?;
    final query = (args['query'] as String?)?.toLowerCase();
    var items = _repository.entries;
    if (kindName != null) {
      final kind = EntryKind.parse(kindName);
      items = items.where((e) => e.kind == kind).toList();
    }
    if (query != null && query.isNotEmpty) {
      items = items
          .where((e) =>
              e.title.toLowerCase().contains(query) || e.body.toLowerCase().contains(query))
          .toList();
    }
    return jsonEncode({'count': items.length, 'entries': items.map(_brief).toList()});
  }

  Future<String> _updateEntry(Map<String, Object?> args) async {
    final id = args['id'] as String?;
    if (id == null || id.isEmpty) return jsonEncode({'error': '缺少 id'});

    final hasDueAt = args.containsKey('due_at');
    final rawDueAt = args['due_at'];
    final clearDueAt = hasDueAt && (rawDueAt == null || rawDueAt == '');

    await _repository.update(
      id,
      title: args['title'] as String?,
      body: args['body'] as String?,
      done: args['done'] as bool?,
      dueAt: _parseTime(rawDueAt),
      clearDueAt: clearDueAt,
    );
    return jsonEncode({'ok': true});
  }

  Future<String> _deleteEntry(Map<String, Object?> args) async {
    final id = args['id'] as String?;
    if (id == null || id.isEmpty) return jsonEncode({'error': '缺少 id'});
    await _repository.delete(id);
    return jsonEncode({'ok': true});
  }

  static Map<String, Object?> _brief(Entry entry) => {
        'id': entry.id,
        'kind': entry.kind.id,
        'title': entry.title,
        if (entry.body.isNotEmpty) 'body': entry.body,
        'done': entry.done,
        'due_at': entry.dueAt == null ? null : _iso(entry.dueAt!),
      };

  static String _iso(DateTime time) {
    final local = time.toLocal();
    final date = '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final clock = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '${date}T$clock:00';
  }

  static String _weekday(DateTime time) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][time.weekday - 1];

  static DateTime? _parseTime(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toLocal();
  }
}
