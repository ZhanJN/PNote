import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:markdown/markdown.dart' as md;

/// 1.64 fork 补丁：appflowy_editor 6.2.0 的 Markdown 解码器没有 fenced code
/// block 解析器（`pre` 节点会被直接丢掉），这里补一个。
///
/// 第一版不追求代码高亮/独立卡片：把 ```` ```lang ````、代码行、```` ``` ````
/// 还原成连续的段落节点，保证内容不丢、能直接改；等编辑器组件层做好再换成
/// 真正的代码块组件。导出时 TextNodeParser 会原样写回这些行，围栏自然闭合。
class PeCodeFenceParser extends CustomMarkdownParser {
  const PeCodeFenceParser();

  @override
  List<Node> transform(
    md.Node element,
    List<CustomMarkdownParser> parsers, {
    MarkdownListType listType = MarkdownListType.unknown,
    int? startNumber,
  }) {
    if (element is! md.Element || element.tag != 'pre') {
      return const [];
    }
    md.Element? code;
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        code = child;
        break;
      }
    }
    final body = (code?.textContent ?? element.textContent).trimRight();
    final className = code?.attributes['class'] ?? '';
    final language =
        className.startsWith('language-') ? className.substring(9) : '';

    final lines = <String>['```$language'];
    if (body.isNotEmpty) lines.addAll(body.split('\n'));
    lines.add('```');
    return [for (final line in lines) paragraphNode(text: line)];
  }
}

/// 把一段 Markdown 里的代码围栏行原样保留；供将来真正的代码块组件使用。
bool isCodeFenceLine(String line) => line.trimLeft().startsWith('```');
