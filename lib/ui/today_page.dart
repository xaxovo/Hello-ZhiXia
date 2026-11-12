/// 「今日」—— 打开应用第一眼看到的东西。
///
/// 只显示今天真正需要处理的：未完成的待办与今天会响的提醒。
/// 不做信息流、不做推荐，这一屏的目标是让用户三秒内知道「现在该干什么」。
library;

import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../domain/entry.dart';
import 'entry_editor_page.dart';
import 'widgets/entry_tile.dart';

class TodayPage extends StatelessWidget {
  const TodayPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final items = controller.today;
        final tasks = items.where((e) => e.kind == EntryKind.task).toList();
        final reminders = items.where((e) => e.kind == EntryKind.reminder).toList();
        final notes = controller.byKind(EntryKind.note);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('今日'),
                Text(
                  _header(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              if (items.isEmpty && notes.isEmpty)
                const _EmptyToday()
              else ...[
                if (items.isEmpty) const _QuietDay(),
                if (reminders.isNotEmpty) ...[
                  const _SectionHeader('今天会响'),
                  ...reminders.map((entry) => EntryTile(
                        entry: entry,
                        onTap: () => _open(context, entry),
                      )),
                ],
                if (tasks.isNotEmpty) ...[
                  const _SectionHeader('待办'),
                  ...tasks.map((entry) => EntryTile(
                        entry: entry,
                        onTap: () => _open(context, entry),
                        onToggleDone: () => _toggle(entry),
                      )),
                ],
                if (notes.isNotEmpty) ...[
                  const _SectionHeader('最近笔记'),
                  ...notes.take(3).map((entry) => EntryTile(
                        entry: entry,
                        onTap: () => _open(context, entry),
                      )),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggle(Entry entry) async {
    await controller.repository.update(entry.id, done: !entry.done);
  }

  Future<void> _open(BuildContext context, Entry entry) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EntryEditorPage(controller: controller, existing: entry),
    ));
  }

  String _header() {
    final now = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${now.year}年${now.month}月${now.day}日 · ${weekdays[now.weekday - 1]}';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

class _EmptyToday extends StatelessWidget {
  const _EmptyToday();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 32),
      child: Column(
        children: [
          Icon(Icons.wb_sunny_outlined, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('今天没有安排', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '右下角可以新建笔记、待办或提醒。\n也可以直接问「知夏」助手。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 有待办或提醒之外的内容、但今天确实没有安排时用的轻提示。
class _QuietDay extends StatelessWidget {
  const _QuietDay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Row(
        children: [
          Icon(Icons.wb_sunny_outlined, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            '今天没有到期的安排',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
