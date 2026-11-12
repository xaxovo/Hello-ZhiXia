/// 条目列表里的一行。
library;

import 'package:material_ui/material_ui.dart';

import '../../domain/entry.dart';
import '../format.dart';

class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.onToggleDone,
  });

  final Entry entry;
  final VoidCallback onTap;
  final VoidCallback? onToggleDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finished = entry.done;

    return ListTile(
      onTap: onTap,
      leading: _leading(theme),
      title: Text(
        entry.title.isEmpty ? '（无标题）' : entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          decoration: finished && entry.kind == EntryKind.task ? TextDecoration.lineThrough : null,
          color: finished ? theme.colorScheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: _subtitle(theme),
      trailing: entry.kind == EntryKind.task
          ? Checkbox(
              value: entry.done,
              onChanged: onToggleDone == null ? null : (_) => onToggleDone!(),
            )
          : null,
    );
  }

  Widget _leading(ThemeData theme) {
    final color = entry.isOverdue ? theme.colorScheme.error : null;
    final icon = switch (entry.kind) {
      EntryKind.note => Icons.sticky_note_2_outlined,
      EntryKind.task => Icons.check_circle_outline,
      EntryKind.reminder => Icons.alarm,
    };
    return Icon(icon, color: color);
  }

  Widget? _subtitle(ThemeData theme) {
    final parts = <String>[];
    final due = entry.dueAt;
    if (due != null) parts.add(formatDue(due));
    if (entry.kind == EntryKind.reminder && entry.done) parts.add('已响过');
    if (entry.kind == EntryKind.note && entry.body.isNotEmpty) {
      parts.add(entry.body.replaceAll('\n', ' '));
    }
    if (parts.isEmpty) return null;

    final overdue = entry.isOverdue;
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: overdue ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
