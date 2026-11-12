/// 应用入口。
library;

import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'theme.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final controller = await AppController.bootstrap();
    runApp(HxzApp(controller: controller));
  } on Object catch (error) {
    runApp(_StartupFailure(error: '$error'));
  }
}

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
class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error});

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
