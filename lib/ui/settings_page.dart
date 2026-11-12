/// 「设置」—— 模型接入与数据说明。
///
/// 这一页刻意把「密钥存在哪里」「哪些平台能后台响铃」写清楚，
/// 而不是藏在实现里让用户自己猜。
library;

import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../domain/entry.dart';
import '../platform/reminders.dart';
import '../platform/settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  bool _obscure = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.settings;
    _baseUrl = TextEditingController(text: settings.baseUrl);
    _apiKey = TextEditingController(text: settings.apiKey);
    _model = TextEditingController(text: settings.model);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.controller.saveSettings(LlmSettings(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
    ));
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          TextButton(
            onPressed: _dirty ? _save : null,
            child: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Section('模型'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              children: [
                TextField(
                  controller: _baseUrl,
                  decoration: const InputDecoration(
                    labelText: '接口地址',
                    hintText: 'https://api.deepseek.com/v1',
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _apiKey,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    ),
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: '模型名',
                    hintText: 'deepseek-chat',
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                ),
              ],
            ),
          ),
          const _Hint(
            '密钥只保存在本机应用数据目录，不会上传到任何服务器。'
            '但它没有加密，请不要在共享设备上填写。',
          ),
          const Divider(height: 32),
          const _Section('数据'),
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final total = widget.controller.entries.length;
              final reminders = widget.controller.byKind(EntryKind.reminder).length;
              return Column(
                children: [
                  _InfoRow(label: '条目总数', value: '$total'),
                  _InfoRow(label: '提醒', value: '$reminders'),
                  _InfoRow(label: '未压缩操作数', value: '${widget.controller.repository.opCount}'),
                ],
              );
            },
          ),
          const _Hint(
            '所有改动都以操作日志的形式保存在本机，日志会自动压缩成快照。'
            '数据目前只在这台设备上，跨设备同步尚未实现。',
          ),
          const Divider(height: 32),
          const _Section('提醒'),
          _ExactAlarmTile(scheduler: widget.controller.scheduler),
          const _Hint(
            'Android 通过系统闹钟投递提醒，关闭应用后仍会响；'
            'Windows / Linux 使用进程内定时器，需要应用保持运行。',
          ),
          const Divider(height: 32),
          const _Section('说明'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '提醒能力因平台而异：Android 通过系统闹钟，关闭应用后仍会响；'
                  'Windows / Linux 使用进程内定时器，需要应用保持运行。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '知夏生活 0.1.0 · MVP',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}

/// 精确闹钟的授权状态。
///
/// Android 14 起系统默认拒绝精确闹钟，此时提醒只能按窗口投递 ——
/// 真机实测会晚两三分钟。与其瞒着用户，不如把状态摆出来并提供入口：
/// **应用自己不去弹系统设置页**，只有用户点了这一行才跳转。
class _ExactAlarmTile extends StatefulWidget {
  const _ExactAlarmTile({required this.scheduler});

  final ReminderScheduler scheduler;

  @override
  State<_ExactAlarmTile> createState() => _ExactAlarmTileState();
}

class _ExactAlarmTileState extends State<_ExactAlarmTile> with WidgetsBindingObserver {
  bool? _permitted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 用户从系统设置页返回时重新检查。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final permitted = await widget.scheduler.exactAlarmsPermitted();
    if (mounted) setState(() => _permitted = permitted);
  }

  Future<void> _request() async {
    await widget.scheduler.requestExactAlarms();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final permitted = _permitted;

    if (permitted == null) {
      return const ListTile(
        leading: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('正在检查闹钟权限…'),
      );
    }

    if (permitted) {
      return ListTile(
        leading: Icon(Icons.alarm_on, color: theme.colorScheme.primary),
        title: const Text('精确闹钟：已允许'),
        subtitle: const Text('提醒会在设定的时刻准时响'),
      );
    }

    return ListTile(
      onTap: _request,
      leading: Icon(Icons.alarm, color: theme.colorScheme.error),
      title: const Text('精确闹钟：未允许'),
      subtitle: const Text('系统会把提醒推迟几分钟投递。点这里去开启。'),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
