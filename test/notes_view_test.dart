/// 笔记列表页测试（1.41）。
///
/// 列表页只依赖 [NotesStore] 的接口，所以这里注入一个「假库」：
/// 不碰真实文件，也就避开了 testWidgets 的 FakeAsync 里真实 I/O 不完成的老坑
/// （7.40 / 7.42）。真实文件读写由 notes_store_test.dart 覆盖。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/notes/notes_groups.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/notes/notes_view.dart';

class _FakeStore extends NotesStore {
  _FakeStore(this.notes, {this.groups = const NoteGroups.empty()});

  final List<NoteFile> notes;

  /// 1.48：组清单也走假实现，免得在 FakeAsync 里等真实文件 IO。
  final NoteGroups groups;

  @override
  Future<NoteGroups> readGroups() async => groups;

  /// 记下有没有被调用，方便确认「切页会重扫」。
  int listCalls = 0;

  @override
  Future<List<NoteFile>> list() async {
    listCalls++;
    return notes;
  }
}

NoteFile _note(String title, {DateTime? created}) {
  final time = created ?? DateTime(2026, 11, 23, 21, 0);
  return NoteFile(
    relPath: '${time.year}/${time.month}/'
        '${time.year}-${time.month}-${time.day} 2100 $title.md',
    title: title,
    createdAt: time,
    modified: time,
    size: 2048,
  );
}

Widget _wrap(NotesStore store) =>
    MaterialApp(home: Scaffold(body: NotesView(store: store)));

void main() {
  late Directory temp;

  setUp(() async {
    // 搜索会用到库根路径（找不到文件就当没命中），给一个真实存在的临时目录。
    temp = await Directory.systemTemp.createTemp('pnote_view_');
    setNotesRootOverride(temp);
  });

  tearDown(() async {
    setNotesRootOverride(null);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  testWidgets('空库显示空态与新建入口', (tester) async {
    await tester.pumpWidget(_wrap(_FakeStore(const <NoteFile>[])));
    await tester.pump();

    expect(find.text('还没有笔记'), findsOneWidget);
    expect(find.text('新建第一篇笔记'), findsOneWidget);
  });

  testWidgets('顶栏常驻「新建」按钮（1.42 补）', (tester) async {
    await tester.pumpWidget(_wrap(_FakeStore([_note('白板复盘')])));
    await tester.pump();

    // 用户反馈「没有新建按钮」：原来只有搜索框右侧一个无字图标。
    expect(find.widgetWithText(FilledButton, '新建'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);
  });

  testWidgets('已有笔记时按年月分组列出，并报出篇数', (tester) async {
    var reported = -1;
    final store = _FakeStore([_note('白板复盘'), _note('购物清单')]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NotesView(
          store: store,
          onCountChanged: (n) => reported = n,
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('白板复盘'), findsOneWidget);
    expect(find.text('购物清单'), findsOneWidget);
    expect(find.text('2026 年 11 月'), findsOneWidget);
    expect(reported, 2);
    expect(store.listCalls, 1);
  });

  testWidgets('搜索框输入后先防抖再筛出命中项', (tester) async {
    // 只放一篇，让关键词命中标题——这样搜索不需要读正文，也就不会卡在
    // FakeAsync 里的真实文件 I/O 上（正文搜索由 notes_parse_test 覆盖）。
    final store = _FakeStore([_note('番茄钟')]);
    await tester.pumpWidget(_wrap(store));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '番茄');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('番茄钟'), findsOneWidget);
  });

  testWidgets('搜索之后清空关键词，回到完整列表', (tester) async {
    final store = _FakeStore([_note('番茄钟'), _note('购物清单')]);
    await tester.pumpWidget(_wrap(store));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '购物');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('番茄钟'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('番茄钟'), findsOneWidget);
    expect(find.text('购物清单'), findsOneWidget);
  });

  testWidgets('外部改动文件后，reload() 能重新读到', (tester) async {
    final store = _FakeStore([_note('第一篇')]);
    final key = GlobalKey<NotesViewState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NotesView(key: key, store: store)),
    ));
    await tester.pump();
    expect(find.text('第一篇'), findsOneWidget);

    store.notes
      ..clear()
      ..add(_note('第二篇'));
    await key.currentState!.reload();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 1.46：删除会收 180 ms
    expect(find.text('第二篇'), findsOneWidget);
    expect(find.text('第一篇'), findsNothing);
  });

  // --------------------------------------------------- 1.45：菜单与多选

  testWidgets('长按行弹出菜单，条目与待办页一致（1.45）', (tester) async {
    final store = _FakeStore([_note('白板复盘')]);
    await tester.pumpWidget(_wrap(store));
    await tester.pump();

    await tester.longPress(find.text('白板复盘'));
    await tester.pumpAndSettle();

    expect(find.text('打开'), findsOneWidget);
    expect(find.text('改标题'), findsOneWidget);
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('在文件夹中显示'), findsOneWidget);
  });

  testWidgets('菜单里选「多选」进入多选态，再点一行能取消（1.45）', (tester) async {
    final store = _FakeStore([_note('白板复盘'), _note('购物清单')]);
    await tester.pumpWidget(_wrap(store));
    await tester.pump();

    await tester.longPress(find.text('白板复盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 篇'), findsOneWidget);

    await tester.tap(find.text('购物清单'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 篇'), findsOneWidget);

    await tester.tap(find.text('购物清单'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 篇'), findsOneWidget);

    // 取消后回到正常列表（搜索框 + 新建按钮）。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '新建'), findsOneWidget);
  });

  testWidgets('多选里点删除先弹确认框，取消不动任何文件（1.45）', (tester) async {
    final store = _FakeStore([_note('白板复盘')]);
    await tester.pumpWidget(_wrap(store));
    await tester.pump();

    await tester.longPress(find.text('白板复盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除选中的 1 篇笔记？'), findsOneWidget);
    expect(find.textContaining('.trash'), findsOneWidget);

    // 顶栏也有一「取消」（退出多选），这里只点对话框里的那个。
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('取消'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 篇'), findsOneWidget);
    expect(find.text('白板复盘'), findsOneWidget);
  });

  // --------------------------------------------- 1.48：视图条与时间视图

  testWidgets('视图条有「全部」「新建组」和四种时间视图（1.48）', (tester) async {
    await tester.pumpWidget(_wrap(_FakeStore([_note('白板复盘')])));
    await tester.pump();

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('新建组'), findsOneWidget);
    expect(find.text('创建 ↑'), findsOneWidget);
    expect(find.text('创建 ↓'), findsOneWidget);
    expect(find.text('修改 ↑'), findsOneWidget);
    expect(find.text('修改 ↓'), findsOneWidget);
  });

  testWidgets('时间视图平铺：不画月份标题，按创建时间正序（1.48）', (tester) async {
    final older = _note('旧笔记', created: DateTime(2026, 10, 2, 9));
    final newer = _note('新笔记', created: DateTime(2026, 11, 20, 9));
    await tester.pumpWidget(_wrap(_FakeStore([newer, older])));
    await tester.pump();

    expect(find.text('2026 年 11 月'), findsOneWidget);

    await tester.tap(find.text('创建 ↑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 平铺：两个月份标题都不该出现。
    expect(find.text('2026 年 11 月'), findsNothing);
    expect(find.text('2026 年 10 月'), findsNothing);
    expect(tester.getTopLeft(find.text('旧笔记')).dy,
        lessThan(tester.getTopLeft(find.text('新笔记')).dy));
  });

  testWidgets('组视图只显示这个组里的笔记（1.48）', (tester) async {
    final inside = _note('组里的');
    final outside = _note('组外的');
    final store = _FakeStore(
      [inside, outside],
      groups: NoteGroups({
        '工作': [inside.relPath],
      }),
    );
    await tester.pumpWidget(_wrap(store));
    await tester.pump();

    await tester.tap(find.text('工作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('组里的'), findsOneWidget);
    expect(find.text('组外的'), findsNothing);
  });
}
