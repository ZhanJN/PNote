/// 每秒检查一次「分钟数变了没有」，变了就重建一次（1.43）。
///
/// 为什么需要它：列表里的相对时间（「刚刚 / 3 分钟前 / 逾期 1 天」）是在
/// `build` 里用 `DateTime.now()` 现算的，而 `build` 只在数据变化时才会跑，
/// 于是「刚刚」可以一直挂在那儿不变——用户 1.43 反馈的正是这个。
///
/// 约定：
///   1. 每 [refreshInterval] 看一次时钟，只有「分钟数」真的变了才 `setState`，
///      避免每 20 秒白重建一遍；
///   2. 测试里不启动定时器（`FLUTTER_TEST` 环境变量）——否则 widget 测试
///      结束时会因为「还有 Timer 没取消」而失败，而测试本身用的是假时钟，
///      真实定时器永远不会合理地触发。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

/// 判断当前是不是在 `flutter test` 里跑（flutter_tester 会设这个环境变量）。
bool get kInFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');

/// 给任意 [State] 加「每分钟重建一次」的能力。
mixin MinuteRefresh<T extends StatefulWidget> on State<T> {
  /// 检查间隔：比 1 分钟短，保证跨分钟时最多晚这么久才刷新。
  Duration get refreshInterval => const Duration(seconds: 20);

  Timer? _refreshTimer;
  int _minuteSeen = _minuteOf(DateTime.now());

  static int _minuteOf(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;

  @override
  void initState() {
    super.initState();
    if (kInFlutterTest) return;
    _refreshTimer = Timer.periodic(refreshInterval, (_) => _checkClock());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _checkClock() {
    final minute = _minuteOf(DateTime.now());
    if (minute == _minuteSeen) return;
    _minuteSeen = minute;
    if (mounted) setState(() {});
  }

  /// 测试用：手动触发一次检查（不依赖真实时钟）。
  @visibleForTesting
  void refreshClockForTest() {
    _minuteSeen = -1;
    _checkClock();
  }
}
