/// 混合逻辑时钟（Hybrid Logical Clock）。
///
/// 它同时提供两样东西：
/// - **物理时间**：`wall` 尽量贴近真实时间，用户可以理解「这条笔记是什么时候写的」
/// - **因果顺序**：即使系统时间被回拨或不准，`(wall, counter)` 依然严格单调，
///   日志的全序不会因为时钟问题而错乱
///
/// 见 doc/data-model.md 第二节。
library;

import 'dart:math' as math;

/// 一个逻辑时间戳。三元组 `(wall, counter, deviceId)` 构成全序。
final class Hlc implements Comparable<Hlc> {
  const Hlc({required this.wall, required this.counter, required this.deviceId});

  /// 毫秒级物理时间。
  final int wall;

  /// 同一毫秒内的序号，物理时间停滞时靠它拉出顺序。
  final int counter;

  /// 产生这条时间戳的设备。多设备时用于区分同毫秒同序号的两次写入。
  final String deviceId;

  DateTime get asDateTime => DateTime.fromMillisecondsSinceEpoch(wall);

  @override
  int compareTo(Hlc other) {
    if (wall != other.wall) return wall.compareTo(other.wall);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return deviceId.compareTo(other.deviceId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.wall == wall &&
      other.counter == counter &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(wall, counter, deviceId);

  @override
  String toString() => '$deviceId@$wall.$counter';

  Map<String, Object?> toJson() => {'wall': wall, 'counter': counter, 'deviceId': deviceId};

  factory Hlc.fromJson(Map<String, Object?> json) => Hlc(
        wall: json['wall']! as int,
        counter: json['counter']! as int,
        deviceId: json['deviceId']! as String,
      );
}

/// 产生 [Hlc] 的时钟。
///
/// 物理时间通过 [physicalClock] 注入，测试可以用一个可控的假时钟
/// 来复现「时钟回拨」「同一毫秒内多次写入」这类边界。
final class HybridLogicalClock {
  HybridLogicalClock({
    required this.deviceId,
    int Function()? physicalClock,
  }) : _physicalClock = physicalClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String deviceId;
  final int Function() _physicalClock;

  int _wall = 0;
  int _counter = 0;

  Hlc get last => Hlc(wall: _wall, counter: _counter, deviceId: deviceId);

  /// 产生一个**严格大于**此前所有时间戳的新时间戳。
  Hlc tick() {
    final now = _physicalClock();
    if (now > _wall) {
      _wall = now;
      _counter = 0;
    } else {
      // 物理时间没有前进（同一毫秒内第二次写入，或系统时钟被回拨）：
      // 只推进逻辑部分，绝不倒退。
      _counter += 1;
    }
    return last;
  }

  /// 观测到一个外部时间戳后推进本地时钟。
  ///
  /// 这是标准的 HLC receive 规则（Kulkarni et al. 2014），四个分支缺一不可：
  ///
  /// ```text
  /// l' = max(l, l_m, pt)
  /// if l' == l == l_m:  c' = max(c, c_m) + 1
  /// else if l' == l:    c' = c + 1
  /// else if l' == l_m:  c' = c_m + 1
  /// else:               c' = 0
  /// ```
  ///
  /// 只要少一个分支，就可能产出一个**因果上早于**已被观测到的写入的时间戳，
  /// 那会让重放顺序错乱、并让「后写的覆盖先写的」失效。
  ///
  /// 本项目在单机形态下用于**启动时追赶磁盘上已有操作**：
  /// 加载历史日志后观测其最大时间戳，保证新写入排在它们之后。
  Hlc observe(Hlc remote) {
    final now = _physicalClock();
    final maxWall = math.max(now, math.max(_wall, remote.wall));

    if (maxWall == _wall && maxWall == remote.wall) {
      _counter = math.max(_counter, remote.counter) + 1;
    } else if (maxWall == _wall) {
      _counter += 1;
    } else if (maxWall == remote.wall) {
      _counter = remote.counter + 1;
    } else {
      _counter = 0;
    }
    _wall = maxWall;
    return last;
  }
}
