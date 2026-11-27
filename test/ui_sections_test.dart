import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/shell/home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 1.17 的页面框架：顶栏功能栏（待办 / 笔记）切换是否正常。
///
/// 1.41 起笔记是真的（读写磁盘上的 Markdown），所以测试多守一条：切到笔记页
/// 不会崩、也不会卡在加载圈。
///   ① 默认落在「待办」，能看到输入框；
///   ② 点「笔记」能看到占位页，且待办专属的顶栏图标消失；
///   ③ 点回「待办」一切复原。
/// 假笔记库：只回空列表，免得 FakeAsync 里等真实文件 IO（7.40 / 7.45）。
class _EmptyStore extends NotesStore {
  const _EmptyStore();

  @override
  Future<List<NoteFile>> list({bool withPreview = false}) async =>
      const <NoteFile>[];
}
void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late TaskDao dao;
  late String path;

  setUp(() async {
    path = p.join(
      Directory.systemTemp.path,
      'pnote_sections_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    db = await openAppDatabase(overridePath: path);
    dao = await TaskDao.attach(db);
    // 笔记页会真的扫一遍库；测试里指到临时目录，不碰用户的文档目录。
    setNotesRootOverride(await Directory.systemTemp.createTemp('pnote_sections_notes_'));
  });

  tearDown(() async {
    setNotesRootOverride(null);
    await db.close();
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  });

  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(dao: dao, notesStore: const _EmptyStore())),
    );
    await settleIo(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('默认在待办：能看到输入框与两条功能栏', (tester) async {
    await pumpHome(tester);
    expect(find.text('待办'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('添加任务…'), findsOneWidget);
    expect(find.text('还没有任务，上面输入一条吧'), findsOneWidget);
    // 待办专属的顶栏图标在
    expect(find.byTooltip('回收站'), findsOneWidget);
    expect(find.byTooltip('导出备份'), findsOneWidget);
    expect(find.byTooltip('导入备份'), findsOneWidget);
  });

  testWidgets('点「笔记」切到笔记页，待办专属图标隐藏、回收站仍可进', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();

    expect(find.text('还没有笔记'), findsOneWidget);
    expect(find.text('新建第一篇笔记'), findsOneWidget);
    // 1.45 起回收站两个页签都有（统一回收站：「任务 / 笔记」两页签）；
    // 导出/导入仍然只属于待办，避免让人以为笔记会跟着任务备份走。
    expect(find.byTooltip('回收站'), findsOneWidget);
    expect(find.byTooltip('导出备份'), findsNothing);
    expect(find.byTooltip('导入备份'), findsNothing);
  });

  testWidgets('点回「待办」复原，且底栏同步按钮一直在', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待办'));
    await tester.pumpAndSettle();

    expect(find.text('添加任务…'), findsOneWidget);
    expect(find.byTooltip('回收站'), findsOneWidget);
    // 同步是全局的：两个模块都看得到同一个按钮（这里 sync 为空故禁用）
    expect(find.text('同步'), findsOneWidget);
    expect(find.textContaining('同步未启用'), findsOneWidget);
  });

  testWidgets('待办里新建的任务，切到笔记再回来还在', (tester) async {
    await tester.runAsync(() => dao.addTask('交数学作业'));
    await pumpHome(tester);
    expect(find.text('交数学作业'), findsOneWidget);

    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    expect(find.text('还没有笔记'), findsOneWidget);

    await tester.tap(find.text('待办'));
    await tester.pumpAndSettle();
    expect(find.text('交数学作业'), findsOneWidget);
    expect(find.textContaining('共 1 条'), findsOneWidget);
  });
}
