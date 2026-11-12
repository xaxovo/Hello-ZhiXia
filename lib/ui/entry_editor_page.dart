/// 新建与编辑条目的整页表单。
///
/// 用整页而不是底部弹窗，是因为笔记正文需要足够的书写空间。
library;

import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../domain/entry.dart';
import 'format.dart';

class EntryEditorPage extends StatefulWidget {
  const EntryEditorPage({
    super.key,
    required this.controller,
    this.existing,
    this.initialKind = EntryKind.note,
  });

  final AppController controller;
  final Entry? existing;
  final EntryKind initialKind;

  @override
  State<EntryEditorPage> createState() => _EntryEditorPageState();
}

class _EntryEditorPageState extends State<EntryEditorPage> {
  late EntryKind _kind;
  late final TextEditingController _title;
  late final TextEditingController _body;
  DateTime? _dueAt;
  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _kind = existing?.kind ?? widget.initialKind;
    _title = TextEditingController(text: existing?.title ?? '');
    _body = TextEditingController(text: existing?.body ?? '');
    _dueAt = existing?.dueAt;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);

    try {
      final existing = widget.existing;
      if (existing == null) {
        await widget.controller.repository.create(
          kind: _kind,
          title: title,
          body: _body.text,
          dueAt: _kind == EntryKind.note ? null : _dueAt,
        );
      } else {
        await widget.controller.repository.update(
          existing.id,
          title: title,
          body: _body.text,
          dueAt: _dueAt,
          clearDueAt: _dueAt == null && existing.dueAt != null,
        );
      }
      await widget.controller.syncReminders();
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条内容？'),
        content: Text('「${existing.title}」将被移除，无法撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.controller.repository.delete(existing.id);
    await widget.controller.syncReminders();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickDueAt() async {
    final now = DateTime.now();
    final initial = _dueAt ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    setState(() {
      _dueAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsTime = _kind != EntryKind.note;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑' : '新建'),
        actions: [
          if (_isEditing)
            IconButton(
              tooltip: '删除',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (!_isEditing) ...[
            SegmentedButton<EntryKind>(
              segments: const [
                ButtonSegment(value: EntryKind.note, label: Text('笔记'), icon: Icon(Icons.sticky_note_2_outlined)),
                ButtonSegment(value: EntryKind.task, label: Text('待办'), icon: Icon(Icons.check_circle_outline)),
                ButtonSegment(value: EntryKind.reminder, label: Text('提醒'), icon: Icon(Icons.alarm)),
              ],
              selected: {_kind},
              onSelectionChanged: (selection) => setState(() => _kind = selection.first),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _title,
            autofocus: !_isEditing,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: '标题', hintText: '一句话说清是什么'),
          ),
          if (_kind == EntryKind.note) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 8,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(labelText: '正文', alignLabelWithHint: true),
            ),
          ],
          if (needsTime) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(_dueAt == null ? '未设置时间' : formatDue(_dueAt!)),
                subtitle: Text(_kind == EntryKind.reminder ? '到这个时间会响铃提醒' : '截止时间'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_dueAt != null)
                      IconButton(
                        tooltip: '清除',
                        onPressed: () => setState(() => _dueAt = null),
                        icon: const Icon(Icons.close),
                      ),
                    IconButton(
                      tooltip: '选择时间',
                      onPressed: _pickDueAt,
                      icon: const Icon(Icons.edit_calendar),
                    ),
                  ],
                ),
              ),
            ),
            if (_kind == EntryKind.reminder && _dueAt == null)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 6),
                child: Text(
                  '提醒必须设置时间，否则不会响。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
