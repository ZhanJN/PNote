import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:markdown/markdown.dart' as md;

/// 1.65 代码块（第③项）：appflowy_editor 6.2.0 的 Markdown 解码器没有 fenced
/// code block 解析器（`pre` 节点会被直接丢掉），这里补一个，产出一个真正的
/// 代码块节点。
///
/// 节点类型用上游编码器认识的名字 `code`（见
/// `third_party/appflowy_editor/lib/src/plugins/markdown/encoder/parser/code_block_node_parser.dart`），
/// 属性：
/// - `delta`：代码正文（上游 `blockComponentDelta`）；
/// - `language`：围栏上写的语言，没有就是空串。
///
/// 文字里不做任何改写，磁盘格式仍是原来的三行围栏，所以不需要迁移数据。
class PnoteCodeBlockKeys {
  PnoteCodeBlockKeys._();

  static const String type = 'code';
  static const String delta = blockComponentDelta;
  static const String language = 'language';
}

/// 新建一个代码块节点；[code] 里的换行原样保留。
Node pnoteCodeNode({String language = '', String code = ''}) {
  final delta = Delta();
  if (code.isNotEmpty) {
    delta.insert(code);
  }
  return Node(
    type: PnoteCodeBlockKeys.type,
    attributes: {
      PnoteCodeBlockKeys.delta: delta.toJson(),
      if (language.isNotEmpty) PnoteCodeBlockKeys.language: language,
    },
  );
}

/// 代码块的语言（没有时返回空串）。
String pnoteCodeLanguage(Node node) {
  final value = node.attributes[PnoteCodeBlockKeys.language];
  return value is String ? value.trim() : '';
}

/// 代码块的正文（不会返回 null）。
String pnoteCodeText(Node node) => node.delta?.toPlainText() ?? '';

/// 把 Markdown 的 ```` ```lang ```` 围栏解析成一个代码块节点。
class PeCodeBlockParser extends CustomMarkdownParser {
  const PeCodeBlockParser();

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
    return [pnoteCodeNode(language: language, code: body)];
  }
}

/// 判断一行是不是代码围栏（```` ``` ```` 开头）。
bool isCodeFenceLine(String line) => line.trimLeft().startsWith('```');
