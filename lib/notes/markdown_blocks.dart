/// 1.57：把 Markdown 拆成「块」，给块状编辑器用。
///
/// 设计原则：
///  - 源文件仍是纯文本 `.md`，块只是编辑时的视图；
///  - `parseBlocks` / `encodeBlocks` 必须能往返（同一份笔记解析再编码，文本不变），
///    否则一打开编辑器就会把用户的笔记格式改掉；
///  - 空行保留成 `MdBlockKind.blank`，不吞掉段落间距。
library;

enum MdBlockKind {
  heading1,
  heading2,
  heading3,
  paragraph,
  bullet,
  numbered,
  todo,
  quote,
  code,
  divider,
  image,
  table,
  blank,
}

/// 1.59：Markdown 会把连续空行压成一个段落间隔。
///
/// 预览时把「多出来的空行」换成一个只含零宽空格的行，这样作者连敲两次
/// 回车留出的间隙能原样看见；代码围栏里的空行不动。
String expandBlankLines(String source) {
  final lines = source.split('\n');
  final out = <String>[];
  var inFence = false;
  var blankRun = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      blankRun = 0;
      out.add(line);
      continue;
    }
    if (!inFence && trimmed.isEmpty) {
      blankRun++;
      out.add(blankRun == 1 ? '' : '\u200B');
      continue;
    }
    blankRun = 0;
    out.add(line);
  }
  return out.join('\n');
}

/// 1.61：对齐块 `::: center` … `:::` 在预览里的表示。
///
/// 把开始标记所在行换成空行，并给第一行正文加一个不可见前缀字符：
/// U+2063 居左、U+2064 居中、U+2065 居右。渲染器据此设置 TextAlign 并把
/// 这个字符去掉，文件本身仍是干净的 `::: center` 写法。
String applyAlignmentMarkers(String source) {
  final open = RegExp(r'^:::\s*(left|center|right)\s*$');
  final close = RegExp(r'^:::\s*$');
  final lines = source.split('\n');
  final out = <String>[];
  var inFence = false;
  String? pending;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence) {
      out.add(line);
      continue;
    }
    final start = open.firstMatch(trimmed);
    if (start != null) {
      pending = start.group(1);
      out.add('');
      continue;
    }
    if (close.hasMatch(trimmed)) {
      pending = null;
      out.add('');
      continue;
    }
    if (pending != null && trimmed.isNotEmpty) {
      final mark = switch (pending) {
        'center' => '\u2064',
        'right' => '\u2065',
        _ => '\u2063',
      };
      out.add('$mark$line');
      pending = null;
      continue;
    }
    out.add(line);
  }
  return out.join('\n');
}

/// 1.60：兼容「###标题」这种缺空格的 ATX 标题，并把只有井号的行当空行。
///
/// 作者手写 Markdown 时常漏掉井号后的空格，标准解析器会把它当正文，
/// 预览里就原样冒出「###」。这里只在解析前补空格，不碰代码围栏里的内容。
String normalizeHeadings(String source) {
  final lines = source.split('\n');
  final out = <String>[];
  var inFence = false;
  final heading = RegExp(r'^(#{1,6})([^\s#].*)$');
  final bare = RegExp(r'^#{1,6}\s*$');
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence) {
      out.add(line);
      continue;
    }
    if (bare.hasMatch(line.trim())) {
      out.add('');
      continue;
    }
    final match = heading.firstMatch(line);
    out.add(match == null ? line : '${match.group(1)} ${match.group(2)}');
  }
  return out.join('\n');
}

/// 1.60：预览时保护行首 4 个以上空格的缩进。
///
/// Markdown 会把这种行当成缩进代码块，于是普通的一段缩进文字被画进灰框。
/// 用等量的不间断空格替换，只影响显示，不改文件。
String protectIndentedLines(String source) {
  final lines = source.split('\n');
  final out = <String>[];
  var inFence = false;
  final indent = RegExp(r'^( {4,})(\S.*)$');
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence) {
      out.add(line);
      continue;
    }
    final match = indent.firstMatch(line);
    if (match == null) {
      out.add(line);
      continue;
    }
    final spaces = match.group(1)!.length;
    out.add('${'\u00A0' * spaces}${match.group(2)}');
  }
  return out.join('\n');
}

class MdBlock {
  MdBlock(this.kind, this.text,
      {this.checked = false, this.imageName, this.codeInfo, this.align = ''});

  MdBlockKind kind;
  String text;

  /// 仅 [MdBlockKind.todo] 用。
  bool checked;

  /// 仅 [MdBlockKind.image] 且是 `![[素材名]]` 形式时有值。
  String? imageName;

  /// 仅 [MdBlockKind.code]：围栏后的语言标记（```dart 的 dart）。
  String? codeInfo;

  /// 1.61：段落对齐，`''` = 默认，`left` / `center` / `right`。
  /// 存成 `::: center` … `:::` 包住的块，文件仍是纯文本。
  String align;

  bool get isEmpty => text.trim().isEmpty;

  static final RegExp _h1 = RegExp(r'^#\s+(.*)$');
  static final RegExp _h2 = RegExp(r'^##\s+(.*)$');
  static final RegExp _h3 = RegExp(r'^###\s+(.*)$');
  static final RegExp _todo = RegExp(r'^[-*+]\s+\[([ xX])\]\s?(.*)$');
  static final RegExp _bullet = RegExp(r'^[-*+]\s+(.*)$');
  static final RegExp _numbered = RegExp(r'^\d{1,3}[.)]\s+(.*)$');
  static final RegExp _quote = RegExp(r'^>\s?(.*)$');
  static final RegExp _divider = RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$');
  static final RegExp _fence = RegExp(r'^\s*```(.*)$');
  static final RegExp _image = RegExp(r'^!\[\[([^\]\|]+)(?:\|([0-9]+))?\]\]\s*$');
  static final RegExp _imageMd = RegExp(r'^!\[[^\]]*\]\(([^)]+)\)\s*$');
  static final RegExp _table = RegExp(r'^\s*\|');
  static final RegExp _alignStart = RegExp(r'^:::\s*(left|center|right)\s*$');
  static final RegExp _alignEnd = RegExp(r'^:::\s*$');

  /// 一行是不是「新块的开始」。工具栏拆分段落时用它判断。
  static bool startsBlock(String line) {
    final t = line.trimRight();
    if (t.trim().isEmpty) return true;
    if (_alignStart.hasMatch(t.trim())) return true;
    if (_fence.hasMatch(t) ||
        _divider.hasMatch(t) ||
        _table.hasMatch(t) ||
        _image.hasMatch(t) ||
        _imageMd.hasMatch(t)) {
      return true;
    }
    if (_h1.hasMatch(t) || _h2.hasMatch(t) || _h3.hasMatch(t)) return true;
    if (_todo.hasMatch(t) || _bullet.hasMatch(t)) return true;
    if (_numbered.hasMatch(t) || _quote.hasMatch(t)) return true;
    return false;
  }

  static List<MdBlock> parseBlocks(String source) {
    if (source.isEmpty) return <MdBlock>[];
    source = normalizeHeadings(source);
    final lines = source.split('\n');
    final blocks = <MdBlock>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trimRight();

      final fence = _fence.firstMatch(trimmed);
      if (fence != null) {
        final info = (fence.group(1) ?? '').trim();
        i++;
        final body = <String>[];
        while (i < lines.length && !_fence.hasMatch(lines[i].trimRight())) {
          body.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // 跳过结尾 ```
        blocks.add(MdBlock(
          MdBlockKind.code,
          body.join('\n'),
          codeInfo: info.isEmpty ? null : info,
        ));
        continue;
      }

      final align = _alignStart.firstMatch(trimmed.trim());
      if (align != null) {
        final dir = align.group(1)!;
        i++;
        final body = <String>[];
        while (i < lines.length && !_alignEnd.hasMatch(lines[i].trim())) {
          body.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // 跳过结尾 :::
        blocks.add(MdBlock(MdBlockKind.paragraph, body.join('\n'), align: dir));
        continue;
      }

      if (trimmed.trim().isEmpty) {
        blocks.add(MdBlock(MdBlockKind.blank, ''));
        i++;
        continue;
      }

      if (_divider.hasMatch(trimmed)) {
        blocks.add(MdBlock(MdBlockKind.divider, ''));
        i++;
        continue;
      }

      final image = _image.firstMatch(trimmed);
      if (image != null) {
        blocks.add(MdBlock(MdBlockKind.image, trimmed, imageName: image.group(1)));
        i++;
        continue;
      }

      final imageMd = _imageMd.firstMatch(trimmed);
      if (imageMd != null) {
        blocks.add(MdBlock(MdBlockKind.image, trimmed, imageName: imageMd.group(1)));
        i++;
        continue;
      }

      final h1 = _h1.firstMatch(trimmed);
      if (h1 != null) {
        blocks.add(MdBlock(MdBlockKind.heading1, h1.group(1) ?? ''));
        i++;
        continue;
      }
      final h2 = _h2.firstMatch(trimmed);
      if (h2 != null) {
        blocks.add(MdBlock(MdBlockKind.heading2, h2.group(1) ?? ''));
        i++;
        continue;
      }
      final h3 = _h3.firstMatch(trimmed);
      if (h3 != null) {
        blocks.add(MdBlock(MdBlockKind.heading3, h3.group(1) ?? ''));
        i++;
        continue;
      }

      final todo = _todo.firstMatch(trimmed);
      if (todo != null) {
        blocks.add(MdBlock(
          MdBlockKind.todo,
          todo.group(2) ?? '',
          checked: (todo.group(1) ?? ' ').toLowerCase() == 'x',
        ));
        i++;
        continue;
      }

      final bullet = _bullet.firstMatch(trimmed);
      if (bullet != null) {
        blocks.add(MdBlock(MdBlockKind.bullet, bullet.group(1) ?? ''));
        i++;
        continue;
      }

      final numbered = _numbered.firstMatch(trimmed);
      if (numbered != null) {
        blocks.add(MdBlock(MdBlockKind.numbered, numbered.group(1) ?? ''));
        i++;
        continue;
      }

      final quote = _quote.firstMatch(trimmed);
      if (quote != null) {
        blocks.add(MdBlock(MdBlockKind.quote, quote.group(1) ?? ''));
        i++;
        continue;
      }

      if (_table.hasMatch(trimmed)) {
        blocks.add(MdBlock(MdBlockKind.table, line));
        i++;
        continue;
      }

      blocks.add(MdBlock(MdBlockKind.paragraph, line));
      i++;
    }
    return blocks;
  }

  static String encodeBlocks(List<MdBlock> blocks) {
    final buffer = StringBuffer();
    var number = 0;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      // 1.60：有序列表按连续段落的序号写回，不再全部写成 1.。
      if (block.kind == MdBlockKind.numbered) {
        number += 1;
      } else {
        number = 0;
      }
      if (i > 0) buffer.write('\n');
      buffer.write(_encodeOne(block, number));
    }
    return buffer.toString();
  }

  static String _encodeOne(MdBlock block, int number) {
    switch (block.kind) {
      case MdBlockKind.heading1:
        return '# ${block.text}';
      case MdBlockKind.heading2:
        return '## ${block.text}';
      case MdBlockKind.heading3:
        return '### ${block.text}';
      case MdBlockKind.paragraph:
        if (block.align.isEmpty) return block.text;
        return '::: ${block.align}\n${block.text}\n:::';
      case MdBlockKind.bullet:
        return '- ${block.text}';
      case MdBlockKind.numbered:
        return '${number <= 0 ? 1 : number}. ${block.text}';
      case MdBlockKind.todo:
        return '- [${block.checked ? 'x' : ' '}] ${block.text}';
      case MdBlockKind.quote:
        return '> ${block.text}';
      case MdBlockKind.code:
        return '```${block.codeInfo ?? ''}\n${block.text}\n```';
      case MdBlockKind.divider:
        return '---';
      case MdBlockKind.image:
        return block.text;
      case MdBlockKind.table:
        return block.text;
      case MdBlockKind.blank:
        return '';
    }
  }

  static MdBlock emptyParagraph() => MdBlock(MdBlockKind.paragraph, '');
}
