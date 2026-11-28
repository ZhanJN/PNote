library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/ui/notes/block_editor.dart';

void main() {
  String last = '';

  Widget wrap(String text, {Future<String?> Function()? pickImage}) {
    return MaterialApp(
      home: Scaffold(
        body: BlockEditor(
          key: ValueKey(text),
          initialText: text,
          onChanged: (value) => last = value,
          assetPath: (_) => null,
          onPickImage: pickImage ?? () async => null,
          onPickLink: () async => null,
          autofocus: false,
        ),
      ),
    );
  }

  testWidgets('标题与正文按块渲染，改正文会回传完整 Markdown', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('# 标题\n\n正文'));
    await tester.pump();

    expect(find.text('标题'), findsWidgets);
    expect(find.text('正文'), findsWidgets);

    await tester.enterText(find.byType(TextField).at(2), '正文改了');
    await tester.pump();
    expect(last, '# 标题\n\n正文改了');
  });

  testWidgets('工具条「待办」把当前块变成 - [ ]', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('一件事'));
    await tester.pump();

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('待办'));
    await tester.pump();

    expect(last, '- [ ] 一件事');
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('插入图片块显示素材名，编码成 ![[名字]]', (tester) async {
    last = '';
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap('看图', pickImage: () async => '照片.png'));
    await tester.pump();

    await tester.tap(find.byTooltip('插入图片'));
    await tester.pump();
    await tester.pump();

    expect(last, contains('![[照片.png]]'));
    expect(find.textContaining('找不到素材：照片.png'), findsOneWidget);
  });

  testWidgets('回车把当前块拆成两个块', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('上'));
    await tester.pump();

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    // 模拟软键盘回车：在光标处插入一个换行。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '上\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    expect(find.byType(TextField), findsNWidgets(2));
    expect(last.startsWith('上'), isTrue);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '下',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(last, contains('下'));
  });

  testWidgets('分割线块可以删除', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('上\n\n---\n\n下'));
    await tester.pump();

    expect(find.byType(Divider), findsWidgets);
    await tester.tap(find.byTooltip('删除分割线'));
    await tester.pump();
    expect(last, isNot(contains('---')));
    expect(last, contains('下'));
  });

  testWidgets('块首退格把两段并成一段', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('上\n下'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(2));

    final second = find.byType(TextField).at(1);
    await tester.tap(second);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '下', selection: TextSelection.collapsed(offset: 0)),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(last, '上下');
  });

  testWidgets('块尾 Delete 把下一段接上来', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('上\n下\n后'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(3));

    final middle = find.byType(TextField).at(1);
    await tester.tap(middle);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '下', selection: TextSelection.collapsed(offset: 1)),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(find.byType(TextField), findsNWidgets(2));
    expect(last.contains('下后'), isTrue);
  });

  testWidgets('再点一次加粗会取消，不会叠第二层标记', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('重点'));
    await tester.pump();

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '重点',
        selection: TextSelection(baseOffset: 0, extentOffset: 2),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(last, '**重点**');

    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(last, '重点');
  });

  testWidgets('再点一次 H1 回到正文', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('# 标题'));
    await tester.pump();

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('大标题'));
    await tester.pump();
    expect(last, '标题');
  });

  testWidgets('新建空块时不显示「输入正文」占位符', (tester) async {
    await tester.pumpWidget(wrap(''));
    await tester.pump();
    expect(find.text('输入正文…'), findsNothing);
  });

  testWidgets('编辑态隐藏 ** 标记，但正文仍是粗体', (tester) async {
    await tester.pumpWidget(wrap('**重点**'));
    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    final span = editable.controller.buildTextSpan(
      context: tester.element(find.byType(EditableText).first),
      style: const TextStyle(fontSize: 15),
      withComposing: false,
    );
    final marker = _findText(span, '**');
    expect(marker, isNotNull);
    expect(marker!.style?.fontSize, lessThan(1));
    final body = _findText(span, '重点');
    expect(body, isNotNull);
    expect(body!.style?.fontWeight, FontWeight.bold);
  });

  testWidgets('没有选区时格式作用于整块，空块不动', (tester) async {
    last = '';
    await tester.pumpWidget(wrap(''));
    await tester.pump();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(last, '');

    await tester.pumpWidget(wrap('文字'));
    await tester.pump();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(last, '**文字**');
  });

  testWidgets('整块跨行框选后可以剪切', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('甲\n乙\n丙'));
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(3));

    final first = tester.getCenter(find.byType(TextField).at(0));
    final gesture = await tester.startGesture(first);
    // 1.60：先长按 450 ms 进入整块选择，再点第三块把选区扩过去。
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump();
    // 选择条出现后布局会下移，重新取第三块的位置。
    final thirdNow = tester.getCenter(find.byType(TextField).at(2));
    await tester.tapAt(thirdNow);
    await tester.pump();

    expect(find.textContaining('已选 3 段'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '剪切'));
    await tester.pump();

    expect(last, isNot(contains('甲')));
    expect(last, isNot(contains('乙')));
  });

  testWidgets('1.60 清空一行不会自动吞并上一块', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('甲\n乙\n丙'));
    await tester.pump();

    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pump();

    expect(find.byType(TextField), findsNWidgets(3));
    expect(last, '甲\n\n丙');
  });

  testWidgets('1.60 有序列表显示 1./2./3.', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('1. 甲\n2. 乙\n3. 丙'));
    await tester.pump();

    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('3.'), findsOneWidget);
  });

  testWidgets('1.60 段首退格先删分割线而不是吞字', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('甲\n---\n乙'));
    await tester.pump();

    final second = find.byType(TextField).at(1);
    await tester.tap(second);
    await tester.pump();
    final controller = tester.widget<TextField>(second).controller!;
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(last, '甲\n乙');
    expect(last, isNot(contains('---')));
  });

  testWidgets('1.61 高亮按钮给整块包上 == ==', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('重点'));
    await tester.pump();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();
    expect(last, '==重点==');
  });

  testWidgets('1.61 居右按钮设置整块对齐并写回 ::: right', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('靠右'));
    await tester.pump();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('居右'));
    await tester.pump();
    expect(last, contains('::: right'));
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.textAlign, TextAlign.right);
  });

  testWidgets('1.61 长按拖到列表底边会自动滚动', (tester) async {
    last = '';
    final many = List.generate(30, (i) => '第 $i 段').join('\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 260,
          child: BlockEditor(
            initialText: many,
            assetPath: (_) => null,
            onPickImage: () async => null,
            onPickLink: () async => null,
            onChanged: (v) => last = v,
          ),
        ),
      ),
    ));
    await tester.pump();

    final list = tester.widget<ListView>(find.byType(ListView));
    final controller = list.controller!;
    final start = tester.getCenter(find.byType(TextField).first);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 500));

    final box = tester.getRect(find.byType(ListView));
    await gesture.moveTo(Offset(box.center.dx, box.bottom - 10));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump();

    expect(controller.offset, greaterThan(0));
  });

  testWidgets('1.62 指针停在底边不动，也继续自动滚动并扩展选择', (tester) async {
    last = '';
    final many = List.generate(40, (i) => '第 $i 段').join('\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 260,
          child: BlockEditor(
            initialText: many,
            assetPath: (_) => null,
            onPickImage: () async => null,
            onPickLink: () async => null,
            onChanged: (v) => last = v,
          ),
        ),
      ),
    ));
    await tester.pump();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TextField).first));
    await tester.pump(const Duration(milliseconds: 500));
    final box = tester.getRect(find.byType(ListView));
    await gesture.moveTo(Offset(box.center.dx, box.bottom - 6));
    await tester.pump(const Duration(milliseconds: 120));
    final first = controller.offset;
    // 指针完全不动，只让时间流逝。
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.offset, greaterThan(first));
    expect(find.textContaining('已选'), findsOneWidget);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('1.62 选择中收到 PointerCancel 不退出选择', (tester) async {
    last = '';
    final many = List.generate(20, (i) => '第 $i 段').join('\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: BlockEditor(
            initialText: many,
            assetPath: (_) => null,
            onPickImage: () async => null,
            onPickLink: () async => null,
            onChanged: (v) => last = v,
          ),
        ),
      ),
    ));
    await tester.pump();
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TextField).first));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.cancel();
    await tester.pump();
    expect(find.textContaining('已选'), findsOneWidget);
  });

  testWidgets('1.62 选择条按钮可向下滚一屏', (tester) async {
    last = '';
    final many = List.generate(40, (i) => '第 $i 段').join('\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 260,
          child: BlockEditor(
            initialText: many,
            assetPath: (_) => null,
            onPickImage: () async => null,
            onPickLink: () async => null,
            onChanged: (v) => last = v,
          ),
        ),
      ),
    ));
    await tester.pump();
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TextField).first));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump();
    await tester.tap(find.byTooltip('向下滚一屏'));
    await tester.pump();
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('1.62 Esc 退出选择、Shift 点击扩展、删除按钮移除选中块', (tester) async {
    last = '';
    const text = '一\n二\n三\n四';
    await tester.pumpWidget(wrap(text));
    await tester.pump();

    Future<void> enterSelect() async {
      final gesture = await tester
          .startGesture(tester.getCenter(find.byType(TextField).first));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pump();
    }

    await enterSelect();
    expect(find.textContaining('已选'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.textContaining('已选'), findsNothing);

    await enterSelect();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(tester.getCenter(find.byType(TextField).at(2)));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text('已选 3 段'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(last, '四');
  });

  testWidgets('1.62 Ctrl+C 复制选中块到剪贴板', (tester) async {
    last = '';
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(wrap('甲\n乙\n丙'));
    await tester.pump();
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TextField).first));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(tester.getCenter(find.byType(TextField).at(1)));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(clip, isNotNull);
    expect(clip, contains('甲'));
    expect(clip, contains('乙'));
  });
  testWidgets('1.63.2 已有颜色换成另一种颜色 = 覆盖，不叠层', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('=={r}重点=='));
    await tester.pump();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();
    expect(last, '==重点==');
  });

  testWidgets('1.63.2 同一种颜色再点一次 = 取消高亮', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('==重点=='));
    await tester.pump();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();
    expect(last, '重点');
  });

  testWidgets('1.63.1 点复制后选区仍保留', (tester) async {
    last = '';
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(wrap('甲\n乙\n丙'));
    await tester.pump();
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TextField).first));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(tester.getCenter(find.byType(TextField).at(2)));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text('已选 3 段'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(clip, contains('甲'));
    expect(find.text('已选 3 段'), findsOneWidget);
  });

  testWidgets('1.63 粘贴带空行的多行文本会拆成多个块且空行保留', (tester) async {
    last = '';
    await tester.pumpWidget(wrap(''));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '一\n\n二');
    await tester.pump();

    expect(last, '一\n\n二');
    expect(find.byType(TextField), findsNWidgets(3));
  });

  testWidgets('1.63 空行不打断有序列表编号', (tester) async {
    await tester.pumpWidget(wrap('1. 一\n\n2. 二'));
    await tester.pump();

    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
  });

  testWidgets('1.63 双击选中的词点高亮只包住这个词', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('重点内容'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    field.controller!.selection =
        const TextSelection(baseOffset: 0, extentOffset: 1);
    await tester.pump();

    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();

    expect(last, '==重==点内容');
  });
  testWidgets('1.63.2 混合颜色整块点高亮 = 全部变黄，再点 = 取消', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('=={r}甲====乙==丙'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    field.controller!.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();
    expect(last, '==甲乙丙==');

    field.controller!.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();
    expect(last, '甲乙丙');
  });

  testWidgets('1.63.2 只给选中的未上色部分上色，其它颜色保持', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('=={r}甲==乙=={g}丙=='));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    field.controller!.selection =
        const TextSelection(baseOffset: 8, extentOffset: 9);
    await tester.pump();

    await tester.tap(find.byTooltip('高亮'));
    await tester.pump();

    expect(last, '=={r}甲====乙===={g}丙==');
  });

  testWidgets('1.63.2 加粗后光标停在原位置，不跳到块尾', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('甲乙丙'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    field.controller!.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();

    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();

    expect(last, '**甲乙丙**');
    expect(field.controller!.selection.baseOffset, 3);
  });

  testWidgets('1.63.3 删除当前行删的是光标所在行，不是下一行', (tester) async {
    last = '';
    await tester.pumpWidget(wrap('一\n二\n三'));
    await tester.pump();

    await tester.tap(find.byType(TextField).at(1));
    await tester.pump();
    await tester.tap(find.byTooltip('删除当前行'));
    await tester.pump();

    // 先清空第二段，第三段必须还在
    expect(last, '一\n\n三');

    // 再点一次：空段并入上一段
    await tester.tap(find.byTooltip('删除当前行'));
    await tester.pump();
    expect(last, '一\n三');
  });
}

TextSpan? _findText(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text) return span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      final found = _findText(child, text);
      if (found != null) return found;
    }
  }
  return null;
}
