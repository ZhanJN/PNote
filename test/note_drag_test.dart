/// 笔记列表的手势层测试（1.46）：长按拖拽换顺序、长按原地抬手弹菜单。
///
/// 只测 [NoteListBody]，不碰真实文件与数据库，所以可以放心用假时钟。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/ui/notes/note_list_body.dart';

NoteFile _note(String title, int day) {
  final time = DateTime(2026, 11, day, 9, 0);
  return NoteFile(
    relPath: '2026/11/2026-11-${day.toString().padLeft(2, '0')} 0900 $title.md',
    title: title,
    createdAt: time,
    modified: time,
    size: 128,
  );
}

void main() {
  late List<NoteFile> notes;

  setUp(() {
    notes = [_note('甲', 21), _note('乙', 22), _note('丙', 23)];
  });

  Widget wrap({
    required void Function(String groupKey, List<String> ids) onReorder,
    void Function(NoteFile note, Offset? at)? onMenu,
    void Function(NoteFile note)? onOpen,
    bool selecting = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: NoteListBody(
          groups: [
            NoteGroup(key: '2026-11', title: '2026 年 11 月', notes: notes),
          ],
          now: DateTime(2026, 11, 24, 10, 0),
          onOpen: onOpen ?? (_) {},
          onMenu: (note, _, at) => onMenu?.call(note, at),
          onReorder: onReorder,
          selecting: selecting,
        ),
      ),
    );
  }

  testWidgets('长按后拖到最后一行下面，组内顺序跟着换', (tester) async {
    List<String>? captured;
    String? capturedKey;
    await tester.pumpWidget(wrap(
      onReorder: (key, ids) {
        capturedKey = key;
        captured = ids;
      },
    ));
    await tester.pump();

    final gesture = await tester.startGesture(tester.getCenter(find.text('甲')));
    // 320 ms 静默期 + 一些余量：走 ticker，时间靠 pump 推进。
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 260));
    // 往下拖过乙和丙的中心点。
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(capturedKey, '2026-11');
    expect(captured, [
      notes[1].relPath,
      notes[2].relPath,
      notes[0].relPath,
    ]);
  });

  testWidgets('长按原地抬手：弹菜单，不改顺序', (tester) async {
    var reordered = false;
    NoteFile? menuNote;
    Offset? menuAt;
    await tester.pumpWidget(wrap(
      onReorder: (_, _) => reordered = true,
      onMenu: (note, at) {
        menuNote = note;
        menuAt = at;
      },
    ));
    await tester.pump();

    final gesture = await tester.startGesture(tester.getCenter(find.text('乙')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 260));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(reordered, isFalse);
    expect(menuNote?.relPath, notes[1].relPath);
    expect(menuAt, isNotNull);
  });

  testWidgets('轻点一行仍然是打开，不会误判成长按', (tester) async {
    NoteFile? opened;
    var menuCalls = 0;
    await tester.pumpWidget(wrap(
      onReorder: (_, _) {},
      onOpen: (note) => opened = note,
      onMenu: (_, _) => menuCalls++,
    ));
    await tester.pump();

    await tester.tap(find.text('丙'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(opened?.relPath, notes[2].relPath);
    expect(menuCalls, 0);
  });
}
