/// 时间展示的格式化。
///
/// 不引入 intl 是因为这里只需要寥寥几种格式，而多一个依赖就多一份升级与体积负担。
library;

/// 形如「今天 14:30」「明天 09:00」「11月20日 09:00」「2027年1月3日 09:00」。
String formatDue(DateTime time, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final target = DateTime(time.year, time.month, time.day);
  final clock = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  final dayDiff = target.difference(today).inDays;
  if (dayDiff == 0) return '今天 $clock';
  if (dayDiff == 1) return '明天 $clock';
  if (dayDiff == -1) return '昨天 $clock';
  if (target.year == reference.year) return '${time.month}月${time.day}日 $clock';
  return '${time.year}年${time.month}月${time.day}日 $clock';
}

/// 形如「3 分钟前」「2 小时前」「昨天」。
String formatRelative(DateTime time, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${time.month}月${time.day}日';
}
