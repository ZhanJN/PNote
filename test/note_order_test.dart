/// 笔记组内顺序（`.order.json`）测试（1.46）。
///
/// 纯文件 I/O：临时目录 + [setNotesRootOverride]，不需要 runAsync。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_store.dart';

void main() {
  late Directory temp;
  const store = NotesStore();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pnote_order_');
    setNotesRootOverride(temp);
  });

  tearDown(() async {
    setNotesRootOverride(null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// 直接铺一篇笔记（文件名决定 createdAt），返回库内相对路径。
  Future<String> seed(String stamp, String title) async {
    final rel = '2026/11/$stamp $title.md';
    final file = File(p.join(temp.path, '2026', '11', '$stamp $title.md'));
    await file.parent.create(recursive: true);
    await file.writeAsString('# $title\n\n正文\n');
    return rel;
  }

  test('默认按创建时间倒序（没有 .order.json 时）', () async {
    final a = await seed('2026-11-21 0900', '周一');
    final b = await seed('2026-11-22 0900', '周二');
    final c = await seed('2026-11-23 0900', '周三');

    final list = await store.list();
    expect(list.map((note) => note.relPath).toList(), [c, b, a]);
  });

  test('写 .order.json 后组内顺序跟着变，且文件落在库根', () async {
    final a = await seed('2026-11-21 0900', '周一');
    final b = await seed('2026-11-22 0900', '周二');
    final c = await seed('2026-11-23 0900', '周三');

    await store.writeOrder('2026-11', [a, c, b]);
    expect(File(p.join(temp.path, kOrderFileName)).existsSync(), isTrue);

    final list = await store.list();
    expect(list.map((note) => note.relPath).toList(), [a, c, b]);
    expect(await store.readOrder(), {
      '2026-11': [a, c, b],
    });
  });

  test('顺序表里没有的新笔记仍排在本月最上面', () async {
    final a = await seed('2026-11-21 0900', '周一');
    final b = await seed('2026-11-22 0900', '周二');
    await store.writeOrder('2026-11', [a, b]);

    final fresh = await seed('2026-11-24 0900', '新来的');
    final list = await store.list();
    expect(list.first.relPath, fresh);
    expect(list.map((note) => note.relPath).toList(), [fresh, a, b]);
  });

  test('新的月份分组排在旧的上面，各自组内按自己的顺序', () async {
    final nov = await seed('2026-11-21 0900', '十一月');
    final decFile = File(p.join(temp.path, '2026', '12', '2026-12-02 0900 十二月.md'));
    await decFile.parent.create(recursive: true);
    await decFile.writeAsString('# 十二月\n\n');
    final dec = '2026/12/2026-12-02 0900 十二月.md';

    await store.writeOrder('2026-11', [nov]);
    final list = await store.list();
    expect(list.map((note) => note.relPath).toList(), [dec, nov]);
  });

  test('.order.json 坏掉时退回时间倒序，库照样能打开', () async {
    final a = await seed('2026-11-21 0900', '周一');
    final b = await seed('2026-11-22 0900', '周二');
    await File(p.join(temp.path, kOrderFileName)).writeAsString('{ 这不是 JSON');

    expect(await store.readOrder(), isEmpty);
    final list = await store.list();
    expect(list.map((note) => note.relPath).toList(), [b, a]);
  });

  test('writeOrder 只覆盖指定的分组，其它分组原样保留', () async {
    await store.writeOrder('2026-11', ['x.md']);
    await store.writeOrder('2026-12', ['y.md']);
    await store.writeOrder('2026-11', ['z.md']);

    expect(await store.readOrder(), {
      '2026-11': ['z.md'],
      '2026-12': ['y.md'],
    });
  });

  test('monthKeyOf 补零到两位', () {
    expect(monthKeyOf(DateTime(2026, 1, 5)), '2026-01');
    expect(monthKeyOf(DateTime(2026, 11, 5)), '2026-11');
  });
}
