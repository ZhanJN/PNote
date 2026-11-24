/// 解析层：把一篇 Markdown 源码变成「可渲染的树 + 元信息」（1.41）。
///
/// 只用 `package:markdown` 的 GFM 扩展集，不加自定义块语法——这样任何别的
/// Markdown 编辑器打开同一份文件，看到的结构都一样（见 ADR-034）。
library;

import 'package:markdown/markdown.dart' as md;

/// `[[名字]]` 与 `![[名字]]` 的统一匹配：group(1) 是 `!` 或空。
final RegExp kRefPattern = RegExp(r'(!?)\[\[([^\[\]\n]+)\]\]');

/// 一个标题：层级、纯文本、在源码里的起始下标（1.44 大纲用）。
///
/// `offset` 指向 `#` 号本身，这样「跳到某个标题」在编辑器里就是把光标挪过去。
class NoteHeading {
  const NoteHeading({
    required this.level,
    required this.text,
    required this.offset,
  });

  final int level;
  final String text;
  final int offset;

  /// `[[笔记#要点]]` 里的「要点」是否就是这个标题（忽略大小写与首尾空格）。
  bool matches(String anchor) =>
      text.trim().toLowerCase() == anchor.trim().toLowerCase();
}

/// 扫一遍源码找 ATX 标题（`#` 开头）并记下偏移量。
///
/// 围栏代码块（``` 或 ~~~）里的 `#` 不算标题——否则贴一段 Python 注释就会
/// 在大纲里冒出一堆假标题。
List<NoteHeading> scanHeadings(String source) {
  final out = <NoteHeading>[];
  final pattern = RegExp(r'^(#{1,6})\s+(.*)$');
  var offset = 0;
  String? fence;
  for (final line in source.split('\n')) {
    final body = line.trimLeft();
    final indent = line.length - body.length;
    if (fence != null) {
      if (body.startsWith(fence)) fence = null;
    } else if (body.startsWith('```') || body.startsWith('~~~')) {
      fence = body.substring(0, 3);
    } else {
      final match = pattern.firstMatch(body);
      if (match != null) {
        var text = match.group(2)!.trim();
        // 收尾的「#」是装饰（`## 要点 ##`），去掉。
        text = text.replaceFirst(RegExp(r'\s+#+\s*$'), '').trim();
        if (text.isNotEmpty) {
          out.add(NoteHeading(
            level: match.group(1)!.length,
            text: text,
            offset: offset + indent,
          ));
        }
      }
    }
    offset += line.length + 1;
  }
  return out;
}

/// `[[笔记#要点]]` 里的锚点（`#` 之后的部分）。没有锚点时返回 null。
String? refAnchor(String raw) {
  final hash = raw.indexOf('#');
  if (hash < 0) return null;
  final anchor = raw.substring(hash + 1).trim();
  return anchor.isEmpty ? null : anchor;
}

/// 一篇笔记解析后的结果。
class NoteDoc {
  const NoteDoc({
    required this.nodes,
    required this.headings,
    required this.headingItems,
    required this.assets,
    required this.links,
  });

  /// 块级节点（`md.Element` / `md.Text`）。
  final List<md.Node> nodes;

  /// 文档里所有标题的纯文本，按出现顺序（第二步做大纲用）。
  final List<String> headings;

  /// 同 [headings]，但带层级与源码偏移（1.44 大纲 / 锚点跳转）。
  final List<NoteHeading> headingItems;

  /// `![[xxx]]` 引用的素材名（图片、附件）。
  final Set<String> assets;

  /// `[[xxx]]` 引用的笔记名。
  final Set<String> links;

  bool get isEmpty => nodes.isEmpty;
}

/// 解析源码。不会抛异常——坏掉的语法最多显示成原文。
NoteDoc parseNoteSource(String source) {
  final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  final nodes = document.parse(source);

  final headings = <String>[];
  for (final node in nodes) {
    if (node is md.Element && node.tag.length == 2 && node.tag[0] == 'h') {
      headings.add(node.textContent.trim());
    }
  }

  // 偏移量得自己扫（AST 不给位置）。行内强调会让 AST 文本与原文不同（`**粗**`
  // vs `粗`），所以文本取 AST 的，位置按顺序取扫描结果；两者数量不一致
  // （setext 标题、围栏里的假标题）就退回扫描结果，宁丑勿错。
  final scanned = scanHeadings(source);
  final headingItems = <NoteHeading>[];
  if (scanned.length == headings.length) {
    for (var i = 0; i < headings.length; i++) {
      headingItems.add(NoteHeading(
        level: scanned[i].level,
        text: headings[i],
        offset: scanned[i].offset,
      ));
    }
  } else {
    headingItems.addAll(scanned);
  }

  final assets = <String>{};
  final links = <String>{};
  for (final match in kRefPattern.allMatches(source)) {
    final name = match.group(2)!.trim();
    if (name.isEmpty) continue;
    if (match.group(1) == '!') {
      assets.add(name);
    } else {
      links.add(name);
    }
  }

  return NoteDoc(
    nodes: nodes,
    headings: headings,
    headingItems: headingItems,
    assets: assets,
    links: links,
  );
}

/// 把 `[[xxx]]` 里的名字规范化成链接键：去掉 `#` 之后的部分、去掉 `.md` 后缀。
String normalizeRefKey(String raw) {
  var name = raw.trim();
  final hash = name.indexOf('#');
  if (hash >= 0) name = name.substring(0, hash);
  if (name.toLowerCase().endsWith('.md')) {
    name = name.substring(0, name.length - 3);
  }
  return name.trim();
}
