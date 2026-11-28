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
      _protectIndentedParagraphs(_encodeImageRefs(source)),
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
  return renumberOrderedLists(
    _ensureBlockSpacing(
      _restoreIndentedParagraphs(_decodeImageRefs(_decodeNoteRefs(text))),
    ),
  );
}

/// 上游 encoder 各块之间只拼一个 `\n`，Markdown 里的空行会被吃掉——用户打开
/// 再保存一次，段落就全挤在一起了。这里在导出时把「块与块之间」的空行补回来：
/// 只在**普通段落 / 标题**这类「散行」前补空行，列表、表格、引用、围栏内部的
/// 行保持紧凑，避免把结构改坏。
final RegExp _structuralLine = RegExp(
  r'^[ \t]*(?:[-*+][ \t]|\d+[.)][ \t]|>|\||```)',
);

String _ensureBlockSpacing(String markdown) {
  if (markdown.trim().isEmpty) {
    return markdown;
  }
  final lines = markdown.split('\n');
  final out = <String>[];
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final isFence = line.trimLeft().startsWith('```');
    final inFenceBefore = inFence;
    if (isFence) {
      inFence = !inFence;
    }
    final structural = inFenceBefore ||
        isFence ||
        line.trim().isEmpty ||
        _structuralLine.hasMatch(line);
    if (i > 0 && out.isNotEmpty && out.last.trim().isNotEmpty && !structural) {
      out.add('');
    }
    out.add(line);
  }
  return out.join('\n');
}

/// 中文笔记里很常见「首行缩进四个空格」——按 CommonMark 那是**缩进代码块**，
/// 上游会把整段解析成 code 节点：块里不能输入、回车没反应、导出还会变成
/// ``` 围栏（等于改坏用户的文件）。这里在解析前把行首的 4+ 空格 / 制表符
/// 换成 U+00A0（不换行空格，宽度和样子都一样），导出时再换回空格。
final RegExp _leadingIndent = RegExp(r'^(?: {4,}|\t+)');

String _protectIndentedParagraphs(String markdown) {
  return _mapOutsideCodeFences(markdown, (line) {
    final match = _leadingIndent.firstMatch(line);
    if (match == null) {
      return line;
    }
    final indent = match.group(0)!;
    final protected = StringBuffer();
    for (final unit in indent.split('')) {
      protected.write(unit == '\t' ? '    ' : ' ');
    }
    return protected.toString().replaceAll(' ', '\u00A0') +
        line.substring(indent.length);
  });
}

final RegExp _restoreIndent = RegExp(r'^\u00A0+');

String _restoreIndentedParagraphs(String markdown) {
  return markdown
      .split('\n')
      .map((line) {
        final match = _restoreIndent.firstMatch(line);
        if (match == null) {
          return line;
        }
        return match.group(0)!.replaceAll('\u00A0', ' ') +
            line.substring(match.end);
      })
      .join('\n');
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

/// 编辑器内存里用的临时地址前缀，不会写进 Markdown 文件。
const String kPnoteImageScheme = 'pnote:';

final RegExp _imageMarkdownPattern = RegExp(r'!\[[^\]\n]*\]\(([^()\n]*)\)');
final RegExp _inlineImageRefPattern = RegExp(r'!\[\[([^\[\]\n]*)\]\]');
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
///
/// 1.65.3：原来只认「独立成行」的写法，真实笔记里常见
/// `![[照片.png]]接着写正文`（图片和正文粘在同一行，1.64 的编辑器写出来就
/// 是这样）。这种行上游解析不成图片，还会被后面的 `[[…]]` 笔记引用规则
/// 吃掉一半。现在统一拆成「图片单独一行 + 其余文字各自成行」。
String _encodeImageRefs(String markdown) {
  return _mapOutsideCodeFences(markdown, (line) {
    if (!line.contains('![[')) return line;
    final out = <String>[];
    var last = 0;
    for (final match in _inlineImageRefPattern.allMatches(line)) {
      final before = line.substring(last, match.start).trim();
      final name = match.group(1)!.trim();
      if (before.isNotEmpty) out.add(before);
      if (name.isNotEmpty) {
        out.add('![]($kPnoteImageScheme${Uri.encodeComponent(name)})');
      } else {
        out.add(match.group(0)!);
      }
      last = match.end;
    }
    final rest = line.substring(last).trim();
    if (rest.isNotEmpty) out.add(rest);
    // 图片必须自成一个「块」（空行隔开），否则上游会把整段当成一个 paragraph，
    // 行内图片节点被丢掉（正文里只剩换行）。
    return out.join('\n\n');
  });
}

/// 把图片节点的临时地址换成素材的绝对路径，供 `Image.file` 渲染。
///
/// 地址可能是三种：`pnote:素材名`（我们改写出来的）、绝对路径（刚插进来的
/// 图）、裸素材名（1.64 的编辑器写出来的 `![图片](照片.png)`）——三种都要
/// 能解析成磁盘上的绝对路径，否则 `Image.file` 会拿相对路径去找，图片就
/// 永远显示不出来。
void _applyImagePaths(
  Document document,
  String? Function(String name) resolveImage,
) {
  void visit(Node node) {
    if (node.type == ImageBlockKeys.type) {
      final raw = node.attributes[ImageBlockKeys.url];
      if (raw is String && raw.isNotEmpty) {
        final name = _assetNameOf(raw);
        if (name != null && name.isNotEmpty) {
          final path = resolveImage(name);
          node.updateAttributes({
            ImageBlockKeys.url: (path == null || path.isEmpty) ? name : path,
          });
        }
      }
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  visit(document.root);
}

/// 把上游导出的 `![](绝对路径)` 换回 `![[素材名]]`；网络图片保持原样。
///
/// 上游写图片时不会补换行，图片后面紧跟的正文会粘在同一行
/// （`![](路径)正文`）。这里顺手断开，免得下次打开又被 [_encodeImageRefs]
/// 拆一次、来回改文件。
String _decodeImageRefs(String markdown) {
  return _mapOutsideCodeFences(markdown, (line) {
    if (!line.contains('](')) return line;
    final out = StringBuffer();
    var last = 0;
    for (final match in _imageMarkdownPattern.allMatches(line)) {
      final name = _assetNameOf(match.group(1)!.trim());
      if (name == null || name.isEmpty) continue;
      out.write(line.substring(last, match.start));
      out.write('![[$name]]');
      last = match.end;
      if (last < line.length &&
          !line.substring(last).startsWith(RegExp(r'[ \t\r]'))) {
        out.write('\n');
      }
    }
    out.write(line.substring(last));
    return out.toString();
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
