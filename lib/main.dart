/// 应用入口。装配逻辑在 [app.dart] 里，这里只负责启动与兜底。
library;

import 'package:flutter/widgets.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final controller = await AppController.bootstrap();
    runApp(HxzApp(controller: controller));
  } on Object catch (error) {
    runApp(StartupFailureApp(error: '$error'));
  }
}
