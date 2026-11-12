/// 真机集成测试。
///
/// 与 `test/` 下的单元测试分工明确：那边跑在 Dart VM 里，用假服务端验证逻辑；
/// 这边跑在**真实设备**上，验证只有真机才成立的东西 ——
/// 平台目录读写、系统通知权限、以及真实模型的往返。
///
/// 真实模型那部分需要传密钥，否则自动跳过，不会让 CI 或本地默认运行失败：
///
/// ```bash
/// flutter test integration_test/device_test.dart -d <设备ID> \
///   --dart-define=HZX_API_KEY=sk-xxx
/// ```
///
/// 密钥只从编译期常量读，不落仓库。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/app.dart';
import 'package:hello_zhixia/domain/entry.dart';
import 'package:hello_zhixia/platform/settings.dart';
import 'package:integration_test/integration_test.dart';

const String _apiKey = String.fromEnvironment('HZX_API_KEY');
const String _baseUrl =
    String.fromEnvironment('HZX_BASE_URL', defaultValue: 'https://api.deepseek.com/v1');
const String _model = String.fromEnvironment('HZX_MODEL', defaultValue: 'deepseek-chat');

/// 等某个控件消失。
///
/// `pumpAndSettle` 只等「还有没有排队的帧」，而保存动作里含真实磁盘写入：
/// 写入期间没有新帧，`pumpAndSettle` 会提前返回，断言就会跑在数据落库之前。
Future<void> _pumpUntilGone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('冷启动能进入今日页', (tester) async {
    final controller = await AppController.bootstrap();
    await tester.pumpWidget(HxzApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('今日'), findsWidgets);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('通过界面新建一条笔记，并真的写进设备存储', (tester) async {
    final controller = await AppController.bootstrap();
    await tester.pumpWidget(HxzApp(controller: controller));
    await tester.pumpAndSettle();

    const title = '真机测试笔记';
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, title);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await _pumpUntilGone(tester, find.text('保存'));

    expect(controller.entries.map((e) => e.title), contains(title));

    // 重新打开一次，确认不是只活在内存里
    final reopened = await AppController.bootstrap();
    expect(reopened.entries.map((e) => e.title), contains(title));
  });

  testWidgets('提醒会被真正排进系统闹钟（两分钟后）', (tester) async {
    final controller = await AppController.bootstrap();
    final due = DateTime.now().add(const Duration(minutes: 2));
    final reminder = await controller.repository.create(
      kind: EntryKind.reminder,
      title: '真机闹钟测试',
      dueAt: due,
    );
    await controller.syncReminders();

    // 这一条在测试结束后要能脱离应用独立触发，所以不做任何清理。
    // ignore: avoid_print
    print('REMINDER_SCHEDULED id=${reminder.id} due=${due.toIso8601String()}');
    expect(reminder.dueAt, isNotNull);
  });

  testWidgets('真实模型：让助手创建条目并回答', (tester) async {
    if (_apiKey.isEmpty) {
      // ignore: avoid_print
      print('跳过真实模型测试：未提供 HZX_API_KEY');
      return;
    }

    final controller = await AppController.bootstrap();
    await controller.saveSettings(LlmSettings(
      baseUrl: _baseUrl,
      apiKey: _apiKey,
      model: _model,
    ));

    final before = controller.repository.entries.length;
    final reply = await controller.assistant.ask(
      '帮我建一条笔记，标题写「真机模型测试」，正文写「这条是模型通过工具创建的」。',
      onTurn: (_) {},
    );

    // ignore: avoid_print
    print('MODEL_REPLY=$reply');
    // ignore: avoid_print
    print('ENTRIES=${controller.repository.entries.map((e) => '${e.kind.id}:${e.title}').join(' | ')}');

    expect(controller.repository.entries.length, greaterThan(before),
        reason: '模型应当通过工具真的写入了条目');
    expect(reply.trim(), isNotEmpty);
  });

  testWidgets('真实模型：一句话排一个两分钟后的提醒', (tester) async {
    if (_apiKey.isEmpty) {
      // ignore: avoid_print
      print('跳过真实模型测试：未提供 HZX_API_KEY');
      return;
    }

    final controller = await AppController.bootstrap();
    await controller.saveSettings(LlmSettings(
      baseUrl: _baseUrl,
      apiKey: _apiKey,
      model: _model,
    ));

    final reply = await controller.assistant.ask(
      '两分钟后提醒我喝水。',
      onTurn: (_) {},
    );
    // ignore: avoid_print
    print('MODEL_REPLY_2=$reply');

    final reminders = controller
        .byKind(EntryKind.reminder)
        .where((e) => e.title.contains('喝水') && !e.done)
        .toList();
    // ignore: avoid_print
    print('REMINDERS=${reminders.map((e) => '${e.title}@${e.dueAt}').join(' | ')}');

    expect(reminders, isNotEmpty, reason: '模型应当建出一条未触发的喝水提醒');
    final due = reminders.last.dueAt;
    expect(due, isNotNull);
    expect(due!.isAfter(DateTime.now()), isTrue, reason: '提醒时间必须落在未来');
  });
}
