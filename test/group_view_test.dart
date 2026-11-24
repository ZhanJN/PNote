import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/tree.dart';
import 'package:pnote/sync/hlc.dart';

/// M16 组视图（1.33）的纯函数测试：
/// 一组一个视角，顺序与树里一致；折叠的组进了视图也要看到内容。
void main() {
  TaskState node(
    String id, {
    bool group = false,
    String? parent,
    bool collapsed = false,
    double order = 1024,
    int created = 1,
  }) {
    final hlc = Hlc(created, 0, 'test');
    final fields = <TaskField, FieldValue>{
      TaskField.title: FieldValue(id, hlc),
      TaskField.order: FieldValue(order, hlc),
      TaskField.parent: FieldValue(parent, hlc),
      TaskField.done: FieldValue(0, hlc),
    };
    if (group) {
      fields[TaskField.collapsed] = FieldValue(collapsed ? 1 : 0, hlc);
      fields[TaskField.color] = FieldValue(0, hlc);
    }
    return TaskState(
      id: id,
      createdAt: created,
      fields: fields,
      kind: group ? TaskKind.group : TaskKind.task,
    );
  }

  test('组视图只含这个组的子孙，组自己不再占一行，层级从 1 起', () {
    final nodes = [
      node('g', group: true, order: 512),
      node('g1', group: true, parent: 'g', order: 1024),
      node('t1', parent: 'g', order: 2048),
      node('t2', parent: 'g1', order: 1024),
      node('other', order: 4096),
    ];
    final rows = groupViewRows(nodes, 'g');
    expect(rows.map((r) => r.id).toList(), ['g1', 't2', 't1']);
    expect(rows.map((r) => r.depth).toList(), [1, 2, 1]);
  });

  test('组折叠着，进组视图仍能看到内容（折叠标记不变）', () {
    final nodes = [
      node('g', group: true, collapsed: true, order: 512),
      node('t1', parent: 'g', order: 1024),
    ];
    expect(flattenTree(nodes).map((r) => r.id), ['g']);
    expect(groupViewRows(nodes, 'g').map((r) => r.id), ['t1']);
    expect(nodes.first.collapsed, isTrue, reason: '数据里的折叠状态没被改动');
  });

  test('组不存在（已删/被同步覆盖）时返回空，不抛错', () {
    expect(groupViewRows([node('t', order: 512)], 'missing'), isEmpty);
  });
}
