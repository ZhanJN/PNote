/// 统一回收站（1.45）的界面接线测试。
///
/// 守三件事：
///   1. 一个页面两个页签，从哪个模块进来落在哪个页签；
///   2. 「任务」页签还是原来的墓碑语义（数据库里删掉的那几条）；
///   3. 「笔记」页签读的是笔记库的 `.trash`，能多选。
///
/// 任务侧要等真实的 sqflite I/O，所以照旧用 tester.runAsync 放出去（7.40）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/trash/notes_trash_view.dart';
import 'package:pnote/ui/trash/tasks_trash_view.dart';
import 'package:pnote/ui/trash/trash_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 只实现列表：restore/purge 的真实行为由 notes_trash_test.dart 覆盖。
class _FakeNotesStore extends NotesStore {
  const _FakeNotesStore(this.entries);

  final List<TrashEntry> entries;

  @override
  Future<List<TrashEntry>> listTrash() async => entries;
}

TrashEntry _entry(String title, {int hour = 14, int minute = 5}) {
  return TrashEntry(
    relPath: '2026-11-23 ${hour.toString().padLeft(2, '0')}'
        '${minute.toString().padLeft(2, '0')} $title/$title.md',
    movedAt: DateTime(2026, 11, 23, hour, minute),
    title: title,
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late TaskDao dao;
  late String dbPath;

  setUp(() async {
    dbPath = p.join(
      Directory.systemTemp.path,
      'pnote_trash_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    db = await openAppDatabase(overridePath: dbPath);
    dao = await TaskDao.attach(db);
  });

  tearDown(() async {
    await db.close();
    final f = File(dbPath);
    if (f.existsSync()) f.deleteSync();
  });

  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
  }

  Future<void> pumpTrash(
    WidgetTester tester, {
    NotesStore store = const _FakeNotesStore(<TrashEntry>[]),
    int initialTab = 0,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: TrashPage(dao: dao, store: store, initialTab: initialTab),
    ));
    await settleIo(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('一个页面两个页签：任务 / 笔记', (tester) async {
    await pumpTrash(tester);
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  testWidgets('从笔记页进来时直接落在「笔记」页签（1.45）', (tester) async {
    await pumpTrash(
      tester,
      store: _FakeNotesStore([_entry('白板复盘')]),
      initialTab: 1,
    );
    await settleIo(tester);
    await tester.pumpAndSettle();

    expect(find.text('笔记回收站是空的'), findsNothing);
    expect(find.text('白板复盘'), findsOneWidget);
    expect(find.textContaining('删除于 11-23 14:05'), findsOneWidget);
  });

  testWidgets('笔记页签能多选，底部出现恢复/永久删除（1.45）', (tester) async {
    await pumpTrash(
      tester,
      store: _FakeNotesStore([_entry('甲'), _entry('乙', hour: 15)]),
      initialTab: 1,
    );
    await settleIo(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(NotesTrashView),
      matching: find.byTooltip('多选'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 篇'), findsOneWidget);

    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 篇'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NotesTrashView),
        matching: find.text('恢复'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('任务页签保留墓碑列表与「恢复」按钮（1.45 未改语义）', (tester) async {
    await tester.runAsync(() async {
      await dao.addTask('买菜');
      final all = await dao.visibleTasks();
      await dao.softDelete(all.single.id);
    });
    await pumpTrash(tester);
    await settleIo(tester);
    await tester.pumpAndSettle();

    expect(find.text('买菜'), findsOneWidget);
    expect(find.textContaining('删除于'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TasksTrashView),
        matching: find.byTooltip('恢复'),
      ),
      findsOneWidget,
    );
  });
}
