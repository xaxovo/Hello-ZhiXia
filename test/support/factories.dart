/// 测试用的构造工厂。
///
/// 时间戳与 ID 全部由调用方显式给出，这样断言里出现的就是确定的数字，
/// 而不是「大约现在」。
library;

import 'package:hello_zhixia/core/hlc.dart';
import 'package:hello_zhixia/core/op.dart';
import 'package:hello_zhixia/domain/ops.dart';

const String testDevice = 'dev-test';

/// 造一条时间戳为 [timeMs] 的时间。
Hlc hlc(int timeMs, {int counter = 0, String device = testDevice}) =>
    Hlc(wall: timeMs, counter: counter, deviceId: device);

/// 造一条 `entry.create` 操作。
Op createOp({
  required String id,
  required Hlc at,
  required String title,
  String kind = 'note',
}) =>
    Op(
      opId: 'op-$id',
      hlc: at,
      entityId: id,
      type: OpTypes.create,
      payload: {
        'kind': kind,
        'title': title,
        'body': '',
        'done': false,
        'dueAt': null,
        'createdAt': at.wall,
      },
    );

/// 造一条 `entry.update` 操作。
Op updateOp({
  required String id,
  required Hlc at,
  Map<String, Object?> patch = const {},
}) =>
    Op(opId: 'op-${at.wall}-${at.counter}', hlc: at, entityId: id, type: OpTypes.update, payload: patch);
