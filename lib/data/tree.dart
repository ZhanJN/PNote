/// 两级分组的纯函数：扁平化、未完成计数、移动校验。
///
/// 为什么单独一个文件：这些逻辑要能被单元测试直接喂数据，不需要数据库、
/// 不需要 Widget。UI 只负责把 [flattenTree] 的结果画出来。
///
/// 规则（《PNote项目说明》7.15）：
///   - 最多两级：一级节点（parentId 为 null）+ 二级节点（挂在某个一级组下）。
///   - 组内显示顺序：先子组、后任务，各自按 order/createdAt/id 排。
///   - 组折叠时子节点不显示，但未完成计数照算（计数是实时算的，不落库）。
///   - 父节点不存在或已删除 → 当一级处理（孤儿上浮，绝不丢数据）。
library;

import 'package:pnote/data/models.dart';

/// 扁平化后的一行：UI 直接按顺序画。
class NodeRow {
  const NodeRow({
    required this.node,
    required this.depth,
    this.unfinished = 0,
    this.sectionBreak = false,
  });

  final TaskState node;

  /// 1 = 一级，2 = 组内。
  final int depth;

  /// 仅组有意义：它下面（含子组的子任务）还有多少条未完成。
  final int unfinished;

  /// 组内「子组在上、任务在下」两段之间的那条细线：画在这一行之前。
  /// 只有组里同时有子组和任务时，第一行任务才会是 true。
  final bool sectionBreak;

  bool get isGroup => node.isGroup;

  String get id => node.id;
}

/// 排序键：order 小的在前，相同则先建的在前，再相同按 id。
/// 与 1.20 的列表排序保持一致，拖拽重排后顺序才稳定。
int compareNodes(TaskState a, TaskState b) {
  final byOrder = a.order.compareTo(b.order);
  if (byOrder != 0) return byOrder;
  final byCreated = a.createdAt.compareTo(b.createdAt);
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

Map<String, TaskState> _aliveById(List<TaskState> nodes) => {
      for (final n in nodes)
        if (!n.isDeleted) n.id: n,
    };

/// 节点的「有效父级」：父节点必须活着、是组，并且层级合法。
///
/// 「最多两级」限制的是**组套组**：组只能挂在一级组下；任务可以挂在任意
/// 合法组下（包括二级组里的任务，比如「学习 › 数学 › 写作业」）。
/// 任何一条不满足都当一级处理 —— 这比报错安全：数据永远不会因为父节点
/// 被删除/被同步覆盖而看不见。
String? effectiveParentOf(TaskState node, Map<String, TaskState> byId) {
  final parentId = node.parentId;
  if (parentId == null) return null;
  final parent = byId[parentId];
  if (parent == null || !parent.isGroup) return null;
  if (node.isGroup) {
    // 组套组：父组自己必须是一级组。
    if (parent.parentId != null) return null;
    return parentId;
  }
  // 任务：父组的层级不能超过两级。
  if (_groupDepth(byId, parent) > 2) return null;
  return parentId;
}

/// 一个组自己的层级（1 = 一级组，2 = 二级组）。只看「组祖先」，不看任务。
int _groupDepth(Map<String, TaskState> byId, TaskState group) {
  var depth = 1;
  var parentId = group.parentId;
  var guard = 0;
  while (parentId != null && guard < 8) {
    final parent = byId[parentId];
    if (parent == null || !parent.isGroup) break;
    depth++;
    parentId = parent.parentId;
    guard++;
  }
  return depth;
}

/// 组下的直接子节点（已按显示顺序排好），含子组与任务。
List<TaskState> childrenOf(List<TaskState> nodes, String? parentId) {
  final byId = _aliveById(nodes);
  final list = nodes
      .where((n) => !n.isDeleted && effectiveParentOf(n, byId) == parentId)
      .toList()
    ..sort(compareNodes);
  return list;
}

/// 同父级的所有可见节点（拖拽重排用）。
List<TaskState> siblingsOf(List<TaskState> nodes, String? parentId) =>
    childrenOf(nodes, parentId);

/// 组的未完成计数：直接子任务 + 子组的子任务（折叠了也算）。
/// 只看任务，不把子组本身算成一条。
Map<String, int> unfinishedCounts(List<TaskState> nodes) {
  final byId = _aliveById(nodes);
  final counts = <String, int>{};
  for (final n in byId.values) {
    if (n.isGroup) counts[n.id] = 0;
  }
  for (final n in byId.values) {
    if (n.isGroup || n.done) continue;
    var parent = effectiveParentOf(n, byId);
    var guard = 0;
    while (parent != null && guard < 8) {
      counts[parent] = (counts[parent] ?? 0) + 1;
      final p = byId[parent];
      if (p == null) break;
      parent = effectiveParentOf(p, byId);
      guard++;
    }
  }
  return counts;
}

/// 把可见节点摊平成「该画的行」。
/// 折叠的组只出现自己这一行，子节点全部跳过。
///
/// [forceExpanded] 里的组即使折叠也展开（1.33 组视图用：进了组就要看到内容，
/// 但组自己的折叠标记不动，回到树里仍按它显示）。
List<NodeRow> flattenTree(
  List<TaskState> nodes, {
  Set<String> forceExpanded = const {},
}) {
  final byId = _aliveById(nodes);
  final counts = unfinishedCounts(nodes);

  final roots = nodes
      .where((n) => !n.isDeleted && effectiveParentOf(n, byId) == null)
      .toList()
    ..sort(compareNodes);

  final rows = <NodeRow>[];

  void addChildren(String parentId, int depth) {
    final kids = nodes
        .where((n) => !n.isDeleted && effectiveParentOf(n, byId) == parentId)
        .toList()
      ..sort(compareNodes);
    final groups = kids.where((n) => n.isGroup).toList();
    final tasks = kids.where((n) => !n.isGroup).toList();
    var firstTask = true;
    for (final n in [...groups, ...tasks]) {
      final breakHere = !n.isGroup && firstTask && groups.isNotEmpty;
      if (!n.isGroup) firstTask = false;
      rows.add(NodeRow(
        node: n,
        depth: depth,
        unfinished: counts[n.id] ?? 0,
        sectionBreak: breakHere,
      ));
      if (n.isGroup && (!n.collapsed || forceExpanded.contains(n.id))) {
        // 二级组里只会有任务（组套组已被数据层拦住），递归是安全的。
        addChildren(n.id, depth + 1);
      }
    }
  }

  for (final root in roots) {
    rows.add(NodeRow(
      node: root,
      depth: 1,
      unfinished: counts[root.id] ?? 0,
    ));
    if (root.isGroup && (!root.collapsed || forceExpanded.contains(root.id))) {
      addChildren(root.id, 2);
    }
  }
  return rows;
}

/// 组视图（1.33）：把某个一级组的内容摊平成行，组自己不占一行。
///
/// 顺序与树里完全一致（先子组后任务、细线保留），只是层级从 1 开始——
/// 相当于「走进了这个组」。组即使折叠着，进视图也能看到内容；子组的
/// 折叠状态照旧生效。组不存在（被删/被同步覆盖）时返回空。
List<NodeRow> groupViewRows(List<TaskState> nodes, String groupId) {
  final rows = flattenTree(nodes, forceExpanded: {groupId});
  final index = rows.indexWhere((r) => r.id == groupId);
  if (index < 0) return const [];
  final baseDepth = rows[index].depth;
  final out = <NodeRow>[];
  for (var i = index + 1; i < rows.length; i++) {
    final row = rows[i];
    if (row.depth <= baseDepth) break;
    out.add(NodeRow(
      node: row.node,
      depth: row.depth - baseDepth,
      unfinished: row.unfinished,
      sectionBreak: row.sectionBreak,
    ));
  }
  return out;
}

/// 某个节点及其全部后代（含组和任务）的 id，用来判断「不能移到自己里面」。
Set<String> descendantIds(List<TaskState> nodes, String id) {
  final byId = _aliveById(nodes);
  final result = <String>{};
  final stack = [id];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    for (final n in byId.values) {
      if (effectiveParentOf(n, byId) == current && result.add(n.id)) {
        stack.add(n.id);
      }
    }
  }
  return result;
}

/// 校验「把 [nodeId] 移到 [newParentId] 下」是否合法。
/// 返回 null 表示可以；返回字符串是给用户看的拒绝原因。
String? validateMove(
  List<TaskState> nodes,
  String nodeId,
  String? newParentId,
) {
  final byId = _aliveById(nodes);
  final node = byId[nodeId];
  if (node == null) return '找不到这一条，可能刚被删掉';

  if (newParentId == null) return null;
  if (newParentId == nodeId) return '不能移到自己里面';

  final parent = byId[newParentId];
  if (parent == null) return '目标分组不存在，可能刚被删掉';
  if (!parent.isGroup) return '只能移到分组里';
  if (parent.parentId != null) return '最多两级，不能放进二级分组里';

  if (descendantIds(nodes, nodeId).contains(newParentId)) {
    return '不能移到自己里面';
  }

  // 组里还套着子组时，整个组不能再往下沉一级。
  if (node.isGroup) {
    final hasChildGroup = nodes.any((n) =>
        !n.isDeleted && n.isGroup && effectiveParentOf(n, byId) == nodeId);
    if (hasChildGroup) return '这个组里还有子组，最多两级；先把子组移出去';
  }
  return null;
}
