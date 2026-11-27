/// 笔记手动顺序测试（1.54）。
///
/// 1.54 起顺序只有一份：`.groups.json` 里的 `order`（组名 → 路径列表）。
/// 时间排序是临时视图，不写盘、也不覆盖手动顺序；老的 `.order.json` 不再读取。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/notes/notes_groups.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_store.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pnote_order_');
    setNotesRootOverride(temp);
  });

  tearDown(() async {
    setNotesRootOverride(null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('手动顺序写在 .groups.json，读回来一字不差', () async {
    const store = NotesStore();
    await store.writeGroups(const NoteGroups(
      groups: [NoteGroupDef(name: '工作')],
      assign: {
        '2026/11/a.md': '工作',
        '2026/11/b.md': '工作',
        '2026/11/c.md': '未分组',
      },
      order: {
        '工作': ['2026/11/c.md', '2026/11/a.md', '2026/11/b.md'],
      },
    ));

    final groups = await store.readGroups();
    expect(groups.order['工作'],
        ['2026/11/c.md', '2026/11/a.md', '2026/11/b.md']);
    // 手动顺序不等于文件时间顺序，这里能存下来就说明没被时间挤掉。
    expect(groups.groupOf('2026/11/a.md'), '工作');
  });

  test('只动一个组的手动顺序，其他组不受影响', () async {
    const store = NotesStore();
    await store.writeGroups(const NoteGroups(
      groups: [NoteGroupDef(name: '工作'), NoteGroupDef(name: '生活')],
      order: {
        '工作': ['a.md'],
        '生活': ['b.md'],
      },
    ));

    final current = await store.readGroups();
    await store.writeGroups(current.withOrder('工作', ['x.md', 'a.md']));

    final again = await store.readGroups();
    expect(again.order['工作'], ['x.md', 'a.md']);
    expect(again.order['生活'], ['b.md']);
  });

  test('v1 迁移后 v3 清单可继续写手动顺序', () async {
    final v1 = jsonEncode(<String, Object?>{
      '工作': ['2026/11/a.md'],
      '生活': ['2026/11/b.md'],
    });
    await File('${temp.path}/$kGroupsFileName').writeAsString(v1);

    const store = NotesStore();
    final migrated = await store.readGroupsMigrated();
    await store.writeGroups(migrated.withOrder('工作', ['2026/11/a.md']));

    final stored = jsonDecode(
      await File('${temp.path}/$kGroupsFileName').readAsString(),
    ) as Map<String, Object?>;
    expect(stored['version'], 3);
    final again = await store.readGroups();
    expect(again.order['工作'], ['2026/11/a.md']);
  });

  test('老的 .order.json 不再被读取', () async {
    // 即便放一个「把 a 排到最前」的旧顺序，清单也不会引用它。
    await File('${temp.path}/.order.json').writeAsString(jsonEncode(<String, Object?>{
      '2026-11': ['2026/11/a.md'],
    }));
    const store = NotesStore();
    await store.writeGroups(const NoteGroups(
      groups: [NoteGroupDef(name: '工作')],
      order: {
        '工作': ['2026/11/z.md'],
      },
    ));

    final groups = await store.readGroups();
    expect(groups.order['工作'], ['2026/11/z.md']);
    expect(await File('${temp.path}/.order.json').exists(), isTrue);
    expect(kLegacyOrderFileName, '.order.json');
  });
}
