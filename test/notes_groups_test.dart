/// 笔记「组」清单测试（1.48）。
///
/// 组 = 磁盘一级目录 ∪ 库根 `.groups.json` 清单；同一篇笔记可以进多个组。
/// 这里测纯函数与清单读写，`mergePhysical` 用真实临时目录（`test()` 里可以真
/// 异步 I/O，不像 `testWidgets` 那样卡在假时钟上）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/notes/notes_groups.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_store.dart';

NoteFile _note(String relPath) => NoteFile(
      relPath: relPath,
      title: relPath.split('/').last.replaceAll('.md', ''),
      createdAt: DateTime(2026, 11, 23),
      modified: DateTime(2026, 11, 23),
      size: 10,
    );

void main() {
  group('清单解析', () {
    test('正常清单：去重、排序、反斜杠归一', () {
      final groups = parseGroups('''
{
  "工作": ["2026/11/b.md", "2026\\\\11\\\\a.md", "2026/11/b.md"],
  "生活": ["2026/11/c.md"]
}
''');
      expect(groups.names, ['工作', '生活']);
      expect(groups.byGroup['工作'], ['2026/11/a.md', '2026/11/b.md']);
    });

    test('坏 JSON / 空清单 → 空表，不抛', () {
      expect(parseGroups(null).names, isEmpty);
      expect(parseGroups('').names, isEmpty);
      expect(parseGroups('{oops').names, isEmpty);
      expect(parseGroups('[1,2,3]').names, isEmpty);
      expect(parseGroups('{"工作": "不是列表"}').names, isEmpty);
    });

    test('嵌套组名：一级名去重，归属按一级组汇总', () {
      final groups = NoteGroups({
        '工作/项目A': ['2026/11/a.md'],
        '工作/项目B': ['2026/11/b.md'],
        '生活': ['2026/11/c.md'],
      });
      expect(groups.topNames, ['工作', '生活']);
      expect(groups.notesUnder('工作'), {'2026/11/a.md', '2026/11/b.md'});
      expect(topOf('工作/项目A'), '工作');
      expect(topOf('生活'), '生活');
    });

    test('一篇笔记可以在多个组里（多对多）', () {
      final groups = NoteGroups({
        '工作': ['2026/11/a.md'],
        '生活': ['2026/11/a.md', '2026/11/b.md'],
      });
      expect(groups.groupsOf('2026/11/a.md'), ['工作', '生活']);
      expect(groups.groupsOf('2026/11/b.md'), ['生活']);
      expect(groups.groupsOf('2026/11/zzz.md'), isEmpty);
    });

    test('序列化后能原样读回来', () {
      final groups = NoteGroups({
        '生活': ['2026/11/c.md'],
        '工作': ['2026/11/a.md'],
      });
      final again = parseGroups(encodeGroups(groups));
      expect(again.names, ['工作', '生活']);
      expect(again.byGroup['工作'], ['2026/11/a.md']);
    });

    test('时间目录与内部名不算组', () {
      expect(isYearDir('2026'), isTrue);
      expect(isYearDir('2026年'), isFalse);
      expect(isInternalName('.trash'), isTrue);
      expect(isInternalName('x.assets'), isTrue);
      expect(isInternalName('工作'), isFalse);
      expect(topDirOf('2026/11/a.md'), '2026');
      expect(topDirOf('工作/a.md'), '工作');
      expect(topDirOf('a.md'), isNull);
    });
  });

  group('磁盘目录并进组表', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('pnote_groups_');
      setNotesRootOverride(temp);
    });

    tearDown(() async {
      setNotesRootOverride(null);
      try {
        await temp.delete(recursive: true);
      } on FileSystemException {
        // 句柄还没放完时删不掉，残留不影响结果。
      }
    });

    test('物理目录（含空目录）会成为组，年份与内部目录不算', () async {
      for (final name in ['工作', '空的组', '照片', '2026', '.trash']) {
        await Directory('${temp.path}/$name').create(recursive: true);
      }
      final notes = [
        _note('工作/a.md'),
        _note('2026/11/b.md'),
        _note('照片/x.md'),
      ];
      final merged = mergePhysical(temp, const NoteGroups.empty(), notes);
      expect(merged.topNames, ['工作', '照片', '空的组']);
      expect(merged.notesUnder('工作'), {'工作/a.md'});
      expect(merged.notesUnder('空的组'), isEmpty);
      // 年份目录里的笔记不归任何组。
      expect(merged.notesUnder('2026'), isEmpty);
    });

    test('清单与物理目录同名时做并集', () async {
      await Directory('${temp.path}/工作').create(recursive: true);
      final manifest = NoteGroups({
        '工作': ['2026/11/远程.md'],
      });
      final merged = mergePhysical(temp, manifest, [_note('工作/a.md')]);
      expect(merged.notesUnder('工作'), {'工作/a.md', '2026/11/远程.md'});
    });

    test('库根的 .groups.json 能读写，坏文件当空表', () async {
      final store = const NotesStore();
      expect((await store.readGroups()).names, isEmpty);

      await store.addToGroup('生活', '2026/11/a.md');
      await store.addToGroup('生活', '2026/11/b.md');
      await store.addToGroup('工作', '2026/11/a.md');
      final groups = await store.readGroups();
      expect(groups.names, ['工作', '生活']);
      expect(groups.groupsOf('2026/11/a.md'), ['工作', '生活']);

      await store.removeFromGroup('生活', '2026/11/a.md');
      expect((await store.readGroups()).groupsOf('2026/11/a.md'), ['工作']);

      // 文件坏掉也不能让列表页崩。
      await File('${temp.path}/$kGroupsFileName').writeAsString('{坏的');
      expect((await store.readGroups()).names, isEmpty);
    });
  });
}
