import 'package:appflowy_editor/appflowy_editor.dart';

import 'pe_code_block.dart';

/// 1.64 PEditor 地基：Markdown 与 appflowy_editor 文档之间的转换。
///
/// 转换器主体由 appflowy_editor 提供；这里补四样上游缺的东西：
/// 1. fenced code block 解码成代码块节点（上游 `pre` 节点会被丢掉，见
///    [PeCodeBlockParser]）；
/// 2. 有序列表编号（上游每项都导出 `1.`，这里按连续列表重新编号）；
/// 3. 图片：旧内核写法 `![[素材名]]` 与编辑器图片节点互转（1.65）；
/// 4. 笔记引用：`[[名字]]` 与带 `href` 的文字互转（1.65）。
///
/// 图片不做数据迁移，磁盘上永远是 `![[素材名]]`。进编辑器时临时编码成
/// `![](pnote:素材名)` 让上游解析成图片节点，再把节点地址换成素材的绝对路径
/// 交给 `Image.file` 渲染；导出时把绝对路径换回 `![[素材名]]`。
Document peDocumentFromMarkdown(
  String source, {
  String? Function(String name)? resolveImage,
}) {
  if (source.trim().isEmpty) {
    return Document.blank(withInitialText: true);
  }
  Document document;
  try {
    document = markdownToDocument(
      _encodeImageRefs(source),
      markdownParsers: const [PeCodeBlockParser()],
    );
  } catch (_) {
    document = Document(
      root: Node(
        type: 'page',
        children: [paragraphNode(text: source)],
      ),
    );
  }
  if (resolveImage != null) {
    _applyImagePaths(document, resolveImage);
  }
  _applyNoteRefs(document);
  return document;
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
  return renumberOrderedLists(_decodeImageRefs(_decodeNoteRefs(text)));
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

/// 旧内核的图片引用写法：`![[素材名]]`。
///
/// 只认独立成行的那种：行内 `![[名]]` 上游解析不成图片节点，硬转反而会
/// 丢字，所以留成普通文字（旧内核也只把独立成行的当图片）。
final RegExp _imageRefPattern = RegExp(
  r'^[ \t]*!\[\[([^\]\n]*)\]\][ \t\r]*$',
  multiLine: true,
);

/// 编辑器内存里用的临时地址前缀，不会写进 Markdown 文件。
const String kPnoteImageScheme = 'pnote:';

final RegExp _imageMarkdownPattern = RegExp(r'!\[[^\]\n]*\]\(([^()\n]*)\)');
final RegExp _absolutePathPattern = RegExp(r'^(?:[A-Za-z]:[\\/]|/)');
final RegExp _schemePattern = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');

/// 逐行改写，但跳过代码围栏里的内容（围栏里的 `![[…]]`、链接都是代码本身，
/// 不能被当成图片/笔记引用改写）。
String _mapOutsideCodeFences(
  String markdown,
  String Function(String line) transform,
) {
  final out = <String>[];
  var inFence = false;
  for (final line in markdown.split('\n')) {
    if (isCodeFenceLine(line)) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    out.add(inFence ? line : transform(line));
  }
  return out.join('\n');
}

/// 把 `![[素材名]]` 临时改写成上游能解析的 `![](pnote:素材名)`。
String _encodeImageRefs(String markdown) {
  return _mapOutsideCodeFences(markdown, (line) {
    return line.replaceAllMapped(_imageRefPattern, (match) {
      final name = match.group(1)!.trim();
      if (name.isEmpty) {
        return match.group(0)!;
      }
      return '![]($kPnoteImageScheme${Uri.encodeComponent(name)})';
    });
  });
}

/// 把图片节点的临时地址换成素材的绝对路径，供 `Image.file` 渲染。
void _applyImagePaths(
  Document document,
  String? Function(String name) resolveImage,
) {
  void visit(Node node) {
    if (node.type == ImageBlockKeys.type) {
      final raw = node.attributes[ImageBlockKeys.url];
      if (raw is String && raw.startsWith(kPnoteImageScheme)) {
        final encoded = raw.substring(kPnoteImageScheme.length);
        final name = _decodeName(encoded);
        final path = resolveImage(name) ?? resolveImage(encoded);
        node.updateAttributes({
          ImageBlockKeys.url: (path == null || path.isEmpty) ? name : path,
        });
      }
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  visit(document.root);
}

/// 把上游导出的 `![](绝对路径)` 换回 `![[素材名]]`；网络图片保持原样。
String _decodeImageRefs(String markdown) {
  return _mapOutsideCodeFences(markdown, (line) {
    return line.replaceAllMapped(_imageMarkdownPattern, (match) {
      final name = _assetNameOf(match.group(1)!.trim());
      if (name == null || name.isEmpty) {
        return match.group(0)!;
      }
      return '![[$name]]';
    });
  });
}

String? _assetNameOf(String url) {
  if (url.startsWith(kPnoteImageScheme)) {
    return _decodeName(url.substring(kPnoteImageScheme.length));
  }
  if (_absolutePathPattern.hasMatch(url)) {
    return url.split(RegExp(r'[\\/]')).last;
  }
  if (url.contains('/') || url.contains('\\') || _schemePattern.hasMatch(url)) {
    return null;
  }
  return _decodeName(url);
}

String _decodeName(String encoded) {
  try {
    return Uri.decodeComponent(encoded);
  } catch (_) {
    return encoded;
  }
}

/// 旧内核的笔记引用写法：`[[笔记名]]`，可以带 `#锚点`。
///
/// 和图片一样不做数据迁移：磁盘上保持 `[[名字]]` 原样。进编辑器时把这段
/// 文字换成「带 `href` 属性的文字」（appflowy 的链接就是这样存的），这样
/// 点得动；导出时再把链接换回 `[[名字]]`。
const String kPnoteNoteScheme = 'pnote:note:';

final RegExp _noteRefPattern = RegExp(r'\[\[([^\[\]\n]+)\]\]');
final RegExp _noteLinkMarkdownPattern = RegExp(
  r'\[([^\[\]\n]+)\]\(pnote:note:[^)\n]*\)',
);

/// `[[名字]]` → 编辑器里用的链接地址；不是 `[[…]]` 写法时原样拼进去。
String peNoteRefHref(String raw) {
  return '$kPnoteNoteScheme${Uri.encodeComponent(peNoteRefBody(raw))}';
}

/// `[[名字]]` → `名字`（编辑器里显示不带方括号的链接）；别的原样返回。
String peNoteRefBody(String raw) {
  final trimmed = raw.trim();
  if (trimmed.startsWith('[[') &&
      trimmed.endsWith(']]') &&
      trimmed.length > 4) {
    return trimmed.substring(2, trimmed.length - 2);
  }
  return trimmed;
}

/// 链接地址 → `[[名字]]`；不是笔记引用时返回 null。
String? peNoteRefRaw(String href) {
  if (!href.startsWith(kPnoteNoteScheme)) {
    return null;
  }
  final body = _decodeName(href.substring(kPnoteNoteScheme.length));
  if (body.isEmpty) {
    return null;
  }
  return '[[$body]]';
}

/// 把段落里行内的 `[[名字]]` 换成带 `href` 的文字（编辑器里才点得动）。
///
/// 只动文本类块；代码块里的 `[[…]]` 保持原样。
void _applyNoteRefs(Document document) {
  void visit(Node node) {
    final delta = node.delta;
    if (delta != null &&
        node.type != 'text' &&
        node.type != PnoteCodeBlockKeys.type) {
      final updated = _splitNoteRefs(delta);
      if (updated != null) {
        node.updateAttributes({ParagraphBlockKeys.delta: updated.toJson()});
      }
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  visit(document.root);
}

Delta? _splitNoteRefs(Delta delta) {
  if (!delta.toPlainText().contains('[[')) {
    return null;
  }
  final next = Delta();
  var changed = false;
  for (final operation in delta) {
    if (operation is! TextInsert) {
      next.add(operation);
      continue;
    }
    final text = operation.text;
    final attributes = operation.attributes;
    var start = 0;
    for (final match in _noteRefPattern.allMatches(text)) {
      if (match.start > start) {
        next.insert(text.substring(start, match.start), attributes: attributes);
      }
      next.insert(
        match.group(1)!,
        attributes: {
          ...?attributes,
          AppFlowyRichTextKeys.href: peNoteRefHref(match.group(0)!),
        },
      );
      changed = true;
      start = match.end;
    }
    if (start < text.length) {
      next.insert(text.substring(start), attributes: attributes);
    }
  }
  return changed ? next : null;
}

/// 把 `[[名字]](pnote:note:…)` 换回 `[[名字]]`。普通链接不动，代码围栏里不动。
String _decodeNoteRefs(String markdown) {
  return _mapOutsideCodeFences(markdown, (line) {
    return line.replaceAllMapped(
      _noteLinkMarkdownPattern,
      (match) => '[[${match.group(1)}]]',
    );
  });
}
