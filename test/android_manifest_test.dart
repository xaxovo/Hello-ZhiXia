/// 守护 Android 清单文件。
///
/// 这条测试的存在是有原因的：真机调试时发现 **release 包完全连不上网** ——
/// Flutter 模板只在 `debug/` 与 `profile/` 的清单里放了 `INTERNET` 权限，
/// 于是 debug 包能跑、桌面端能跑，唯独装到手机上的 release 包「域名解析失败」。
/// 这类缺陷单元测试抓不到、静态检查抓不到、桌面端也复现不了。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');

  test('主清单存在', () {
    expect(manifest.existsSync(), isTrue);
  });

  test('主清单声明了运行期必需的权限', () {
    final content = manifest.readAsStringSync();

    // INTERNET 少了就整个助手不可用；其余三条少了则提醒不能响或重启后失效。
    const required = {
      'android.permission.INTERNET': '助手要访问云端模型接口',
      'android.permission.POST_NOTIFICATIONS': '在 Android 13+ 上要用户授权才能显示通知',
      'android.permission.SCHEDULE_EXACT_ALARM': '提醒要在设定的时刻准时响，而不是被推迟几分钟',
      'android.permission.RECEIVE_BOOT_COMPLETED': '设备重启后要把已排的提醒重新挂上',
    };

    required.forEach((permission, reason) {
      expect(
        content,
        contains(permission),
        reason: '缺少 $permission：$reason',
      );
    });
  });

  test('定时通知需要的 receiver 已注册', () {
    final content = manifest.readAsStringSync();

    expect(
      content,
      contains('com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver'),
      reason: '没有它，闹钟到点后不会有人把通知显示出来',
    );
    expect(
      content,
      contains('com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver'),
      reason: '没有它，重启一次所有提醒都会消失',
    );
  });

  test('应用名不会是默认的工程名', () {
    final content = manifest.readAsStringSync();
    expect(content, contains('android:label="知夏生活"'));
  });
}
