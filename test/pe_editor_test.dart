import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pnote/ui/notes/pe_editor.dart';

/// 1×1 透明 PNG，够 Image.file 解码用。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

/// 造一张真 PNG（纯色）：悬停菜单要图片真的占位，1×1 会让整个块是 0×0，
/// 菜单按钮就被 Stack 裁掉、点不到。必须在 runAsync 里调用。
Future<Uint8List> _makePng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF508CDC),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// 图片块菜单按钮：Tooltip 包着 IconButton，Tooltip 自己的渲染盒是布局代理，
/// 直接 tap find.byTooltip 会点到旁边的空白，必须落到里面的 IconButton。
Finder _menuButton(String tooltip) => find.ancestor(
  of: find.byTooltip(tooltip),
  matching: find.byType(IconButton),
);

/// 把图片真正解码进 ImageCache：FakeAsync 里 Image.file 永远不会完成加载，
/// 块会停在 0×0，悬停菜单也就没地方可点。要在 runAsync 里调用。
Future<void> _preload(File file) {
  final provider = FileImage(file);
  final stream = provider.resolve(ImageConfiguration.empty);
  final completer = Completer<void>();
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, sync) {
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.complete();
      }
    },
    onError: (error, stack) {
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    },
  );
  stream.addListener(listener);
  return completer.future;
}

void main() {
  Widget wrap(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? ThemeData.dark(),
      home: Scaffold(body: SizedBox(height: 600, child: child)),
    );
  }

  testWidgets('PEditor 能挂载并显示初始文本（1.64）', (tester) async {
    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '# 标题\n\n正文一段',
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PEditor), findsOneWidget);
    expect(find.textContaining('标题', findRichText: true), findsWidgets);
  });

  testWidgets('1.64.1 深色主题下编辑文字用 onSurface（不是写死白色）', (tester) async {
    await tester.pumpWidget(
      wrap(
        PEditor(initialText: '正文', onChanged: (_) {}),
        theme: ThemeData.dark(),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    final config = editor.editorStyle.textStyleConfiguration;
    expect(config.text.color, ThemeData.dark().colorScheme.onSurface);
    expect(config.bold.color, ThemeData.dark().colorScheme.onSurface);
  });

  testWidgets('1.64.2 浅色主题下编辑文字是深色 onSurface', (tester) async {
    await tester.pumpWidget(
      wrap(
        PEditor(initialText: '正文', onChanged: (_) {}),
        theme: ThemeData.light(),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    final config = editor.editorStyle.textStyleConfiguration;
    final light = ThemeData.light().colorScheme;
    expect(config.text.color, light.onSurface);
    expect(config.text.color, isNot(Colors.white));
    expect(config.code.backgroundColor!.a, greaterThan(0));
  });

  testWidgets('1.64.1 手机宽度下出现 MobileToolbar', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      wrap(PEditor(initialText: '正文', onChanged: (_) {})),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MobileToolbar), findsOneWidget);
  });

  testWidgets('1.65 手机工具条的插图按钮会选素材并插入图片', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pe_img_toolbar');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File('${dir.path}/新图.png')..writeAsBytesSync(_tinyPng);

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var picked = 0;
    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '正文',
          onChanged: (_) {},
          onPickImage: () async {
            picked++;
            return '新图.png';
          },
          assetPath: (name) => name == '新图.png' ? file.path : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // MobileToolbar 只有存在选区时才显示按钮，先点一下正文让光标落进去。
    await tester.tap(find.byType(AppFlowyRichText).first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MobileToolbar), findsOneWidget);

    // 插图按钮排在最后一个，工具条横向滚动，先把它滚出来。
    final toolbarList = find.descendant(
      of: find.byType(MobileToolbar),
      matching: find.byType(ListView),
    );
    await tester.drag(toolbarList.last, const Offset(-320, 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.image_outlined));
    await tester.pump(const Duration(milliseconds: 200));

    expect(picked, 1);
    final state = tester.state<PEditorState>(find.byType(PEditor));
    expect(
      state.editorState.document.root.children.any(
        (node) => node.type == 'image',
      ),
      isTrue,
    );
  });

  testWidgets('1.64.1 图片节点后自动补一个空段落', (tester) async {
    await tester.pumpWidget(
      wrap(PEditor(initialText: '正文', onChanged: (_) {})),
    );
    await tester.pumpAndSettle();
    final state = tester.state<PEditorState>(find.byType(PEditor));
    final editorState = state.editorState;
    final transaction = editorState.transaction
      ..insertNode(
        [editorState.document.root.children.length],
        imageNode(url: 'https://example.com/x.png'),
      );
    await editorState.apply(transaction);
    await tester.pump(const Duration(milliseconds: 300));
    expect(editorState.document.root.children.last.type, 'paragraph');
  });

  testWidgets('1.65 打开笔记时 ![[素材名]] 变成可显示的图片节点', (tester) async {
    // widget 测试跑在 FakeAsync 里，异步文件 IO 永远等不到，必须用同步 IO。
    final dir = Directory.systemTemp.createTempSync('pe_img_open');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File('${dir.path}/照片.png')..writeAsBytesSync(_tinyPng);

    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '上面\n\n![[照片.png]]\n\n下面',
          onChanged: (_) {},
          assetPath: (name) => name == '照片.png' ? file.path : null,
        ),
      ),
    );
    // 图片块会触发真实的 FileImage 解码，pumpAndSettle 在这里等不到静止，
    // 只推固定帧数（项目坑：widget 测试不要 pumpAndSettle）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final state = tester.state<PEditorState>(find.byType(PEditor));
    final image = state.editorState.document.root.children.firstWhere(
      (node) => node.type == 'image',
    );
    expect(image.attributes['url'], file.path);
  });

  testWidgets('1.65 工具栏插入图片：出现图片节点并写回 ![[素材名]]', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pe_img_insert');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File('${dir.path}/新图.png')..writeAsBytesSync(_tinyPng);

    final controller = PeEditorController();
    var markdown = '';
    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '正文',
          onChanged: (text) => markdown = text,
          controller: controller,
          assetPath: (name) => name == '新图.png' ? file.path : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await controller.insertImage('新图.png');
    await tester.pump(const Duration(milliseconds: 200));

    final state = tester.state<PEditorState>(find.byType(PEditor));
    expect(
      state.editorState.document.root.children.any((node) => node.type == 'image'),
      isTrue,
    );
    expect(markdown, contains('![[新图.png]]'));
  });

  testWidgets('1.65 悬停图片可替换 / 删除，且写回 Markdown', (tester) async {    final dir = Directory.systemTemp.createTempSync('pe_img_hover');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    late Uint8List png;
    await tester.runAsync(() async {
      png = await _makePng(200, 120);
    });
    final a = File('${dir.path}/a.png')..writeAsBytesSync(png);
    final b = File('${dir.path}/b.png')..writeAsBytesSync(png);
    // 真实文件 IO 与图片解码都要放在 runAsync 里，否则 FakeAsync 等不到。
    await tester.runAsync(() async {
      await _preload(a);
      await _preload(b);
    });

    final controller = PeEditorController();
    var markdown = '';
    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '![[a.png]]',
          onChanged: (text) => markdown = text,
          controller: controller,
          onPickImage: () async => 'b.png',
          assetPath: (name) => switch (name) {
            'a.png' => a.path,
            'b.png' => b.path,
            _ => null,
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // 悬停图片块：appflowy 只在 MouseRegion.onEnter 时显示菜单。
    await mouse.moveTo(tester.getCenter(find.byType(Image).first));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('替换图片'), findsOneWidget);
    expect(find.byTooltip('删除图片'), findsOneWidget);

    await tester.tap(_menuButton('替换图片'));
    // 写回 Markdown 有 120 ms 防抖，等过它。
    await tester.pump(const Duration(milliseconds: 250));
    final state = tester.state<PEditorState>(find.byType(PEditor));
    final image = state.editorState.document.root.children.firstWhere(
      (node) => node.type == 'image',
    );
    expect(image.attributes['url'], b.path);
    expect(markdown, contains('![[b.png]]'));

    await mouse.moveTo(tester.getCenter(find.byType(Image).first));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(_menuButton('删除图片'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      state.editorState.document.root.children.any(
        (node) => node.type == 'image',
      ),
      isFalse,
    );
  });

  testWidgets('1.65 Ctrl+V 把剪贴板里的图片插进来，写回 ![[名]]', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pe_paste');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    late Uint8List png;
    await tester.runAsync(() async {
      png = await _makePng(120, 80);
    });
    final target = File('${dir.path}/粘贴图片.png')..writeAsBytesSync(png);
    await tester.runAsync(() async {
      await _preload(target);
    });

    var markdown = '';
    var saved = 0;
    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '第一段',
          onChanged: (text) => markdown = text,
          onPasteImage: () async => png,
          onImportImageBytes: (bytes, fileName) async {
            saved++;
            expect(bytes, isNotEmpty);
            return '粘贴图片.png';
          },
          assetPath: (name) => name == '粘贴图片.png' ? target.path : null,
        ),
      ),
    );
    await tester.pump();
    // 快捷键要落在编辑器里的焦点上才会被编辑器自己的命令处理收到。
    await tester.tap(find.byType(AppFlowyRichText).first);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(saved, 1);
    final state = tester.state<PEditorState>(find.byType(PEditor));
    expect(
      state.editorState.document.root.children.any(
        (node) => node.type == 'image',
      ),
      isTrue,
    );
    expect(markdown, contains('![[粘贴图片.png]]'));
  });

  testWidgets('1.65 剪贴板里没有图片时 Ctrl+V 不插图、不崩', (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      wrap(
        PEditor(
          initialText: '第一段',
          onChanged: (_) {},
          onPasteImage: () async {
            reads++;
            return null;
          },
          onImportImageBytes: (bytes, fileName) async => '不该走到这里.png',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(AppFlowyRichText).first);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(reads, 1);
    final state = tester.state<PEditorState>(find.byType(PEditor));
    expect(
      state.editorState.document.root.children.any(
        (node) => node.type == 'image',
      ),
      isFalse,
    );
  });
}
