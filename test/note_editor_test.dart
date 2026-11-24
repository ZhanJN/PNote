/// 编辑器（1.43）：字数统计、反向链接面板。
///
/// 用内存里的假 store，不碰真实磁盘——真实文件 IO 在 widget 测试的假时钟里
/// 永远不会完成（老坑 7.40 / 7.45）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pnote/notes/notes_model.dart';
import 'package:pnote/notes/notes_store.dart';
import 'package:pnote/ui/notes/note_editor_page.dart';

class _MemStore extends NotesStore {
  _MemStore(this.texts);

  final Map<String, String> texts;

  NoteFile _file(String relPath) => NoteFile(
        relPath: relPath,
        title: titleFromFileName(p.basename(relPath)),
        createdAt: DateTime(2026, 11, 23, 20, 41),
        modified: DateTime(2026, 11, 23, 20, 41),
        size: texts[relPath]!.length,
      );

  @override
  Future<List<NoteFile>> list() async => texts.keys.map(_file).toList();

  @override
  Future<String> read(String relPath) async => texts[relPath]!;

  @override
  Future<void> write(String relPath, String content) async {
    texts[relPath] = content;
  }

  @override
  Future<Map<String, File>> assetsOf(String noteId) async =>
      const <String, File>{};

  @override
  Future<NoteFile> create(String title) async {
    final relPath = '2026/11/2026-11-23 2200 $title.md';
    texts[relPath] = '# $title\n\n';
    return _file(relPath);
  }
}

const String _selfPath = '2026/11/2026-11-23 2041 白板复盘.md';
const String _planPath = '2026/11/2026-11-23 2105 今天的计划.md';

Widget _editor(_MemStore store) {
  final self = store.texts[_selfPath] ?? '';
  return MaterialApp(
    home: NoteEditorPage(
      note: NoteFile(
        relPath: _selfPath,
        title: '白板复盘',
        createdAt: DateTime(2026, 11, 23, 20, 41),
        modified: DateTime(2026, 11, 23, 20, 41),
        size: self.length,
      ),
      store: store,
      hasNote: (stem) => stem == '白板复盘' || stem == '今天的计划',
      openNote: (_) {},
    ),
  );
}

void main() {
  testWidgets('状态条显示字数，并且随输入更新（1.43）', (tester) async {
    final store = _MemStore({
      _selfPath: '# 白板复盘\n\n三件事',
      _planPath: '# 今天的计划\n\n[[白板复盘]]',
    });
    await tester.runAsync(() async {});
    await tester.pumpWidget(_editor(store));
    await tester.pump();
    await tester.pump();

    expect(find.text('8 字'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '# 白板复盘\n\n三件事都做完了');
    await tester.pump();
    expect(find.text('12 字'), findsOneWidget);
  });

  testWidgets('反向链接面板列出引用了这篇的笔记（1.43）', (tester) async {
    final store = _MemStore({
      _selfPath: '# 白板复盘\n\n内容',
      _planPath: '# 今天的计划\n\n先看 [[白板复盘]]',
    });
    await tester.pumpWidget(_editor(store));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('反向链接（谁引用了这篇）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('被 1 篇笔记引用'), findsOneWidget);
    expect(find.text('今天的计划'), findsOneWidget);
    expect(find.text('引用 1 次'), findsOneWidget);
  });

  testWidgets('大纲列出标题，点一条把光标挪到那个标题（1.44）', (tester) async {
    const text = '# 白板复盘\n\n开头\n\n## 本周问题\n\n- 收集太随意\n\n## 下一步\n\n看计划';
    final store = _MemStore({_selfPath: text});
    await tester.pumpWidget(_editor(store));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('大纲（跳到标题）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('大纲（3 个标题）'), findsOneWidget);
    expect(find.text('本周问题'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.selection.baseOffset, text.indexOf('## 下一步'));
  });

  testWidgets('带锚点进来直接定位到对应标题（1.44）', (tester) async {
    const text = '# 白板复盘\n\n开头\n\n## 下一步\n\n看计划';
    final store = _MemStore({_selfPath: text});
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(
        note: NoteFile(
          relPath: _selfPath,
          title: '白板复盘',
          createdAt: DateTime(2026, 11, 23, 20, 41),
          modified: DateTime(2026, 11, 23, 20, 41),
          size: text.length,
        ),
        store: store,
        hasNote: (stem) => stem == '白板复盘',
        openNote: (_) {},
        initialAnchor: '下一步',
      ),
    ));
    await tester.pump();
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.selection.baseOffset, text.indexOf('## 下一步'));
  });

  testWidgets('锚点找不到时给出提示（1.44）', (tester) async {
    const text = '# 白板复盘\n\n只有这一节';
    final store = _MemStore({_selfPath: text});
    await tester.pumpWidget(MaterialApp(
      home: NoteEditorPage(
        note: NoteFile(
          relPath: _selfPath,
          title: '白板复盘',
          createdAt: DateTime(2026, 11, 23, 20, 41),
          modified: DateTime(2026, 11, 23, 20, 41),
          size: text.length,
        ),
        store: store,
        hasNote: (stem) => stem == '白板复盘',
        openNote: (_) {},
        initialAnchor: '不存在的小节',
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('没有「不存在的小节」这个标题'), findsOneWidget);
  });
}
