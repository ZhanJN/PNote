/// 1.59：列表标题/预览的读盘与缓存。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/notes/notes_paths.dart';
import 'package:pnote/notes/notes_store.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pnote_preview_');
    setNotesRootOverride(dir);
  });

  tearDown(() {
    setNotesRootOverride(null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('标题取 # 行，预览取标题后第一段正文', () async {
    File('${dir.path}/2026/11/2026.11.26 1000 日记.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('# 我的标题\n\n第一段**正文**，还有 [[引用]]。\n\n第二段');

    final notes = await const NotesStore().list(withPreview: true);
    expect(notes, hasLength(1));
    expect(notes.single.title, '我的标题');
    expect(notes.single.preview, '第一段正文，还有 引用。');
  });

  test('没有 # 标题时，第一条 ### 小标题去掉井号当预览', () async {
    File('${dir.path}/2026/11/2026.11.26 1000 化学.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('### 化学复习脉络\n\n物质的量 → 离子反应');

    final notes = await const NotesStore().list(withPreview: true);
    expect(notes.single.title, '2026.11.26 1000 化学');
    expect(notes.single.preview, '化学复习脉络');
  });

  test('对齐块标记行不占摘要，取下一行正文', () async {
    File('${dir.path}/2026/11/2026.11.26 1000 对齐.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('# 标题\n\n::: center\n居中的一句话\n:::');

    final notes = await const NotesStore().list(withPreview: true);
    expect(notes.single.preview, '居中的一句话');
  });

  test('关闭预览时不读正文；文件没变时走缓存', () async {
    final file = File('${dir.path}/2026/11/2026.11.26 1000 x.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('# A\n\nB');
    const store = NotesStore();

    final plain = await store.list();
    expect(plain.single.preview, '');

    final withPreview = await store.list(withPreview: true);
    expect(withPreview.single.preview, 'B');

    // 文件改了，缓存必须失效。
    file.writeAsStringSync('# A\n\nC');
    file.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
    final again = await store.list(withPreview: true);
    expect(again.single.preview, 'C');
  });
}
