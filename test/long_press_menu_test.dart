import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/tree.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/ui/tasks/task_list_body.dart';

/// 1.20 长按交互的**接线测试**。
///
/// 这里只测 [TaskListBody] 本身：它只吃一个摊平后的行列表 + 四个回调，
/// 完全不碰数据库（DAO 会引入真实文件 I/O，在 FakeAsync 里极易把测试挂死，踩过）。
/// 状态机逐条行为在 press_machine_test.dart，数据层在 reorder_test.dart。
void main() {
  TaskState task(String id, String title, {int created = 1}) {
    final hlc = Hlc(created, 0, 'dev');
    return TaskState(
      id: id,
      createdAt: created,
      fields: {
        TaskField.title: FieldValue(title, hlc),
        TaskField.done: FieldValue(0, hlc),
        TaskField.order: FieldValue(created * 1024.0, hlc),
      },
    );
  }

  /// 不用 pumpAndSettle：一旦有东西持续排帧它就会一直等（踩过 10 分钟超时）。
  Future<void> settleFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpList(
    WidgetTester tester,
    List<TaskState> tasks, {
    void Function(TaskState, String?)? onReorder,
    void Function(TaskState, Rect, Offset?)? onMenu,
    void Function(TaskState)? onToggle,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListBody(
            rows: flattenTree(tasks),
            onToggle: (row) => onToggle?.call(row.node),
            onMenu: (row, rect, at) => onMenu?.call(row.node, rect, at),
            onReorder: (row, beforeId) => onReorder?.call(row.node, beforeId),
            onCollapse: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('按住 500 ms 再松手 → 回调 onMenu（弹菜单由外层负责）', (tester) async {
    final tasks = [task('a', 'A'), task('b', 'B')];
    TaskState? menuTask;
    Rect? menuRect;
    await pumpList(tester, tasks, onMenu: (t, r, _) {
      menuTask = t;
      menuRect = r;
    });

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 320)); // 累计 > 480 ms
    await gesture.up();
    await settleFrames(tester);

    expect(menuTask?.id, 'a');
    expect(menuRect, isNotNull, reason: '菜单需要锚点才能避开手指');
    expect(menuRect!.height, greaterThan(0));
  });

  testWidgets('长按弹菜单时**不会**顺手把任务勾上（用户 bug 1）', (tester) async {
    var toggled = 0;
    var menuCount = 0;
    await pumpList(
      tester,
      [task('a', 'A'), task('b', 'B')],
      onToggle: (_) => toggled++,
      onMenu: (_, _, _) => menuCount++,
    );

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 400)); // 超过授予时间
    await gesture.up();
    await settleFrames(tester);

    expect(menuCount, 1, reason: '长按应该弹出菜单');
    expect(toggled, 0, reason: '同一根手指的抬起不能再触发勾选');
    expect(tester.takeException(), isNull);
  });

  testWidgets('判定收紧后：按住 340 ms 就足够授予资格（不用等 0.5 秒）', (tester) async {
    var menuCount = 0;
    await pumpList(tester, [task('a', 'A')], onMenu: (_, _, _) => menuCount++);

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 340));
    await gesture.up();
    await settleFrames(tester);

    expect(menuCount, 1);
  });

  testWidgets('只按 250 ms 就松手 → 不触发 onMenu', (tester) async {
    var menuCount = 0;
    await pumpList(tester, [task('a', 'A')], onMenu: (_, _, _) => menuCount++);

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.up();
    await settleFrames(tester);

    expect(menuCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('静默期内大幅移动 → 放弃识别，不触发 onMenu / onReorder', (tester) async {
    var menuCount = 0;
    var reorderCount = 0;
    await pumpList(
      tester,
      [task('a', 'A'), task('b', 'B')],
      onMenu: (_, _, _) => menuCount++,
      onReorder: (_, _) => reorderCount++,
    );

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveBy(const Offset(0, 60)); // 超过死区 → 让给滚动
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.up();
    await settleFrames(tester);

    expect(menuCount, 0);
    expect(reorderCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按后往下拖过 B → onReorder 收到落点（拖到末尾 = null）', (tester) async {
    final tasks = [task('a', 'A'), task('b', 'B'), task('c', 'C')];
    TaskState? moved;
    String? before;
    await pumpList(tester, tasks, onReorder: (t, b) {
      moved = t;
      before = b;
    });

    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 500)); // 授予资格
    await gesture.moveTo(tester.getCenter(find.text('C')) + const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.up();
    await settleFrames(tester);

    expect(moved?.id, 'a');
    expect(before, isNull, reason: '拖过最后一行 → 插到同级末尾');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点行尾 ⋮ → 同一个 onMenu 回调（长按之外的第二入口）', (tester) async {
    TaskState? menuTask;
    await pumpList(
      tester,
      [task('a', 'A')],
      onMenu: (t, _, _) => menuTask = t,
    );

    await tester.tap(find.byTooltip('更多').first);
    await settleFrames(tester);

    expect(menuTask?.id, 'a');
  });

  testWidgets('点复选框 → onToggle（这条不能被长按逻辑吃掉）', (tester) async {
    var toggled = 0;
    await pumpList(
      tester,
      [task('a', 'A')],
      onToggle: (_) => toggled++,
    );

    await tester.tap(find.byType(Checkbox).first);
    await settleFrames(tester);

    expect(toggled, 1);
  });

  testWidgets('电脑上右键 → 同一个 onMenu，并带上鼠标位置（1.23）', (tester) async {
    Rect? rect;
    Offset? at;
    await pumpList(
      tester,
      [task('a', 'A'), task('b', 'B')],
      onMenu: (_, r, p) {
        rect = r;
        at = p;
      },
    );

    final target = tester.getCenter(find.text('B'));
    final gesture = await tester.startGesture(
      target,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await settleFrames(tester);

    expect(rect, isNotNull, reason: '右键要能定位到具体某一行');
    expect(at, isNotNull, reason: '菜单要弹在鼠标那一点，而不是行左端');
    expect((at! - target).distance, lessThan(2));
  });

  testWidgets('正在删除的行会淡出（删除过渡只动透明度）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListBody(
            rows: flattenTree([task('a', 'A')]),
            onToggle: (_) {},
            onMenu: (_, _, _) {},
            onReorder: (_, _) {},
            onCollapse: (_) {},
            removingId: 'a',
          ),
        ),
      ),
    );
    await tester.pump();

    final fade = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity).first,
    );
    expect(fade.opacity, 0, reason: '淡出用来解释「这一条正在离开」');
    expect(fade.duration, const Duration(milliseconds: 160));
  });
}
