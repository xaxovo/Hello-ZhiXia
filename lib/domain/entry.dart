/// 领域中唯一的条目类型。
///
/// 笔记、待办、提醒在数据上是同一种东西 —— **一段带标题的文字，可能带时间、可能可勾选**。
/// 用一张表加一个 [EntryKind] 来区分，而不是三个近似的实体类，是为了让操作类型
/// 保持 3 个（create / update / delete）而不是 9 个。
///
/// 三者的差别落在展示与提醒策略上，不落在数据形状上。
library;

enum EntryKind {
  note('note', '笔记'),
  task('task', '待办'),
  reminder('reminder', '提醒');

  const EntryKind(this.id, this.label);

  final String id;
  final String label;

  static EntryKind parse(String value) =>
      EntryKind.values.firstWhere((kind) => kind.id == value, orElse: () => EntryKind.note);
}

final class Entry {
  const Entry({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.done,
    required this.dueAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final EntryKind kind;
  final String title;

  /// 笔记正文；待办与提醒通常为空。
  final String body;

  /// 待办：是否完成。提醒：是否已经响过。
  final bool done;

  /// 待办：截止时间。提醒：触发时间。
  final DateTime? dueAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  Entry copyWith({
    String? title,
    String? body,
    bool? done,
    DateTime? dueAt,
    bool clearDueAt = false,
    DateTime? updatedAt,
  }) =>
      Entry(
        id: id,
        kind: kind,
        title: title ?? this.title,
        body: body ?? this.body,
        done: done ?? this.done,
        dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.id,
        'title': title,
        'body': body,
        'done': done,
        'dueAt': dueAt?.millisecondsSinceEpoch,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory Entry.fromJson(Map<String, Object?> json) => Entry(
        id: json['id']! as String,
        kind: EntryKind.parse(json['kind']! as String),
        title: (json['title'] as String?) ?? '',
        body: (json['body'] as String?) ?? '',
        done: (json['done'] as bool?) ?? false,
        dueAt: _dateOrNull(json['dueAt']),
        createdAt: _dateOrNull(json['createdAt']) ?? DateTime.now(),
        updatedAt: _dateOrNull(json['updatedAt']) ?? DateTime.now(),
      );

  static DateTime? _dateOrNull(Object? value) =>
      value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;

  bool get isOverdue {
    final due = dueAt;
    if (due == null || done) return false;
    return due.isBefore(DateTime.now());
  }
}
