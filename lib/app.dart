/// 应用的装配点：把数据层、平台层、助手与界面接在一起。
///
/// 这里同时定义 [HxzApp] 这个根 Widget —— 它被入口和真机集成测试共用，
/// 因此不能藏在 `main.dart` 里。
library;

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'agent/assistant.dart';
import 'agent/llm.dart';
import 'agent/tools.dart';
import 'domain/entry.dart';
import 'domain/repository.dart';
import 'platform/reminders.dart';
import 'platform/settings.dart';
import 'theme.dart';
import 'ui/home_page.dart';

final class AppController extends ChangeNotifier {
  AppController._(this.repository, this.settingsStore, this.settings, this.scheduler);

  final HxzRepository repository;
  final SettingsStore settingsStore;
  final ReminderScheduler scheduler;

  LlmSettings settings;
  LlmClient? _client;
  Assistant? _assistant;

  final StreamController<Entry> _fires = StreamController<Entry>.broadcast();

  /// 界面还没挂载时到达的提醒先存在这里，挂载后一次性补报。
  final List<Entry> _pendingFires = [];

  /// 到点的提醒。界面订阅它来弹出提示。
  Stream<Entry> get fires => _fires.stream;

  /// 取走挂载之前积压的提醒。
  List<Entry> drainPendingFires() {
    final pending = List<Entry>.from(_pendingFires);
    _pendingFires.clear();
    return pending;
  }

  LlmSettings get _currentSettings => settings;

  List<Entry> get entries => repository.entries;
  List<Entry> get today => repository.today;
  List<Entry> byKind(EntryKind kind) => repository.byKind(kind);

  Assistant get assistant {
    final existing = _assistant;
    if (existing != null) return existing;
    final client = _client ??= LlmClient(settings: _currentSettings);
    final created = Assistant(client: client, tools: ToolRegistry(repository));
    _assistant = created;
    return created;
  }

  /// 启动装配。任何一步失败都会抛出，由调用方展示可读的错误。
  static Future<AppController> bootstrap() async {
    final support = await getApplicationSupportDirectory();

    final settingsStore = SettingsStore(support);
    final settings = await settingsStore.load();

    final repository = await HxzRepository.open(
      Directory('${support.path}${Platform.pathSeparator}store'),
    );

    final scheduler = await createReminderScheduler();
    await scheduler.initialize();

    final controller = AppController._(repository, settingsStore, settings, scheduler);
    repository.addListener(controller._onRepositoryChanged);

    await controller._catchUpOverdue();
    await controller.syncReminders();
    return controller;
  }

  /// 提醒的「签名」。只要它变了，说明待响的提醒集合发生了变化，需要重排。
  String? _reminderSignature;

  /// 仓储一变就重排系统闹钟。
  ///
  /// 这不能依赖某几个调用点「记得调 syncReminders」—— 真机实测发现助手通过工具
  /// 建出来的提醒根本不会进系统闹钟，因为它走的是仓储而不是编辑页。
  /// 把重排挂在仓储变化上，界面、助手、补报三条写入路径就都覆盖到了。
  void _onRepositoryChanged() {
    notifyListeners();

    final signature = repository
        .byKind(EntryKind.reminder)
        .map((e) => '${e.id}:${e.dueAt?.millisecondsSinceEpoch}:${e.done}')
        .join(',');
    if (signature == _reminderSignature) return;
    _reminderSignature = signature;
    syncReminders();
  }

  Future<void> saveSettings(LlmSettings updated) async {
    settings = updated;
    _client?.dispose();
    _client = null;
    _assistant = null;
    await settingsStore.save(updated);
    notifyListeners();
  }

  /// 把当前待响的提醒全量同步给调度器。
  Future<void> syncReminders() async {
    await scheduler.sync(repository.byKind(EntryKind.reminder), onFire: _onFire);
  }

  Future<void> _onFire(Entry entry) async {
    _pendingFires.add(entry);
    _fires.add(entry);
    await repository.update(entry.id, done: true);
  }

  /// 应用没在运行时错过的提醒。统一在这里补一次，避免它们永远停在「未触发」。
  Future<void> _catchUpOverdue() async {
    final now = DateTime.now();
    final overdue = repository
        .byKind(EntryKind.reminder)
        .where((e) => !e.done && (e.dueAt?.isBefore(now) ?? false))
        .toList();
    for (final entry in overdue) {
      await repository.update(entry.id, done: true);
      _pendingFires.add(entry);
      _fires.add(entry);
    }
  }

  @override
  void dispose() {
    repository.removeListener(_onRepositoryChanged);
    scheduler.dispose();
    _client?.dispose();
    _fires.close();
    repository.dispose();
    super.dispose();
  }
}

/// 应用根 Widget。入口与集成测试共用同一份装配。
class HxzApp extends StatelessWidget {
  const HxzApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '知夏生活',
      debugShowCheckedModeBanner: false,
      theme: HxzTheme.light(),
      darkTheme: HxzTheme.dark(),
      home: HomePage(controller: controller),
    );
  }
}

/// 启动失败时的兜底界面。比白屏更有用：它把真实的失败原因摆出来。
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HxzTheme.light(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text('启动失败', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 12),
                SelectableText(error, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
