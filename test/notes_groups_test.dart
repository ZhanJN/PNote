/// 笔记「组」清单 v2 测试（1.54）。
///
/// 组只是标签：一篇笔记最多一个组，组本身只有名字/颜色/折叠/顺序四样。
/// 老格式（多对多）在读取时迁移，一篇只保留第一个出现的组。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/notes/notes_groups.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_store.dart';

String _v2({
  List<Map<String, Object?>> groups = const [],
  Map<String, String> assign = const {},
  Map<String, List<String>> order = const {},
}) {
  return jsonEncode(<String, Object?>{
    'version': 2,
    'groups': groups,
    'assign': assign,
    'order': order,
  });
}

void main() {
  group('v2 解析', () {
    test('组按 order 排序；归属、手动顺序、折叠、颜色都读回', () {
      final groups = parseGroups(_v2(
        groups: [
          {'name': '生活', 'color': 2, 'collapsed': false, 'order': 2048},
          {'name': '工作', 'color': 1, 'collapsed': true, 'order': 1024},
        ],
        assign: {
          '2026/11/a.md': '工作',
          '2026\\11\\b.md': '生活',
          '2026/11/zzz.md': '已经不存在的组',
        },
        order: {
          '工作': ['2026/11/a.md'],
          '': ['2026/11/u.md'],
        },
      ));
      expect(groups.names, ['工作', '生活']);
      expect(groups.groupOf('2026/11/a.md'), '工作');
      expect(groups.groupOf('2026/11/b.md'), '生活');
      expect(groups.groupOf('2026/11/zzz.md'), isNull);
      expect(groups.isCollapsed('工作'), isTrue);
      expect(groups.groupNamed('生活')!.color, 2);
      expect(groups.order['工作'], ['2026/11/a.md']);
      expect(groups.order[''], ['2026/11/u.md']);
    });

    test('坏 JSON / 空 / 非对象 → 空表，不抛', () {
      expect(parseGroups(null).names, isEmpty);
      expect(parseGroups('').names, isEmpty);
      expect(parseGroups('{oops').names, isEmpty);
      expect(parseGroups('[1,2,3]').names, isEmpty);
      expect(parseGroups('{"工作": "不是列表"}').names, isEmpty);
    });

    test('encode → parse 往返不丢信息', () {
      final original = NoteGroups(
        groups: const [
          NoteGroupDef(name: '工作', color: 3, collapsed: true, order: 0),
          NoteGroupDef(name: '生活', color: 5, order: 1024),
        ],
        assign: const {
          '2026/11/a.md': '工作',
          '2026/11/b.md': '生活',
        },
        order: const {
          '工作': ['2026/11/a.md'],
          '': ['2026/11/u.md'],
        },
      );
      final again = parseGroups(encodeGroups(original));
      expect(again.names, ['工作', '生活']);
      expect(again.groupNamed('工作')!.collapsed, isTrue);
      expect(again.groupNamed('工作')!.color, 3);
      expect(again.groupOf('2026/11/b.md'), '生活');
      expect(again.order['工作'], ['2026/11/a.md']);
      expect(again.order[''], ['2026/11/u.md']);
    });
  });

  group('v1 迁移', () {
    test('多对多 → 单归属：先出现的组赢', () {
      final groups = parseGroups(jsonEncode(<String, Object?>{
        '工作': ['2026/11/a.md', '2026/11/b.md'],
        '生活': ['2026/11/b.md', '2026/11/c.md'],
      }));
      expect(groups.names, ['工作', '生活']);
      expect(groups.groupOf('2026/11/a.md'), '工作');
      expect(groups.groupOf('2026/11/b.md'), '工作');
      expect(groups.groupOf('2026/11/c.md'), '生活');
    });

    test('反斜杠归一、重复路径去掉、空组保留', () {
      final groups = parseGroups(jsonEncode(<String, Object?>{
        '工作': ['2026\\11\\a.md', '2026/11/a.md'],
        '空的': <String>[],
      }));
      expect(groups.names, ['工作', '空的']);
      expect(groups.order['工作'], isNull);
      expect(groups.groupOf('2026/11/a.md'), '工作');
    });
  });

  group('组操作', () {
    final base = NoteGroups(
      groups: const [
        NoteGroupDef(name: '工作', order: 0),
        NoteGroupDef(name: '生活', order: 1024),
      ],
      assign: const {
        'a.md': '工作',
        'b.md': '工作',
        'c.md': '生活',
      },
      order: const {
        '工作': ['b.md', 'a.md'],
      },
    );

    test('addGroup 追加到末尾；重名 / 空名不动', () {
      final added = base.addGroup(' 学习 ', color: 9);
      expect(added.names, ['工作', '生活', '学习']);
      expect(added.groupNamed('学习')!.order, 2048);
      expect(added.groupNamed('学习')!.color, kGroupColorCount - 1);
      expect(identical(added.addGroup('工作'), added), isTrue);
      expect(identical(added.addGroup('   '), added), isTrue);
    });

    test('renameGroup 把归属与手动顺序一起搬', () {
      final renamed = base.renameGroup('工作', '项目');
      expect(renamed.names, ['项目', '生活']);
      expect(renamed.groupOf('a.md'), '项目');
      expect(renamed.order['项目'], ['b.md', 'a.md']);
      expect(renamed.order.containsKey('工作'), isFalse);
    });

    test('deleteGroup：笔记回未分组，笔记文件一条不动', () {
      final deleted = base.deleteGroup('工作');
      expect(deleted.names, ['生活']);
      expect(deleted.groupOf('a.md'), isNull);
      expect(deleted.groupOf('b.md'), isNull);
      expect(deleted.order.containsKey('工作'), isFalse);
    });

    test('moveGroup 换位置并重排 order', () {
      final moved = base.moveGroup('生活', -1);
      expect(moved.names, ['生活', '工作']);
      expect(moved.groups[0].order, 0);
      expect(moved.groups[1].order, kGroupOrderStep);
      expect(identical(base.moveGroup('工作', -1), base), isTrue);
    });

    test('withNoteGroup 单组覆盖，null 取消归属', () {
      final moved = base.withNoteGroup('c.md', '工作');
      expect(moved.groupOf('c.md'), '工作');
      final ungrouped = moved.withNoteGroup('c.md', null);
      expect(ungrouped.groupOf('c.md'), isNull);
    });

    test('withOrder 只替换指定组，其他组原样', () {
      final next = base.withOrder('工作', ['a.md', 'b.md']);
      expect(next.order['工作'], ['a.md', 'b.md']);
      expect(base.order['工作'], ['b.md', 'a.md']);
      expect(next.groupOf('c.md'), '生活');
    });

    test('withCollapsed / withColor 只改目标组', () {
      final collapsed = base.withCollapsed('工作', true);
      expect(collapsed.isCollapsed('工作'), isTrue);
      expect(collapsed.isCollapsed('生活'), isFalse);
      final colored = collapsed.withColor('生活', 7);
      expect(colored.groupNamed('生活')!.color, 7);
      expect(colored.groupNamed('工作')!.color, 0);
    });
  });

  group('磁盘读写', () {
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

    test('readGroupsMigrated：v1 备份成 .groups.v1.bak，写回 v3', () async {
      final v1 = jsonEncode(<String, Object?>{
        '工作': ['2026/11/a.md'],
        '生活': ['2026/11/a.md', '2026/11/b.md'],
      });
      await File('${temp.path}/$kGroupsFileName').writeAsString(v1);

      const store = NotesStore();
      final groups = await store.readGroupsMigrated();
      expect(groups.names, ['工作', '生活']);
      expect(groups.groupOf('2026/11/a.md'), '工作');
      expect(groups.groupOf('2026/11/b.md'), '生活');

      final backup = File('${temp.path}/.groups.v1.bak');
      expect(await backup.exists(), isTrue);
      expect(await backup.readAsString(), v1);

      final stored = jsonDecode(
        await File('${temp.path}/$kGroupsFileName').readAsString(),
      ) as Map<String, Object?>;
      expect(stored['version'], kGroupsVersion);
      expect(stored['version'], 3);

      // 再读一次不会重复备份，也不会改回 v1。
      await store.readGroupsMigrated();
      expect(await backup.readAsString(), v1);
    });

    test('addToGroup 是单组覆盖；不存在的组名被忽略', () async {
      const store = NotesStore();
      await store.writeGroups(const NoteGroups(
        groups: [NoteGroupDef(name: '工作'), NoteGroupDef(name: '生活')],
      ));
      await store.addToGroup('工作', '2026/11/a.md');
      await store.addToGroup('生活', '2026/11/a.md');
      expect((await store.readGroups()).groupOf('2026/11/a.md'), '生活');

      await store.addToGroup('不存在的组', '2026/11/a.md');
      expect((await store.readGroups()).groupOf('2026/11/a.md'), '生活');

      await store.addToGroup(null, '2026/11/a.md');
      expect((await store.readGroups()).groupOf('2026/11/a.md'), isNull);
    });

    test('清单坏掉时读成空表，不让列表页崩', () async {
      const store = NotesStore();
      await store.writeGroups(const NoteGroups(
        groups: [NoteGroupDef(name: '工作')],
      ));
      await File('${temp.path}/$kGroupsFileName').writeAsString('{坏的');
      expect((await store.readGroups()).names, isEmpty);
    });
  });

  group('v3 子组与置顶（1.55）', () {
    NoteGroups tree() => parseGroups(jsonEncode(<String, Object?>{
          'version': 3,
          'groups': [
            {'name': '工作', 'color': 1, 'collapsed': false, 'order': 0},
            {'name': '项目', 'color': 2, 'collapsed': false, 'order': 1024,
              'parent': '工作', 'pinned': true},
            {'name': '生活', 'color': 3, 'collapsed': false, 'order': 2048},
          ],
          'assign': {'2026/11/a.md': '项目', '2026/11/b.md': '工作'},
          'order': <String, Object?>{},
          'pins': ['2026/11/b.md'],
        }));

    test('子组挂父组，深度/子树/生效父组都对', () {
      final groups = tree();
      expect(groups.roots.map((g) => g.name), ['工作', '生活']);
      expect(groups.parentOf('项目'), '工作');
      expect(groups.depthOf('项目'), 1);
      expect(groups.depthOf('工作'), 0);
      expect(groups.subtreeNames('工作'), ['工作', '项目']);
      expect(groups.pathsOf('工作', includeDescendants: true),
          containsAll(<String>['2026/11/a.md', '2026/11/b.md']));
    });

    test('置顶组排同级最前；笔记置顶可读回', () {
      final groups = tree();
      final withPinned = groups.withGroupPinned('生活', true);
      expect(withPinned.roots.map((g) => g.name), ['生活', '工作']);
      expect(withPinned.isPinned('生活'), isTrue);
      expect(groups.isPinnedNote('2026/11/b.md'), isTrue);
      final unpinned = groups.withNotePinned('2026/11/b.md', false);
      expect(unpinned.isPinnedNote('2026/11/b.md'), isFalse);
    });

    test('删父组时子组上移一级，笔记不丢', () {
      final deleted = tree().deleteGroup('工作');
      expect(deleted.groupNamed('工作'), isNull);
      expect(deleted.parentOf('项目'), '');
      expect(deleted.groupOf('2026/11/b.md'), isNull);
      expect(deleted.groupOf('2026/11/a.md'), '项目');
      expect(deleted.depthOf('项目'), 0);
    });

    test('移动组只在同级里换，跨级不动', () {
      final groups = tree();
      // 生活是一级，工作也是一级：可以互换。
      final swapped = groups.moveGroup('生活', -1);
      expect(swapped.roots.map((g) => g.name), ['生活', '工作']);
      // 项目是工作下的子组，不可能被换到一级。
      expect(groups.moveGroup('项目', -1).parentOf('项目'), '工作');
    });

    test('v2 清单迁到 v3：缺 parent/pinned 取默认，不丢组', () {
      final migrated = parseGroups(_v2(
        groups: [
          {'name': '工作', 'order': 0},
          {'name': '生活', 'order': 1024},
        ],
        assign: {'a.md': '工作'},
        order: {'工作': ['a.md']},
      ));
      expect(migrated.names, ['工作', '生活']);
      expect(migrated.parentOf('工作'), '');
      expect(migrated.roots.length, 2);
      expect(migrated.isPinned('工作'), isFalse);
      expect(migrated.pins, isEmpty);
      expect(migrated.groupOf('a.md'), '工作');
    });

    test('父组不存在或成环时降为一级，不崩', () {
      final groups = parseGroups(jsonEncode(<String, Object?>{
        'version': 3,
        'groups': [
          {'name': '孤儿', 'order': 0, 'parent': '不存在'},
          {'name': 'A', 'order': 1024, 'parent': 'B'},
          {'name': 'B', 'order': 2048, 'parent': 'A'},
        ],
      }));
      expect(groups.parentOf('孤儿'), '');
      // 成环的一组无法判定谁在上，整段降为一级，但绝不崩。
      expect(groups.parentOf('A'), '');
      expect(groups.parentOf('B'), '');
      expect(groups.depthOf('A'), 0);
    });
  });

  test('年份目录 / 内部名不算组', () {
    expect(isYearDir('2026'), isTrue);
    expect(isYearDir('2026年'), isFalse);
    expect(isInternalName('.trash'), isTrue);
    expect(isInternalName('x.assets'), isTrue);
    expect(isInternalName('工作'), isFalse);
  });
}
