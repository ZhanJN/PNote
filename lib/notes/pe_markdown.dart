import 'package:appflowy_editor/appflowy_editor.dart';

import 'pe_code_block.dart';

/// 1.64 PEditor 地基：Markdown 与 appflowy_editor 文档之间的转换。
///
/// 转换器主体由 appflowy_editor 提供；这里补两样上游缺的东西：
/// 1. fenced code block 解码（上游 `pre` 节点会被丢掉，见 [PeCodeFenceParser]）；
/// 2. 有序列表编号（上游每项都导出 `1.`，这里按连续列表重新编号）。
/// 另加空文本与解析异常兜底，保证编辑器不会白屏。
Document peDocumentFromMarkdown(String source) {
  if (source.trim().isEmpty) {
    return Document.blank(withInitialText: true);
  }
  try {
    return markdownToDocument(
      source,
      markdownParsers: const [PeCodeFenceParser()],
    );
  } catch (_) {
    return Document(
      root: Node(
        type: 'page',
        children: [paragraphNode(text: source)],
      ),
    );
  }
}

String peMarkdownFromDocument(Document document) {
  String text;
  try {
    text = documentToMarkdown(document).trimRight();
  } catch (_) {
    text = document.root.children
        .map((node) => node.delta?.toPlainText() ?? '')
        .join('\n')
        .trimRight();
  }
  return renumberOrderedLists(text);
}

final RegExp _orderedItem = RegExp(r'^(\s*)1\.\s');

/// 上游导出有序列表时每项都写 `1.`；按缩进层级重新编号为 1、2、3…
String renumberOrderedLists(String markdown) {
  final counters = <int, int>{};
  final out = <String>[];
  for (final line in markdown.split('\n')) {
    final match = _orderedItem.firstMatch(line);
    if (match != null) {
      final indent = match.group(1)!.length;
      counters.removeWhere((depth, _) => depth > indent);
      final number = (counters[indent] ?? 0) + 1;
      counters[indent] = number;
      out.add(
        line.replaceRange(
          match.start,
          match.end,
          '${match.group(1)}$number. ',
        ),
      );
      continue;
    }
    if (line.trim().isEmpty) {
      out.add(line);
      continue;
    }
    counters.clear();
    out.add(line);
  }
  return out.join('\n');
}
