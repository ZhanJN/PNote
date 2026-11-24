import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/tree.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/ui/tasks/task_list_body.dart';

/// 1.25 分组动效：折叠/展开时子行要**收缩**着离开，不能瞬间消失（用户反馈
/// 「折叠展开时会闪动」）。
///
/// 这里直接驱动 [TaskListBody] 换 rows，等价于展开态 → 折叠态的重建。
/// 注意不能用 pumpAndSettle 等动画自己跑完：要逐帧看中途的幽灵行。
void main() {
  TaskState node(
    String id, {
    bool group = false,
    String? parent,
    bool collapsed = false,
    double order = 1024,
  }) {
    final hlc = Hlc(1, 0, 'test');
    final fields = <TaskField, FieldValue>{
      TaskField.title: FieldValue(id, hlc),
      TaskField.done: FieldValue(0, hlc),
      TaskField.order: FieldValue(order, hlc),
      TaskField.parent: FieldValue(parent, hlc),
    };
    if (group) {
      fields[TaskField.collapsed] = FieldValue(collapsed ? 1 : 0, hlc);
      fields[TaskField.color] = FieldValue(0, hlc);
    }
    return TaskState(
      id: id,
      createdAt: 1,
      fields: fields,
      kind: group ? TaskKind.group : TaskKind.task,
    );
  }

  testWidgets('折叠：子行先收缩 180 ms 再移除，中途仍能看到', (tester) async {
    var nodes = [
      node('g', group: true, order: 512),
      node('t1', parent: 'g'),
    ];
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TaskListBody(
                rows: flattenTree(nodes),
                onToggle: (_) {},
                onMenu: (_, _, _) {},
                onReorder: (_, _) {},
                onCollapse: (_) {},
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('t1'), findsOneWidget);

    // 折叠：rows 变成只剩组自己一行。
    nodes = [node('g', group: true, collapsed: true, order: 512)];
    rebuild(() {});
    await tester.pump();

    // 动画开头：幽灵行还没被丢掉，只是高度在缩小。
    expect(find.text('t1'), findsOneWidget, reason: '折叠不是瞬间移除');

    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('t1'), findsOneWidget, reason: '中途仍在收缩');

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('t1'), findsNothing, reason: '180 ms 后幽灵行清掉');
  });

  testWidgets('展开：新行第一帧高度被压到 0，随后长出来', (tester) async {
    var nodes = [node('g', group: true, collapsed: true, order: 512)];
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return TaskListBody(
                rows: flattenTree(nodes),
                onToggle: (_) {},
                onMenu: (_, _, _) {},
                onReorder: (_, _) {},
                onCollapse: (_) {},
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('t1'), findsNothing);

    nodes = [
      node('g', group: true, order: 512),
      node('t1', parent: 'g'),
    ];
    rebuild(() {});
    await tester.pump();

    final aligns = tester.widgetList<Align>(
      find.ancestor(of: find.text('t1'), matching: find.byType(Align)),
    );
    expect(
      aligns.any((a) => a.heightFactor != null && a.heightFactor! < 0.5),
      isTrue,
      reason: '第一帧用 Align 的 heightFactor 把行压扁，而不是整行直接出现',
    );
  });

  testWidgets('减少动效：折叠立即生效，不留幽灵行', (tester) async {
    var nodes = [
      node('g', group: true, order: 512),
      node('t1', parent: 'g'),
    ];
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return TaskListBody(
                  rows: flattenTree(nodes),
                  onToggle: (_) {},
                  onMenu: (_, _, _) {},
                  onReorder: (_, _) {},
                  onCollapse: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('t1'), findsOneWidget);

    nodes = [node('g', group: true, collapsed: true, order: 512)];
    rebuild(() {});
    await tester.pump();

    expect(find.text('t1'), findsNothing);
  });
}
