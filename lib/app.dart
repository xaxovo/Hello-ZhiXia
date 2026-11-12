/// 应用的装配点：把数据层、平台层与助手接在一起，并以单个 [ChangeNotifier]
/// 对外暴露，界面只订阅这一个对象。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'agent/assistant.dart';
import 'agent/llm.dart';
import 'agent/tools.dart';
import 'domain/entry.dart';
import 'domain/repository.dart';
import 'platform/reminders.dart';
import 'platform/settings.dart';

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

  List<Entry> get entries => repository.entries;
  List<Entry> get today => repository.today;
  List<Entry> byKind(EntryKind kind) => repository.byKind(kind);

  Assistant get assistant {
    final existing = _assistant;
    if (existing != null) return existing;
    final client = _client ??= LlmClient(settings: settings);
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
    repository.addListener(controller.notifyListeners);

    await controller._catchUpOverdue();
    await controller.syncReminders();
    return controller;
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
    repository.removeListener(notifyListeners);
    scheduler.dispose();
    _client?.dispose();
    _fires.close();
    repository.dispose();
    super.dispose();
  }
}
