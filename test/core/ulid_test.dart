import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/core/ulid.dart';

void main() {
  group('ULID 编码', () {
    test('长度固定为 26 且字符集合法', () {
      final generator = UlidGenerator(random: Random(1));
      final id = generator.next();
      expect(id.length, 26);
      expect(Ulid.isValid(id), isTrue);
    });

    test('时间戳可以被原样读回', () {
      const timeMs = 1730000000000;
      final id = UlidGenerator(random: Random(2), clock: () => timeMs).next();
      expect(Ulid.timeOf(id), timeMs);
    });

    test('拒绝非法输入', () {
      expect(Ulid.isValid('too-short'), isFalse);
      expect(Ulid.isValid('I' * 26), isFalse, reason: 'Crockford 不含 I');
      expect(() => Ulid.timeOf('nope'), throwsFormatException);
    });
  });

  group('ULID 单调性', () {
    test('同一毫秒内连续生成严格递增', () {
      final generator = UlidGenerator(random: Random(3), clock: () => 1730000000000);
      final ids = List.generate(50, (_) => generator.next());
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i].compareTo(ids[i - 1]), greaterThan(0),
            reason: '第 $i 个应当大于前一个');
      }
    });

    test('时钟回拨后依然严格递增', () {
      var now = 1730000000000;
      final generator = UlidGenerator(random: Random(4), clock: () => now);

      final before = generator.next();
      now -= 5000; // 系统时间被调回去 5 秒
      final after = generator.next();

      expect(after.compareTo(before), greaterThan(0),
          reason: '回拨不能产生比历史更小的 ID，否则日志全序会被打乱');
    });

    test('随机位溢出时明确抛错而不是静默回绕', () {
      final allMax = 'Z' * 16;
      expect(() => Ulid.incrementRandom(allMax), throwsStateError);
    });
  });
}
