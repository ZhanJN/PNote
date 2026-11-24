import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/ui/common/press_machine.dart';

/// 长按拖拽状态机的纯逻辑测试：用「假时间」把交互稿里的每条时间线走一遍。
/// 这里不需要 Widget、不需要真手指，也不会有计时器抖动。
void main() {
  const ms = Duration(milliseconds: 1);

  PressMachine machine({bool quick = false}) => PressMachine(
        silence: const Duration(milliseconds: 150),
        grantDelay: const Duration(milliseconds: 480),
        grabSlop: 10,
        dragSlop: 6,
        allowQuickDragFromBody: quick,
      );

  Duration d(int v) => ms * v;

  test('按下后进入 pressing，界面此刻还没有任何反馈', () {
    final m = machine();
    expect(m.down(const Offset(50, 100), d(0), scrollActive: false), isTrue);
    expect(m.phase, PressPhase.pressing);
    expect(m.shouldLockScroll, isFalse);
  });

  test('150 ms 内不动：先进入 armed（开始锁滚动），还不到授予', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    expect(m.tick(d(149)), isFalse);
    expect(m.phase, PressPhase.pressing);
    expect(m.tick(d(150)), isFalse);
    expect(m.phase, PressPhase.armed);
    expect(m.shouldLockScroll, isTrue);
  });

  test('480 ms 时授予菜单资格（只返回一次 true）', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    m.tick(d(300));
    expect(m.phase, PressPhase.armed);
    expect(m.tick(d(480)), isTrue);
    expect(m.phase, PressPhase.granted);
    expect(m.tick(d(600)), isFalse, reason: '授予只发生一次');
  });

  test('静默期内位移超过死区 → 放弃识别（这次手势交给列表滚动）', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    expect(m.move(const Offset(50, 130)), PressMoveOutcome.abort);
    expect(m.phase, PressPhase.idle);
  });

  test('静默期内的小抖动不算移动', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    expect(m.move(const Offset(53, 104)), PressMoveOutcome.ignored);
    expect(m.phase, PressPhase.pressing);
  });

  test('armed 之后移动 → 转为拖拽', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    m.tick(d(200));
    expect(m.phase, PressPhase.armed);
    expect(m.move(const Offset(50, 120)), PressMoveOutcome.drag);
    expect(m.phase, PressPhase.dragging);
  });

  test('授予资格后原地抬手 → 弹菜单；移动过则是落位', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    m.tick(d(480));
    expect(m.phase, PressPhase.granted);
    expect(m.release(), PressReleaseOutcome.openMenu);

    final m2 = machine();
    m2.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    m2.tick(d(480));
    m2.move(const Offset(50, 200));
    expect(m2.release(), PressReleaseOutcome.drop);
  });

  test('没到授予就抬手 → 什么都不做（点击交给条目自己）', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    m.tick(d(200));
    expect(m.release(), PressReleaseOutcome.ignored);
    expect(m.phase, PressPhase.idle);
  });

  test('列表正在惯性滚动时不接管这次按下', () {
    final m = machine();
    expect(m.down(const Offset(50, 100), Duration.zero, scrollActive: true), isFalse);
    expect(m.phase, PressPhase.idle);
    expect(m.tick(d(600)), isFalse);
  });

  test('快速拖拽开关打开时：纵向主导才抢，横向主导仍让给滚动', () {
    final m = machine(quick: true);
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    expect(m.move(const Offset(58, 140)), PressMoveOutcome.drag);
    expect(m.phase, PressPhase.dragging);

    final m2 = machine(quick: true);
    m2.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    expect(m2.move(const Offset(120, 108)), PressMoveOutcome.abort);
  });

  test('reset 后代状态清空（指针被系统取消时用）', () {
    final m = machine();
    m.down(const Offset(50, 100), Duration.zero, scrollActive: false);
    m.tick(d(480));
    m.reset();
    expect(m.phase, PressPhase.idle);
    expect(m.shouldLockScroll, isFalse);
    expect(m.release(), PressReleaseOutcome.ignored);
  });
}
