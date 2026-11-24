/// 笔记回收站的数据层测试（1.45）。
///
/// 全部用临时目录 + [setNotesRootOverride]，是纯 Dart I/O，
/// 所以不需要 tester.runAsync。界面接线由 trash_page_test.dart 覆盖。
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
    temp = await Directory.systemTemp.createTemp('pnote_trash_');
    setNotesRootOverride(temp);
  });

  tearDown(() async {
    setNotesRootOverride(null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('恢复：文件回到年/月目录，列表里重新出现（1.45）', () async {
    final note = await store.create('白板复盘');
    await store.delete(note);
    expect(await store.list(), isEmpty);

    final trash = await store.listTrash();
    expect(trash, hasLength(1));
    expect(trash.single.title, '白板复盘');

    final restored = await store.restoreTrash(trash.single);
    expect(restored.relPath, note.relPath);
    expect(await File(p.join(temp.path, restored.relPath)).exists(), isTrue);
    expect(await store.listTrash(), isEmpty);
    final list = await store.list();
    expect(list.single.title, '白板复盘');
  });

  test('恢复：素材目录一起回来（1.45）', () async {
    final note = await store.create('带图');
    final src = File(p.join(temp.path, 'src.png'));
    await src.writeAsBytes(const <int>[1, 2, 3, 4]);
    await store.importAsset(note, src);
    expect(await store.assetsOf(note.id), hasLength(1));

    await store.delete(note);
    final trash = await store.listTrash();
    final restored = await store.restoreTrash(trash.single);

    expect(await store.assetsOf(restored.id), hasLength(1));
  });

  test('恢复：目标位置已有同名文件时加序号，不覆盖（1.45）', () async {
    final note = await store.create('同名');
    await store.delete(note);
    final trash = await store.listTrash();

    // 在原路径手动放一篇（模拟「回收站里这篇」和「库里现存那篇」同名）。
    await File(p.join(temp.path, note.relPath))
        .writeAsString('# 同名\n\n库里新写的一篇\n');

    final restored = await store.restoreTrash(trash.single);
    expect(restored.relPath, isNot(note.relPath));
    expect(restored.relPath, contains('同名'));
    expect(await store.list(), hasLength(2));
  });

  test('永久删除：.md 与素材目录都被删掉，桶目录清空（1.45）', () async {
    final note = await store.create('要删的');
    final src = File(p.join(temp.path, 'a.png'));
    await src.writeAsBytes(const <int>[9, 9]);
    await store.importAsset(note, src);
    await store.delete(note);

    final trash = await store.listTrash();
    final n = await store.purgeTrash(trash);
    expect(n, 1);
    expect(await store.listTrash(), isEmpty);

    // 整个 .trash 下不该留下这篇的任何文件。
    final left = Directory(p.join(temp.path, '.trash'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path).contains('要删的'));
    expect(left, isEmpty);
  });

  test('永久删除多篇：返回篇数，只删传进来的那些（1.45）', () async {
    final a = await store.create('甲');
    final b = await store.create('乙');
    await store.delete(a);
    await store.delete(b);

    final trash = await store.listTrash();
    expect(trash, hasLength(2));
    final n = await store.purgeTrash(trash.take(1));
    expect(n, 1);
    expect(await store.listTrash(), hasLength(1));
  });
}
