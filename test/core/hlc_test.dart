import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/core/hlc.dart';

void main() {
  group('tick', () {
    test('物理时间前进时 counter 归零', () {
      var now = 1000;
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => now);

      expect(clock.tick(), const Hlc(wall: 1000, counter: 0, deviceId: 'a'));
      now = 2000;
      expect(clock.tick(), const Hlc(wall: 2000, counter: 0, deviceId: 'a'));
    });

    test('同一毫秒内靠 counter 严格递增', () {
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => 1000);
      final first = clock.tick();
      final second = clock.tick();
      final third = clock.tick();

      expect(second > first, isTrue);
      expect(third > second, isTrue);
      expect(second.counter, 1);
      expect(third.counter, 2);
    });

    test('系统时钟回拨也不会产出更小的时间戳', () {
      var now = 5000;
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => now);

      final before = clock.tick();
      now = 3000; // 回拨 2 秒
      final after = clock.tick();

      expect(after > before, isTrue, reason: 'HLC 的职责就是让全序不依赖物理时钟的准确性');
      expect(after.wall, 5000, reason: '时间戳不倒退，只是不再跟随物理时间');
    });
  });

  group('observe —— 标准四个分支', () {
    test('物理时间最靠前：counter 归零', () {
      var now = 1000;
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => now);
      clock.tick(); // (1000, 0)

      now = 5000;
      final result = clock.observe(const Hlc(wall: 3000, counter: 3, deviceId: 'b'));

      expect(result, const Hlc(wall: 5000, counter: 0, deviceId: 'a'));
    });

    test('对端时间最靠前：取对端 counter + 1', () {
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => 1000);
      clock.tick(); // (1000, 0)

      final result = clock.observe(const Hlc(wall: 2000, counter: 3, deviceId: 'b'));

      expect(result, const Hlc(wall: 2000, counter: 4, deviceId: 'a'));
    });

    test('本地与对端时间相同：取两者 counter 的最大值 + 1', () {
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => 1000);
      clock.tick();
      clock.tick(); // (1000, 1)

      final result = clock.observe(const Hlc(wall: 1000, counter: 5, deviceId: 'b'));

      expect(result, const Hlc(wall: 1000, counter: 6, deviceId: 'a'));
    });

    test('本地最靠前：本地 counter + 1', () {
      var now = 2000;
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => now);
      clock.tick(); // (2000, 0)

      now = 1500; // 本地物理时间比对端落后，但逻辑时间已经到过 2000
      final result = clock.observe(const Hlc(wall: 1000, counter: 9, deviceId: 'b'));

      expect(result, const Hlc(wall: 2000, counter: 1, deviceId: 'a'));
    });

    test('观测之后产生的时间戳必然晚于被观测的那一条', () {
      var now = 1000;
      final clock = HybridLogicalClock(deviceId: 'a', physicalClock: () => now);
      const remote = Hlc(wall: 900, counter: 0, deviceId: 'b');

      clock.observe(remote);
      final next = clock.tick();

      expect(next > remote, isTrue);
    });
  });

  group('全序', () {
    test('先比 wall，再比 counter，最后比 deviceId', () {
      final a = const Hlc(wall: 1, counter: 0, deviceId: 'a');
      final b = const Hlc(wall: 2, counter: 0, deviceId: 'a');
      final c = const Hlc(wall: 2, counter: 1, deviceId: 'a');
      final d = const Hlc(wall: 2, counter: 1, deviceId: 'b');

      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(c), lessThan(0));
      expect(c.compareTo(d), lessThan(0));
      expect(d.compareTo(d), 0);
    });
  });
}
