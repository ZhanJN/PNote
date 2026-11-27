/// 横向标签条（1.53）。
///
/// 「全部 / 今天 / 本周 / 逾期 + 一级组」这类 chip 一多，在电脑上就没法滑动：
/// Flutter 的横向 ListView 默认只认触摸拖动，鼠标滚轮只驱动纵向滚动，鼠标
/// 也不能拖。这里补两件事：
///   1. 滚轮（竖直或水平）转成横向滚动，并且只在还能滚的时候吃掉事件，
///      免得整页跟着滚；
///   2. 允许鼠标/触控板拖动（[PointerDeviceKind.mouse] 等）。
library;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// 固定高度、可横向滚动的 chip 容器。
class HorizontalChipBar extends StatefulWidget {
  const HorizontalChipBar({
    super.key,
    required this.height,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final double height;
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  State<HorizontalChipBar> createState() => _HorizontalChipBarState();
}

class _HorizontalChipBarState extends State<HorizontalChipBar> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canScroll =>
      _controller.hasClients && _controller.position.maxScrollExtent > 0;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_canScroll) return; // 不能滚时让页面自己处理，别把滚轮吃掉。
    final delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    // 同一个滚轮事件只允许一个响应者；不注册的话父级页面也会跟着滚。
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (!_controller.hasClients) return;
      final next = (_controller.offset + delta).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      if (next != _controller.offset) _controller.jumpTo(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ScrollConfiguration(
        // 桌面端默认不允许鼠标拖动滚动视图，这里放开。
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
          },
        ),
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: ListView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            children: widget.children,
          ),
        ),
      ),
    );
  }
}
