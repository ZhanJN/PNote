/// 行内渲染：把一段 `package:markdown` 的行内节点变成 [InlineSpan]（1.41）。
///
/// 这里只认识四件事：强调/斜体/删除线、行内代码、外链、以及本项目的两种引用
/// `[[笔记]]` 和 `![[素材]]`。其余一律当纯文本，绝不执行任何外来内容。
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import 'package:pnote/notes/notes_ast.dart';

/// 认识成图片的扩展名（其余 `![[x]]` 显示成附件卡片）。
const Set<String> kImageExtensions = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
};

bool isImageName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return kImageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// 行内构建器。每渲染一次 new 一个，用 [owns] 把识别器交给外部统一释放。
/// 1.61：高亮底色，与块编辑器保持一致。
Color noteHighlightColor(String? code) {
  // 1.63.3：半透明底色，深色主题下白字也能看清。
  return switch (code) {
    'r' => const Color(0x59EF5350),
    'g' => const Color(0x594CAF50),
    'b' => const Color(0x5942A5F5),
    'p' => const Color(0x59AB47BC),
    _ => const Color(0x59FFEB3B),
  };
}

class NoteInlineBuilder {
  NoteInlineBuilder({
    required this.assets,
    required this.hasNote,
    required this.openNote,
    required this.openAsset,
    required this.openUrl,
    required this.owns,
    this.compact = false,
  });

  final Map<String, File> assets;
  final bool Function(String stem) hasNote;
  final void Function(String stem) openNote;
  final void Function(File file, String name) openAsset;
  final void Function(String url) openUrl;
  final void Function(TapGestureRecognizer recognizer) owns;

  /// 列表预览时图片更小。
  final bool compact;

  List<InlineSpan> build(List<md.Node> nodes, TextStyle style) {
    final out = <InlineSpan>[];
    for (final node in nodes) {
      _append(out, node, style);
    }
    return out;
  }

  void _append(List<InlineSpan> out, md.Node node, TextStyle style) {
    if (node is md.Text) {
      out.addAll(textSpans(node.text, style));
      return;
    }
    if (node is! md.Element) return;
    switch (node.tag) {
      case 'strong':
        _appendChildren(out, node, style.copyWith(fontWeight: FontWeight.w700));
        return;
      case 'em':
        _appendChildren(out, node, style.copyWith(fontStyle: FontStyle.italic));
        return;
      case 'del':
        _appendChildren(
          out,
          node,
          style.copyWith(decoration: TextDecoration.lineThrough),
        );
        return;
      case 'code':
        out.add(TextSpan(
          text: node.textContent,
          style: style.copyWith(
            fontFamily: 'monospace',
            fontSize: (style.fontSize ?? 15) - 1,
            backgroundColor: style.color?.withValues(alpha: 0.08),
          ),
        ));
        return;
      case 'br':
        out.add(const TextSpan(text: '\n'));
        return;
      case 'a':
        _appendLink(out, node, style);
        return;
      case 'img':
        out.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: inlineImage(node.attributes['src'] ?? '', style),
        ));
        return;
      default:
        _appendChildren(out, node, style);
    }
  }

  void _appendChildren(List<InlineSpan> out, md.Element node, TextStyle style) {
    for (final child in node.children ?? const <md.Node>[]) {
      _append(out, child, style);
    }
  }

  void _appendLink(List<InlineSpan> out, md.Element node, TextStyle style) {
    final href = node.attributes['href'] ?? '';
    final label = node.textContent.isEmpty ? href : node.textContent;
    final recognizer = TapGestureRecognizer()..onTap = () => openUrl(href);
    owns(recognizer);
    out.add(TextSpan(
      text: label,
      style: style.copyWith(
        color: _linkColor,
        decoration: TextDecoration.underline,
      ),
      recognizer: recognizer,
    ));
  }

  /// 把一段纯文本拆成「高亮 + 普通文字 + 引用」。
  List<InlineSpan> textSpans(String text, TextStyle style) {
    final out = <InlineSpan>[];
    var cursor = 0;
    for (final match in _highlight.allMatches(text)) {
      if (match.start > cursor) {
        out.addAll(_refSpans(text.substring(cursor, match.start), style));
      }
      out.add(TextSpan(
        text: match.group(2),
        style: style.copyWith(
          backgroundColor: noteHighlightColor(match.group(1)),
        ),
      ));
      cursor = match.end;
    }
    if (cursor < text.length) {
      out.addAll(_refSpans(text.substring(cursor), style));
    }
    return out;
  }

  List<InlineSpan> _refSpans(String text, TextStyle style) {
    final out = <InlineSpan>[];
    var cursor = 0;
    for (final match in kRefPattern.allMatches(text)) {
      if (match.start > cursor) {
        out.add(TextSpan(text: text.substring(cursor, match.start), style: style));
      }
      out.add(_refSpan(match.group(1) == '!', match.group(2)!.trim(), style));
      cursor = match.end;
    }
    if (cursor < text.length) {
      out.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return out;
  }

  static final _highlight = RegExp(r'==(?:\{([yrgbp])\})?([^=\n]+)==');

  InlineSpan _refSpan(bool embed, String rawName, TextStyle style) {
    if (embed && isImageName(rawName)) {
      final file = _asset(rawName);
      if (file == null) return TextSpan(text: '［缺图：$rawName］', style: _warn(style));
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _Thumb(file: file, compact: compact),
        ),
      );
    }
    if (embed) {
      final file = _asset(rawName);
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _AttachmentChip(
          name: rawName,
          exists: file != null,
          onTap: file == null ? null : () => openAsset(file, rawName),
        ),
      );
    }
    final key = normalizeRefKey(rawName);
    final anchor = refAnchor(rawName);
    final found = hasNote(key);
    // 带锚点就把原串整只传出去（`笔记#要点`），由上层决定跳到哪个标题（1.44）。
    final recognizer = TapGestureRecognizer()..onTap = () => openNote(rawName);
    owns(recognizer);
    return TextSpan(
      text: anchor == null ? '［$key］' : '［$key › $anchor］',
      style: style.copyWith(
        color: found ? _linkColor : _errorColor,
        decoration: found ? TextDecoration.underline : TextDecoration.none,
        fontWeight: FontWeight.w600,
      ),
      recognizer: recognizer,
    );
  }

  File? _asset(String rawName) {
    final name = p.basename(rawName.replaceAll('\\', '/'));
    return assets[name] ?? assets[rawName];
  }

  Widget inlineImage(String src, TextStyle style) {
    final file = _asset(src);
    if (file == null) {
      return Text('［缺图：$src］', style: _warn(style));
    }
    return _Thumb(file: file, compact: compact);
  }

  TextStyle _warn(TextStyle style) =>
      style.copyWith(color: _errorColor, fontStyle: FontStyle.italic);

  // 主题色由外层通过 DefaultTextStyle 之外的常量取，简单起见用固定语义色。
  Color get _linkColor => const Color(0xFF2E6F5E);
  Color get _errorColor => const Color(0xFFB3261E);
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file, required this.compact});

  final File file;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final maxHeight = compact ? 90.0 : 320.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        file,
        height: maxHeight,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Text('［图片打不开：${p.basename(file.path)}］'),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.name, required this.exists, this.onTap});

  final String name;
  final bool exists;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  exists ? Icons.attach_file : Icons.report_gmailerrorred,
                  size: 15,
                  color: exists ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 4),
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 13,
                    color: exists ? scheme.primary : scheme.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
