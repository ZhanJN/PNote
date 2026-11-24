/// 渲染层：把解析后的块级节点画成 Flutter 组件（1.41）。
///
/// 支持的范围就是「读起来不丢信息」：标题、段落、强调、删除线、行内代码、
/// 列表（可嵌套）、引用、代码块、表格、分割线、图片、链接、引用卡片。
/// 不认识的标签退化成纯文本，绝不让内容消失。
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import 'package:pnote/notes/notes_ast.dart';
import 'package:pnote/notes/notes_inline.dart';

class NoteRender extends StatefulWidget {
  const NoteRender({
    super.key,
    required this.doc,
    required this.hasNote,
    required this.openNote,
    this.assets = const <String, File>{},
    this.openAsset,
    this.openUrl,
    this.compact = false,
    this.headingKeys = const <GlobalKey>[],
  });

  final NoteDoc doc;
  final Map<String, File> assets;
  final bool Function(String stem) hasNote;
  final void Function(String stem) openNote;
  final void Function(File file, String name)? openAsset;
  final void Function(String url)? openUrl;
  final bool compact;

  /// 每个标题一个 key（顺序与 `doc.headingItems` 一致），供「跳到某个标题」用。
  final List<GlobalKey> headingKeys;

  @override
  State<NoteRender> createState() => _NoteRenderState();
}

class _NoteRenderState extends State<NoteRender> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];
  late NoteInlineBuilder _inline;

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium!.copyWith(
      fontSize: widget.compact ? 13 : 15,
      height: 1.65,
    );
    _inline = NoteInlineBuilder(
      assets: widget.assets,
      hasNote: widget.hasNote,
      openNote: widget.openNote,
      openAsset: (file, name) => widget.openAsset?.call(file, name),
      openUrl: (url) => widget.openUrl?.call(url),
      owns: _recognizers.add,
      compact: widget.compact,
    );
    if (widget.doc.isEmpty) {
      return Text('（空笔记）', style: base.copyWith(color: theme.hintColor));
    }
    final blocks = <Widget>[];
    var headingIndex = 0;
    for (final node in widget.doc.nodes) {
      var widgetNode = _block(node, base);
      if (widgetNode == null) continue;
      if (node is md.Element && node.tag.length == 2 && node.tag[0] == 'h') {
        if (headingIndex < widget.headingKeys.length) {
          widgetNode = KeyedSubtree(
            key: widget.headingKeys[headingIndex],
            child: widgetNode,
          );
        }
        headingIndex++;
      }
      blocks.add(Padding(
        padding: EdgeInsets.only(bottom: widget.compact ? 6 : 10),
        child: widgetNode,
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }

  Widget? _block(md.Node node, TextStyle base) {
    if (node is md.Text) {
      final text = node.text.trim();
      if (text.isEmpty) return null;
      return Text(text, style: base);
    }
    if (node is! md.Element) return null;
    switch (node.tag) {
      case 'p':
        return _paragraph(node, base);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        return _heading(node, base);
      case 'pre':
        return _codeBlock(node, base);
      case 'blockquote':
        return _blockquote(node, base);
      case 'ul':
      case 'ol':
        return _list(node, base);
      case 'table':
        return _table(node, base);
      case 'hr':
        return const Divider(height: 24);
      case 'img':
        return _imageBlock(node.attributes['src'] ?? '', node.attributes['alt'] ?? '');
      default:
        final spans = _inline.build(node.children ?? const <md.Node>[], base);
        if (spans.isEmpty) return null;
        return Text.rich(TextSpan(children: spans), style: base);
    }
  }

  Widget _paragraph(md.Element node, TextStyle base) {
    final lone = _loneImage(node);
    if (lone != null) return lone;
    final children = node.children ?? const <md.Node>[];
    final spans = _inline.build(children, base);
    return Text.rich(TextSpan(children: spans), style: base);
  }

  /// 整段只有一个图片引用时按大图显示，而不是塞进文字行里。
  Widget? _loneImage(md.Element node) {
    final children = node.children ?? const <md.Node>[];
    if (children.length == 1 && children.first is md.Element) {
      final only = children.first as md.Element;
      if (only.tag == 'img') {
        return _imageBlock(
          only.attributes['src'] ?? '',
          only.attributes['alt'] ?? '',
        );
      }
    }
    final text = node.textContent.trim();
    final match = RegExp(r'^!\[\[([^\[\]\n]+)\]\]$').firstMatch(text);
    if (match != null && isImageName(match.group(1)!)) {
      return _imageBlock(match.group(1)!, '');
    }
    return null;
  }

  Widget _imageBlock(String src, String alt) {
    final name = p.basename(src.replaceAll('\\', '/'));
    final file = widget.assets[name] ?? widget.assets[src];
    if (file == null) {
      final scheme = Theme.of(context).colorScheme;
      return Row(
        children: [
          Icon(Icons.broken_image_outlined, size: 18, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '图片缺失：$src${alt.isEmpty ? '' : '（$alt）'}',
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
          ),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Text('图片打不开：$name'),
          ),
        ),
      ),
    );
  }

  Widget _heading(md.Element node, TextStyle base) {
    final level = int.tryParse(node.tag.substring(1)) ?? 1;
    final size = switch (level) {
      1 => 24.0,
      2 => 20.0,
      3 => 17.0,
      _ => 15.0,
    };
    final style = base.copyWith(
      fontSize: size,
      fontWeight: FontWeight.w700,
      height: 1.35,
    );
    final spans = _inline.build(node.children ?? const <md.Node>[], style);
    return Padding(
      padding: EdgeInsets.only(top: level <= 2 && !widget.compact ? 8 : 2),
      child: Text.rich(TextSpan(children: spans), style: style),
    );
  }

  Widget _codeBlock(md.Element node, TextStyle base) {
    String code = node.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          code,
          style: base.copyWith(fontFamily: 'monospace', fontSize: 13, height: 1.5),
        ),
      ),
    );
  }

  Widget _blockquote(md.Element node, TextStyle base) {
    final scheme = Theme.of(context).colorScheme;
    final inner = <Widget>[];
    for (final child in node.children ?? const <md.Node>[]) {
      final built = _block(child, base.copyWith(color: scheme.onSurfaceVariant));
      if (built != null) inner.add(built);
    }
    return Container(
      padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: scheme.primary.withValues(alpha: 0.5), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: inner,
      ),
    );
  }

  Widget _list(md.Element node, TextStyle base, {int depth = 0}) {
    final ordered = node.tag == 'ol';
    final items = <Widget>[];
    var number = 1;
    for (final child in node.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') {
        final built = _block(child, base);
        if (built != null) items.add(built);
        continue;
      }
      final bullet = ordered ? '${number++}.' : '•';
      final content = <Widget>[];
      for (final part in child.children ?? const <md.Node>[]) {
        if (part is md.Element && (part.tag == 'ul' || part.tag == 'ol')) {
          content.add(_list(part, base, depth: depth + 1));
        } else if (part is md.Element && part.tag == 'p') {
          content.add(_paragraph(part, base));
        } else {
          final built = _block(part, base);
          if (built != null) content.add(built);
        }
      }
      items.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(bullet, style: base, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: content,
            ),
          ),
        ],
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items);
  }

  Widget _table(md.Element node, TextStyle base) {
    final rows = <TableRow>[];
    var columns = 0;
    for (final section in node.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element) continue;
        final cells = <Widget>[];
        for (final cell in row.children ?? const <md.Node>[]) {
          if (cell is! md.Element) continue;
          final spans = _inline.build(cell.children ?? const <md.Node>[], base);
          cells.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text.rich(TextSpan(children: spans), style: base),
          ));
        }
        columns = cells.length > columns ? cells.length : columns;
        rows.add(TableRow(children: cells));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(
          color: scheme.outlineVariant,
          borderRadius: BorderRadius.circular(6),
        ),
        children: rows,
      ),
    );
  }
}
