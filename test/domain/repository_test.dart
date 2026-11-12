import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_zhixia/domain/entry.dart';
import 'package:hello_zhixia/domain/repository.dart';

void main() {
  late Directory directory;

  setUp(() => directory = Directory.systemTemp.createTempSync('hzx_repo_'));
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('新建的条目在重新打开后依然存在', () async {
    final first = await HxzRepository.open(directory);
    await first.create(kind: EntryKind.note, title: '读书计划', body: '睡前半小时');
    first.dispose();

    final second = await HxzRepository.open(directory);
    final entries = second.entries;

    expect(entries.length, 1);
    expect(entries.single.title, '读书计划');
    expect(entries.single.body, '睡前半小时');
    expect(entries.single.kind, EntryKind.note);
    second.dispose();
  });

  test('修改与删除都会被持久化', () async {
    final first = await HxzRepository.open(directory);
    final created = await first.create(kind: EntryKind.task, title: '交周报');
    await first.update(created.id, title: '交周报（周五）', done: true);
    final toDelete = await first.create(kind: EntryKind.note, title: '临时');
    await first.delete(toDelete.id);
    first.dispose();

    final second = await HxzRepository.open(directory);
    final entries = second.entries;

    expect(entries.length, 1);
    expect(entries.single.title, '交周报（周五）');
    expect(entries.single.done, isTrue);
    second.dispose();
  });

  test('同一设备再次打开不会复用旧的逻辑时间戳', () async {
    final first = await HxzRepository.open(directory);
    final a = await first.create(kind: EntryKind.note, title: 'A');
    first.dispose();

    final second = await HxzRepository.open(directory);
    final b = await second.create(kind: EntryKind.note, title: 'B');
    second.dispose();

    expect(
      b.updatedAt.isBefore(a.updatedAt),
      isFalse,
      reason: '重启后新写入必须排在历史操作之后，否则折叠顺序会乱',
    );
  });

  test('操作数超过阈值后自动压缩，重开的数据仍然完整', () async {
    final first = await HxzRepository.open(directory);
    const total = 260;
    for (var i = 0; i < total; i++) {
      await first.create(kind: EntryKind.note, title: '条目 $i');
    }

    expect(first.entries.length, total);
    expect(
      first.opCount <= 220,
      isTrue,
      reason: '触发压缩后内存里只应保留尾部，否则压缩没生效',
    );
    first.dispose();

    final second = await HxzRepository.open(directory);
    expect(second.entries.length, total, reason: '压缩丢掉任何条目都是不可恢复的数据丢失');
    final titles = second.entries.map((e) => e.title).toSet();
    expect(titles.contains('条目 0'), isTrue, reason: '最早的一条必须还在');
    expect(titles.contains('条目 259'), isTrue);
    second.dispose();
  });

  test('今日视图只收未完成的待办与当天到期的提醒', () async {
    final repository = await HxzRepository.open(directory);
    final now = DateTime.now();

    await repository.create(kind: EntryKind.task, title: '无时间的待办');
    await repository.create(
      kind: EntryKind.task,
      title: '下周的待办',
      dueAt: now.add(const Duration(days: 7)),
    );
    final done = await repository.create(kind: EntryKind.task, title: '已完成', dueAt: now);
    await repository.update(done.id, done: true);
    await repository.create(
      kind: EntryKind.reminder,
      title: '今晚的提醒',
      dueAt: DateTime(now.year, now.month, now.day, 23, 59),
    );
    await repository.create(kind: EntryKind.note, title: '一条笔记');

    final today = repository.today.map((e) => e.title).toList();

    expect(today, contains('无时间的待办'));
    expect(today, contains('今晚的提醒'));
    expect(today, isNot(contains('下周的待办')));
    expect(today, isNot(contains('已完成')));
    expect(today, isNot(contains('一条笔记')));
    repository.dispose();
  });

  test('空标题不会被 trim 成空条目之外的意外结果', () async {
    final repository = await HxzRepository.open(directory);
    final entry = await repository.create(kind: EntryKind.note, title: '  带空格  ');

    expect(entry.title, '带空格');
    repository.dispose();
  });
}
