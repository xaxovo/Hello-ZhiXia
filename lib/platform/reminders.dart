/// 提醒调度。
///
/// 同一个接口，两种实现，因为三端的系统能力不一样：
///
/// | 平台 | 实现 | 应用被关掉后还响吗 |
/// | --- | --- | --- |
/// | Android | `AlarmManager`（经 flutter_local_notifications） | 会 |
/// | Windows / Linux | 进程内 Timer | 不会，需要应用在运行 |
///
/// 这个差别必须如实体现，不能假装桌面端也有系统级闹钟。见 ADR-0016。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../domain/entry.dart';

typedef ReminderCallback = void Function(Entry entry);

abstract interface class ReminderScheduler {
  Future<void> initialize();

  /// 把「当前所有待响的提醒」同步给调度器：先全部取消，再排上还没到点的。
  ///
  /// 全量重排而不是增量，是因为提醒会被修改、删除、标记完成，
  /// 逐个追踪这些变化比重新排一遍更容易出错。
  Future<void> sync(Iterable<Entry> reminders, {required ReminderCallback onFire});

  Future<void> dispose();
}

/// 按平台选择实现。
Future<ReminderScheduler> createReminderScheduler() async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return _AndroidReminderScheduler();
  }
  return _InAppReminderScheduler();
}

// ---------------------------------------------------------------- Android

final class _AndroidReminderScheduler implements ReminderScheduler {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  @override
  Future<void> initialize() async {
    tz_data.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  }

  /// 通知 ID 必须是 32 位整数，而我们的实体 ID 是字符串，所以取哈希。
  int _notificationId(String entryId) => entryId.hashCode & 0x7fffffff;

  @override
  Future<void> sync(Iterable<Entry> reminders, {required ReminderCallback onFire}) async {
    await _plugin.cancelAll();
    final now = DateTime.now();
    for (final reminder in reminders) {
      final at = reminder.dueAt;
      if (at == null || reminder.done || !at.isAfter(now)) continue;
      await _plugin.zonedSchedule(
        id: _notificationId(reminder.id),
        title: '知夏 · 提醒',
        body: reminder.title,
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'hzx_reminders',
            '提醒',
            channelDescription: '到点提醒与闹钟',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------- 桌面

final class _InAppReminderScheduler implements ReminderScheduler {
  final Map<String, Timer> _timers = {};
  ReminderCallback? _onFire;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> sync(Iterable<Entry> reminders, {required ReminderCallback onFire}) async {
    _onFire = onFire;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();

    final now = DateTime.now();
    for (final reminder in reminders) {
      final at = reminder.dueAt;
      if (at == null || reminder.done || !at.isAfter(now)) continue;
      _timers[reminder.id] = Timer(at.difference(now), () {
        _timers.remove(reminder.id);
        _onFire?.call(reminder);
      });
    }
  }

  @override
  Future<void> dispose() async {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
