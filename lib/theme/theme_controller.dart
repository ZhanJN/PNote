/// 本机偏好控制器：一支笔管"现在是黑还是白"和"要不要减少动效"（1.18 / 1.22），
/// 并且负责落库。
///
/// 为什么不用 Provider / Riverpod：整个 App 只有这一份全局偏好状态，
/// Flutter 自带的 `ChangeNotifier` + `InheritedNotifier` 就够了，
/// 也少一个依赖要跟 Flutter 版本对齐（之前 file_selector 的坑还记着）。
///
/// 为什么把「减少动效」也放这里：它和主题是同一类东西 —— 都是本机偏好、
/// 都存在 meta 表、都不参与同步。分成两个控制器只会让 app.dart 多套一层。
library;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/data/task_dao.dart';
import 'package:pnote/theme/theme.dart';

class ThemeController extends ChangeNotifier {
  ThemeController({
    required this.dao,
    required ThemeMode initialMode,
    bool initialReduceMotion = false,
  }) : _mode = initialMode,
       _reduceMotion = initialReduceMotion;

  final TaskDao dao;

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  bool _reduceMotion;
  bool get reduceMotion => _reduceMotion;

  /// 切换主题并落库。先改内存再写库：界面立刻响应，写库失败也不会把
  /// 用户的选择退回原样（下次启动顶多是旧值，不是崩溃）。
  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await dao.writeSetting(kThemeModeKey, mode.name);
    } catch (_) {
      // 写不进去就算了：本次会话内用户看到的仍然是新主题。
    }
  }

  /// 开关「减少动效」并落库。开启后 app.dart 会把 MediaQuery 的
  /// disableAnimations 置真，列表里那些 160~320 ms 的装饰动画即时归零。
  Future<void> setReduceMotion(bool value) async {
    if (value == _reduceMotion) return;
    _reduceMotion = value;
    notifyListeners();
    try {
      await dao.writeSetting(kReduceMotionKey, value ? '1' : '0');
    } catch (_) {
      // 同上：本次会话内生效即可。
    }
  }
}

/// 让任何页面都能拿到控制器：`ThemeScope.of(context)`。
/// 用 InheritedNotifier 而不是 InheritedWidget，是因为它自带"notifier 变了
/// 就重建依赖者"的行为，省掉手写 addListener/removeListener。
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope 没有挂上（检查 app.dart 的 build）');
    return scope!.notifier!;
  }
}
