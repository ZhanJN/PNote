/// 长按 → 授予「菜单资格」→ 拖拽 / 弹菜单 的**纯逻辑状态机**（1.20）。
///
/// 为什么单独抽出来：这套判定的错法都很隐蔽（闪现、误触发、抢走滚动），
/// 抽成纯函数后可以在单元测试里用「假时间」把每条时间线走一遍，
/// 不用起 Widget、也不用真手指。
///
/// 时间线（与用户给的交互稿一致）：
///
///   0 ms        按下 → [PressPhase.pressing]。界面**什么都不做**：
///               不抬起、不让位、不震 —— 否则每次点击都会闪一下。
///   0–120 ms    静默期。位移超过 [grabSlop] 就说明这不是长按（用户在滚动），
///               直接放弃本次识别（[PressMoveOutcome.abort]），交给列表滚动。
///   120 ms      仍在原地 → 进入 [PressPhase.armed]：此时才会「关掉列表滚动」，
///               因为用户已经明确地在原地按住了。此后位移就给拖拽用。
///   120–320 ms  改主意窗口：开始移动 → 转拖拽；一直不动就等授予资格。
///   320 ms      授予资格 → [PressPhase.granted]：条目轻微抬起 + 阴影加深 +
///               轻震一次。**此时不弹菜单** —— 菜单会盖住列表，用户就没法
///               接着拖了；这段空窗正是留给用户改主意的时间。
///   granted 后  移动 → 转拖拽；原地抬手 → 弹菜单（菜单要偏离锚点）。
///   dragging 后 抬手 → 落位（提交新顺序）。
///
/// 一处刻意的取舍（[allowQuickDragFromBody]）：交互稿里「按下 150 ms 内
/// 位移超阈值就永久进入拖拽态」这一条，在**整行都能按**的列表上与滚动完全
/// 互斥 —— 手指一往下动，到底是滚动还是拖拽没有任何信息能区分。
/// 所以默认关闭（false）：早期位移一律判给滚动；想快速拖拽请用右侧把手的
/// 独立入口。把它设成 true 只是保留实验能力，不要在正式版打开。
library;

import 'dart:ui' show Offset;

/// 识别阶段。
enum PressPhase {
  /// 没有手指按在条目上。
  idle,

  /// 已按下，仍在 120 ms 静默期内。界面零反馈。
  pressing,

  /// 静默期已过、还没到授予时间。列表滚动已被关掉，位移开始算拖拽。
  armed,

  /// 已授予「菜单资格」：条目抬起 + 轻震，但菜单还没弹。
  granted,

  /// 正在拖拽（插入位置随手指移动）。
  dragging,
}

/// 一次位移的判定结果。
enum PressMoveOutcome {
  /// 位移太小，还不到判定阈值，什么也不做。
  ignored,

  /// 放弃本次识别（把这次手势让给列表滚动 / 横向滑动）。
  abort,

  /// 进入 / 保持在拖拽态。
  drag,
}

/// 抬手时的判定结果。
enum PressReleaseOutcome {
  /// 不是我们要处理的手势（点击交给条目自己的 onTap）。
  ignored,

  /// 已授予资格、且没有移动过 → 应该弹菜单。
  openMenu,

  /// 拖拽结束 → 应该提交新顺序。
  drop,
}

/// 长按拖拽状态机。
///
/// 全部时间由外部传入（[Duration]），这样测试里可以「快进」，也不必依赖
/// 真实计时器；真实运行时由 Widget 用 Timer 驱动 [tick]。
class PressMachine {
  PressMachine({
    this.silence = const Duration(milliseconds: 120),
    this.grantDelay = const Duration(milliseconds: 320),
    this.grabSlop = 10,
    this.dragSlop = 6,
    this.allowQuickDragFromBody = false,
  });

  /// 静默期：这段时间内界面零反馈，位移超阈值即判定为「不是长按」。
  final Duration silence;

  /// 从按下到授予「菜单资格」的时间。1.21 起按用户反馈「判定太长」从
  /// 480 ms 收紧到 320 ms（静默期同时 150 → 120）。
  final Duration grantDelay;

  /// 静默期内允许的手指抖动（像素）。超过它就不再是长按。
  final double grabSlop;

  /// 已授予资格后，移动多少像素才真正开始拖拽。
  final double dragSlop;

  /// 是否允许「按下就快速拖动」（默认关闭，理由见文件头）。
  final bool allowQuickDragFromBody;

  PressPhase _phase = PressPhase.idle;
  Offset _origin = Offset.zero;
  Duration _downAt = Duration.zero;

  PressPhase get phase => _phase;

  bool get isActive => _phase != PressPhase.idle;

  /// 是否已经该关掉列表滚动（armed / granted / dragging 三个阶段）。
  bool get shouldLockScroll =>
      _phase == PressPhase.armed ||
      _phase == PressPhase.granted ||
      _phase == PressPhase.dragging;

  /// 手指按下。
  ///
  /// [scrollActive] 为 true 时不接管（列表正在惯性滚动，任何按压都该先停下
  /// 滚动，而不是被识别成长按）。返回 true 表示这次按下归我们管。
  bool down(Offset position, Duration now, {required bool scrollActive}) {
    if (scrollActive) {
      _phase = PressPhase.idle;
      return false;
    }
    _phase = PressPhase.pressing;
    _origin = position;
    _downAt = now;
    return true;
  }

  /// 时钟推进。返回 true 表示**刚刚**授予了菜单资格（调用方据此做抬起 + 轻震）。
  bool tick(Duration now) {
    if (_phase != PressPhase.pressing && _phase != PressPhase.armed) {
      return false;
    }
    final held = now - _downAt;
    if (held < silence) return false;
    if (held >= grantDelay) {
      _phase = PressPhase.granted;
      return true;
    }
    _phase = PressPhase.armed; // 静默期已过，但还没到授予时间
    return false;
  }

  /// 手指移动。
  PressMoveOutcome move(Offset position) {
    final delta = position - _origin;
    final distance = delta.distance;
    switch (_phase) {
      case PressPhase.idle:
        return PressMoveOutcome.ignored;

      case PressPhase.pressing:
        // 静默期内的位移：只有「纵向主导 1.5 倍以上」并且显式允许快速拖拽时
        // 才抢过来；否则一律放弃识别，让列表去滚动。
        if (distance <= grabSlop) return PressMoveOutcome.ignored;
        final verticalDominant =
            delta.dy.abs() >= 1.5 * delta.dx.abs() && delta.dy.abs() > grabSlop;
        if (allowQuickDragFromBody && verticalDominant) {
          _phase = PressPhase.dragging;
          return PressMoveOutcome.drag;
        }
        _phase = PressPhase.idle;
        return PressMoveOutcome.abort;

      case PressPhase.armed:
        if (distance >= dragSlop) {
          _phase = PressPhase.dragging;
          return PressMoveOutcome.drag;
        }
        return PressMoveOutcome.ignored;

      case PressPhase.granted:
        if (distance >= dragSlop) {
          _phase = PressPhase.dragging;
          return PressMoveOutcome.drag;
        }
        return PressMoveOutcome.ignored;

      case PressPhase.dragging:
        return PressMoveOutcome.drag;
    }
  }

  /// 手指抬起（或手势被系统取消 —— 取消时调用 [reset]，不要调用它）。
  PressReleaseOutcome release() {
    final was = _phase;
    _phase = PressPhase.idle;
    return switch (was) {
      PressPhase.pressing || PressPhase.armed => PressReleaseOutcome.ignored,
      PressPhase.granted => PressReleaseOutcome.openMenu,
      PressPhase.dragging => PressReleaseOutcome.drop,
      PressPhase.idle => PressReleaseOutcome.ignored,
    };
  }

  /// 立刻回到初始状态（指针取消、条目被移除、页面销毁）。
  void reset() {
    _phase = PressPhase.idle;
  }
}
