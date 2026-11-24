import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/tree.dart';
import 'package:pnote/sync/hlc.dart';

/// M12 分组的**纯函数**测试：不碰数据库、不碰 Widget。
///
/// 规则来自《PNote项目说明》7.15：
///   最多两级；组内先子组后任务；折叠只影响显示不影响计数；
///   父节点没了就上浮，绝不丢数据。
void main() {
  TaskState node(
    String id, {
    bool group = false,
    String? parent,
    bool done = false,
    bool collapsed = false,
    int color = 0,
    double order = 1024,
    int created = 1,
  }) {
    final hlc = Hlc(created, 0, 'test');
    final fields = <TaskField, FieldValue>{
      TaskField.title: FieldValue(id, hlc),
      TaskField.done: FieldValue(done ? 1 : 0, hlc),
      TaskField.order: FieldValue(order, hlc),
      TaskField.parent: FieldValue(parent, hlc),
    };
    if (group) {
      fields[TaskField.collapsed] = FieldValue(collapsed ? 1 : 0, hlc);
      fields[TaskField.color] = FieldValue(color, hlc);
    }
    return TaskState(
      id: id,
      createdAt: created,
      fields: fields,
      kind: group ? TaskKind.group : TaskKind.task,
    );
  }

  test('未完成计数：组里任务 + 子组任务都算，已完成与折叠不影响', () {
    final nodes = [
      node('g', group: true, order: 512),
      node('g1', group: true, parent: 'g', order: 1024),
      node('t1', parent: 'g', order: 2048),
      node('t2', parent: 'g1', order: 1024, done: true),
      node('t3', parent: 'g1', order: 2048),
    ];
    final counts = unfinishedCounts(nodes);
    expect(counts['g'], 2, reason: 't1 未完成 + g1 里的 t3；t2 已完成不算');
    expect(counts['g1'], 1);
  });

  test('折叠也照算：折叠只是不显示，计数仍是实时全量', () {
    final nodes = [
      node('g', group: true, collapsed: true, order: 512),
      node('t1', parent: 'g', order: 1024),
    ];
    expect(unfinishedCounts(nodes)['g'], 1);
    final rows = flattenTree(nodes);
    expect(rows.length, 1, reason: '折叠后只剩组自己一行');
    expect(rows.single.unfinished, 1);
  });

  test('组内先子组后任务，且两段之间给第一行任务打 sectionBreak', () {
    final nodes = [
      node('g', group: true, order: 512),
      node('t1', parent: 'g', order: 1024),
      node('g1', group: true, parent: 'g', order: 2048),
    ];
    final rows = flattenTree(nodes);
    expect(rows.map((r) => r.id).toList(), ['g', 'g1', 't1']);
    expect(rows[1].depth, 2);
    expect(rows[2].depth, 2);
    expect(rows[1].sectionBreak, isFalse);
    expect(rows[2].sectionBreak, isTrue, reason: '子组段与任务段之间要画细线');
  });

  test('只有任务没有子组时，不画那条细线', () {
    final nodes = [
      node('g', group: true, order: 512),
      node('t1', parent: 'g', order: 1024),
      node('t2', parent: 'g', order: 2048),
    ];
    final rows = flattenTree(nodes);
    expect(rows.skip(1).any((r) => r.sectionBreak), isFalse);
  });

  test('父节点已删除 → 孤儿上浮成一级，不丢', () {
    final nodes = [
      node('t1', parent: 'ghost', order: 1024),
    ];
    final rows = flattenTree(nodes);
    expect(rows.single.depth, 1);
    expect(rows.single.id, 't1');
  });

  test('任务挂在二级组下是合法的：显示为第三层（学习›数学›写作业）', () {
    final nodes = [
      node('a', group: true, order: 512),
      node('b', group: true, parent: 'a', order: 1024),
      node('t1', parent: 'b', order: 1024),
    ];
    final rows = flattenTree(nodes);
    final t1 = rows.firstWhere((r) => r.id == 't1');
    expect(t1.depth, 3);
  });

  test('组套三级（非法数据）→ 那个组上浮成一级，不丢', () {
    final nodes = [
      node('a', group: true, order: 512),
      node('b', group: true, parent: 'a', order: 1024),
      node('c', group: true, parent: 'b', order: 1024),
    ];
    final rows = flattenTree(nodes);
    final c = rows.firstWhere((r) => r.id == 'c');
    expect(c.depth, 1, reason: '组套组最多两级，c 是第三级组，按一级显示');
  });

  test('一级既可以是组也可以是任务：组和任务按 order 混排', () {
    final nodes = [
      node('t1', order: 512),
      node('g', group: true, order: 1024),
    ];
    final rows = flattenTree(nodes);
    expect(rows.map((r) => r.id).toList(), ['t1', 'g']);
  });

  test('validateMove：合法移动 / 移到自己 / 目标不是组 / 目标二级 / 组里有子组', () {
    final nodes = [
      node('g', group: true, order: 512),
      node('g1', group: true, parent: 'g', order: 1024),
      node('t1', order: 2048),
      node('t2', parent: 'g1', order: 1024),
    ];
    expect(validateMove(nodes, 't1', 'g'), isNull);
    expect(validateMove(nodes, 't1', null), isNull, reason: '移到顶层永远合法');
    expect(validateMove(nodes, 't1', 't1'), isNotNull);
    expect(validateMove(nodes, 't1', 't2'), isNotNull);
    expect(validateMove(nodes, 't1', 'g1'), isNotNull, reason: 'g1 是二级组');
    expect(validateMove(nodes, 'g', 'g1'), isNotNull, reason: '不能移到自己里面');
    expect(validateMove(nodes, 'g', 'nope'), isNotNull);
  });

  test('带子组的组不能再往组里沉（会变三级）', () {
    final nodes = [
      node('g', group: true, order: 512),
      node('g1', group: true, parent: 'g', order: 1024),
      node('other', group: true, order: 2048),
    ];
    final reason = validateMove(nodes, 'g', 'other');
    expect(reason, isNotNull);
    expect(reason, contains('子组'));
  });

  test('descendantIds 含全部子孙，不含自己', () {
    final nodes = [
      node('g', group: true),
      node('g1', group: true, parent: 'g'),
      node('t', parent: 'g1'),
      node('x'),
    ];
    expect(descendantIds(nodes, 'g'), {'g1', 't'});
  });
}
