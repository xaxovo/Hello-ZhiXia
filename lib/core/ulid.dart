/// ULID：48 位毫秒时间戳 + 80 位随机数，Crockford Base32 编码为 26 个字符。
///
/// 为什么不用自增 ID 或纯随机 UUID：ULID 的前 10 个字符就编码了时间，
/// 因此「按 ID 排序 ≈ 按创建时间排序」，操作日志天然有序，
/// 且无需额外的自增列或中心化发号器。
///
/// 同一毫秒内生成多个 ID 时，随机部分递增而不是重新取随机数，
/// 保证严格单调 —— 否则同一毫秒内的两条操作无法确定全序。
library;

import 'dart:math';
import 'dart:typed_data';

/// Crockford Base32：去掉了容易混淆的 I / L / O / U。
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const int _timeLength = 10;
const int _randomChars = 16;
const int _randomBytes = 10;

final RegExp _pattern = RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$');

final class Ulid {
  const Ulid._();

  static bool isValid(String value) => _pattern.hasMatch(value);

  /// 取回 ULID 里编码的毫秒时间戳。
  static int timeOf(String value) {
    if (!isValid(value)) {
      throw FormatException('不是合法的 ULID', value);
    }
    var time = 0;
    for (var i = 0; i < _timeLength; i++) {
      time = (time << 5) | _alphabet.indexOf(value[i]);
    }
    return time;
  }

  /// 编码 48 位时间戳为前 10 个字符。
  static String encodeTime(int timeMs) {
    final clamped = timeMs & 0xFFFFFFFFFFFF;
    final buffer = StringBuffer();
    for (var i = _timeLength - 1; i >= 0; i--) {
      buffer.write(_alphabet[(clamped >> (5 * i)) & 0x1F]);
    }
    return buffer.toString();
  }

  /// 把 10 字节随机数编码为后 16 个字符（80 位 = 16 × 5 位，正好整除）。
  static String encodeRandom(Uint8List bytes) {
    assert(bytes.length == _randomBytes);
    final buffer = StringBuffer();
    var accumulator = 0;
    var bits = 0;
    for (final byte in bytes) {
      accumulator = (accumulator << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        buffer.write(_alphabet[(accumulator >> bits) & 0x1F]);
      }
    }
    assert(buffer.length == _randomChars);
    return buffer.toString();
  }

  /// 把后 16 个字符当作 80 位整数加一，用于同毫秒内的单调递增。
  static String incrementRandom(String encoded) {
    final chars = encoded.split('');
    for (var i = chars.length - 1; i >= 0; i--) {
      final value = _alphabet.indexOf(chars[i]);
      if (value < _alphabet.length - 1) {
        chars[i] = _alphabet[value + 1];
        return chars.join();
      }
      chars[i] = _alphabet[0];
    }
    throw StateError('ULID 随机位溢出：同一毫秒内生成的操作过多');
  }
}

/// ULID 生成器。注入 [Random] 与时钟是为了让测试可以完全确定。
final class UlidGenerator {
  UlidGenerator({Random? random, int Function()? clock})
      : _random = random ?? Random.secure(),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Random _random;
  final int Function() _clock;

  int _lastTime = 0;
  String? _lastRandom;

  String next() {
    final now = _clock();
    if (_lastRandom == null || now > _lastTime) {
      _lastTime = now;
      _lastRandom = Ulid.encodeRandom(_nextBytes());
    } else {
      // 时钟没走或回拨：保持在已用过的最大时间里继续递增，
      // 这样即使系统时间被调回去，ID 依然严格单调。
      _lastRandom = Ulid.incrementRandom(_lastRandom!);
    }
    return Ulid.encodeTime(_lastTime) + _lastRandom!;
  }

  Uint8List _nextBytes() {
    final bytes = Uint8List(_randomBytes);
    for (var i = 0; i < _randomBytes; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }
}
