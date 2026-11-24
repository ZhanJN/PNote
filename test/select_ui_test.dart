import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/tree.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/ui/tasks/task_list_body.dart';

/// 1.29 多选模式的行级行为：选中走 onSelect，不再触发完成/折叠。
void main() {
  TaskState task(String id, String title) => TaskState(
        id: id,
        createdAt: 1000,
        fields: {
          TaskField.title: FieldValue(title, const Hlc(1000, 0, 'd')),
          TaskField.done: FieldValue(0, const Hlc(1000, 0, 'd')),
          TaskField.order: FieldValue(1024.0, const Hlc(1000, 0, 'd')),
        },
      );

  testWidgets('多选模式：点行回调选中，不触发勾选', (tester) async {
    final nodes = [task('a', '写作业')];
    NodeRow? picked;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListBody(
            rows: flattenTree(nodes),
            onToggle: (_) => fail('多选时不应触发完成'),
            onMenu: (_, _, _) {},
            onReorder: (_, _) {},
            onCollapse: (_) => fail('多选时不应折叠'),
            selecting: true,
            selectedIds: const <String>{},
            onSelect: (row) => picked = row,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('写作业'));
    await tester.pump();

    expect(picked?.id, 'a');
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).value,
      isFalse,
    );
  });

  testWidgets('多选模式：已选中的行勾选框为 true', (tester) async {
    final nodes = [task('a', '写作业')];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskListBody(
            rows: flattenTree(nodes),
            onToggle: (_) {},
            onMenu: (_, _, _) {},
            onReorder: (_, _) {},
            onCollapse: (_) {},
            selecting: true,
            selectedIds: const {'a'},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
  });
}
