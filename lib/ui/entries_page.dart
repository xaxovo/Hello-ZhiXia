/// 「条目」—— 全部内容的统一列表。
///
/// 笔记、待办、提醒放在同一屏里用筛选器切换，因为它们本来就是同一张表。
/// 分开做三个 Tab 会让「我刚才记的那条到底是笔记还是待办」变成一个额外的心智负担。
library;

import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../domain/entry.dart';
import 'entry_editor_page.dart';
import 'widgets/entry_tile.dart';

class EntriesPage extends StatefulWidget {
  const EntriesPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<EntriesPage> createState() => _EntriesPageState();
}

class _EntriesPageState extends State<EntriesPage> {
  EntryKind? _filter;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final all = widget.controller.entries;
        final visible = _filter == null ? all : all.where((e) => e.kind == _filter).toList();

        return Scaffold(
          appBar: AppBar(title: const Text('条目')),
          body: Column(
            children: [
              SizedBox(
                height: 56,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _chip('全部', null),
                    _chip('笔记', EntryKind.note),
                    _chip('待办', EntryKind.task),
                    _chip('提醒', EntryKind.reminder),
                  ],
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          '还没有内容',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final entry = visible[index];
                          return EntryTile(
                            entry: entry,
                            onTap: () => _open(entry),
                            onToggleDone: entry.kind == EntryKind.task
                                ? () => widget.controller.repository
                                    .update(entry.id, done: !entry.done)
                                : null,
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(String label, EntryKind? kind) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == kind,
        onSelected: (_) => setState(() => _filter = kind),
      ),
    );
  }

  Future<void> _open(Entry entry) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EntryEditorPage(controller: widget.controller, existing: entry),
    ));
  }
}
