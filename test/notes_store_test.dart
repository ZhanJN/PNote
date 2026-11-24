/// 笔记文件层测试（1.41）。
///
/// 全部用临时目录 + [setNotesRootOverride]，不碰 path_provider，也不碰数据库，
/// 所以是纯 Dart I/O，不需要 tester.runAsync。
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
    temp = await Directory.systemTemp.createTemp('pnote_notes_');
    setNotesRootOverride(temp);
  });

  tearDown(() async {
    setNotesRootOverride(null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('新建笔记：按年月归档、文件名带时间、内容有标题行', () async {
    final note = await store.create('白板复盘');
    expect(note.relPath, endsWith('.md'));
    expect(note.relPath, contains('白板复盘'));
    expect(note.relPath.split('/').length, 3, reason: '年/月/文件');

    final text = await store.read(note.relPath);
    expect(text, '# 白板复盘\n\n');

    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.title, '白板复盘');
    expect(list.single.size, greaterThan(0));
  });

  test('同一分钟建两篇同名笔记不会互相覆盖', () async {
    final a = await store.create('同名');
    final b = await store.create('同名');
    expect(a.relPath, isNot(b.relPath));
    expect(await File(p.join(temp.path, a.relPath)).exists(), isTrue);
    expect(await File(p.join(temp.path, b.relPath)).exists(), isTrue);
  });

  test('原子写入：写完整内容并读回，库里不留 .tmp', () async {
    final note = await store.create('草稿');
    const body = '# 草稿\n\n第一行\n第二行\n';
    await store.write(note.relPath, body);
    expect(await store.read(note.relPath), body);

    final leftovers = temp
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('标题优先读第一行 `# 标题`，没有标题行时退回文件名', () async {
    final note = await store.create('有标题');
    await store.write(note.relPath, '# 改过的标题\n\n正文');
    final list = await store.list();
    expect(list.single.title, '改过的标题');

    final plain = File(p.join(temp.path, '2026', '11', '2026-11-23 0900 无标题行.md'));
    await plain.parent.create(recursive: true);
    await plain.writeAsString('正文第一行没有井号\n');
    final again = await store.list();
    final found = again.firstWhere((n) => n.relPath.endsWith('无标题行.md'));
    expect(found.title, '无标题行');
    expect(found.createdAt, DateTime(2026, 11, 23, 9, 0));
  });

  test('删除只是移入 .trash：原件还在，列表里消失', () async {
    final note = await store.create('要删的');
    await store.delete(note);

    expect(await store.list(), isEmpty);
    final trash = await store.listTrash();
    expect(trash, hasLength(1));
    expect(trash.single.title, '要删的');

    final moved = File(p.join(temp.path, '.trash', trash.single.relPath));
    expect(await moved.exists(), isTrue);
  });

  test('清空回收目录返回删除篇数，之后目录仍可用', () async {
    await store.delete(await store.create('甲'));
    await store.delete(await store.create('乙'));
    expect(await store.emptyTrash(), 2);
    expect(await store.listTrash(), isEmpty);
    expect(await Directory(p.join(temp.path, '.trash')).exists(), isTrue);
  });

  test('改名：文件、素材目录、全库 [[旧名]] 一起改', () async {
    final target = await store.create('旧名');
    await store.importAsset(target, await _asset(temp, 'a.png'));

    final other = await store.create('引用者');
    await store.write(other.relPath, '# 引用者\n\n见 [[旧名]] 和 ![[old.png]]\n');

    final renamed = await store.renameFile(target, '新名');
    expect(renamed.relPath, contains('新名'));
    expect(await File(p.join(temp.path, target.relPath)).exists(), isFalse);
    expect(
      await Directory(p.join(temp.path, renamed.assetsRelPath)).exists(),
      isTrue,
    );

    final text = await store.read(other.relPath);
    expect(text, contains('[[新名]]'));
    // 指向别的素材的引用不能被动到
    expect(text, contains('![[old.png]]'));
  });

  test('改名同时改正文标题行，列表标题跟着变（1.42）', () async {
    final note = await store.create('旧标题');
    expect((await store.list()).first.title, '旧标题');

    final renamed = await store.renameFile(note, '新标题');
    expect(await store.read(renamed.relPath), startsWith('# 新标题'));
    // 列表标题读的是正文第一行，不同步就会出现「改了名但列表没变化」
    expect((await store.list()).first.title, '新标题');
  });

  test('改名不会覆盖用户自己写的大标题', () async {
    final note = await store.create('文件名');
    await store.write(note.relPath, '# 完全不同的标题\n\n正文\n');

    final renamed = await store.renameFile(note, '新文件名');
    final text = await store.read(renamed.relPath);
    expect(text, startsWith('# 完全不同的标题'));
    expect((await store.list()).first.title, '完全不同的标题');
  });

  test('重名会被拒绝，不会静默覆盖', () async {
    await store.create('占位');
    final second = await store.create('占位二');
    expect(
      () => store.renameFile(second, '占位'),
      throwsA(isA<NotesIoException>()),
    );
  });

  test('导入素材：重名自动加序号，素材目录跟着笔记', () async {
    final note = await store.create('带图');
    final source = await _asset(temp, 'shot.png');

    final first = await store.importAsset(note, source);
    final second = await store.importAsset(note, source);
    expect(first, 'shot.png');
    expect(second, 'shot (2).png');

    final assets = await store.assetsOf(note.id);
    expect(assets.keys, containsAll(<String>['shot.png', 'shot (2).png']));
  });

  test('非法字符被清掉，文件名在 Windows 上也合法', () async {
    final note = await store.create(r'a/b:c*d?e"f<g>h|i');
    final name = p.basename(note.relPath);
    for (final bad in <String>['/', ':', '*', '?', '"', '<', '>', '|']) {
      expect(name.contains(bad), isFalse, reason: '不能含 $bad');
    }
    expect(name, contains('a b c d e f g h i'));
  });

  test('写出笔记库会被拒绝', () async {
    expect(
      () => store.write('../逃出去.md', 'x'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('文件名解析：时间前缀与链接名', () {
    expect(parseStamp('2026-11-23 2041 白板复盘.md'), DateTime(2026, 11, 23, 20, 41));
    expect(parseStamp('随手记.md'), isNull);
    expect(titleFromFileName('2026-11-23 2041 白板复盘.md'), '白板复盘');
    expect(titleFromFileName('随手记.md'), '随手记');
    expect(linkStemOf('2026/11/2026-11-23 2041 白板复盘.md'), '白板复盘');
  });
}

/// 造一个假素材文件（随便写点字节）。
Future<File> _asset(Directory temp, String name) async {
  final dir = Directory(p.join(temp.path, '外面临时'));
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(List<int>.generate(32, (i) => i));
  return file;
}
