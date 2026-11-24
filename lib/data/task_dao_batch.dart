part of 'task_dao.dart';

/// 多选批量操作（1.29 新增）。
///
/// 三条底线和单条操作完全一致：一次用户动作 = 一个事务；只写
/// parent/order/deleted_at；每个字段的「值 + 版本 + 时钟」一起写（INV-01）。
///
/// 「同一层次」是硬约束：批量移动、上移/下移都要求选中的节点共享同一个
/// 生效父级，否则拒绝并给中文原因 —— 跨层的批量移动没有唯一合理的落点。
extension BatchOps on TaskDao {
  /// 批量删除（软删除，回收站可恢复）。
  ///
  /// 任务：直接写墓碑。
  /// 分组：按 1.24 的默认规则「内容上移后删空壳」—— 子节点先挂到组原来的
  /// 父级、接在末尾，再删组自己。于是「只选了组」不会连累内容；「组和
  /// 子任务都选了」两条路都进回收站，不会丢数据。
  Future<void> softDeleteMany(List<String> ids) async {
    if (ids.isEmpty) return;
    final all = await visibleTasks();
    final byId = {for (final n in all) n.id: n};
    final targets = <String>[
      for (final id in ids)
        if (byId.containsKey(id)) id,
    ];
    if (targets.isEmpty) return;
    final stamp = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction((txn) async {
      for (final id in targets) {
        final node = byId[id]!;
        if (!node.isGroup) continue;
        var order = await _appendOrder(txn, node.parentId);
        for (final child in childrenOf(all, id)) {
          await _writeField(txn, child.id, TaskField.parent, node.parentId);
          await _writeField(txn, child.id, TaskField.order, order);
          order += kOrderStep;
        }
      }
      for (final id in targets) {
        await _writeField(txn, id, TaskField.deletedAt, stamp);
      }
    });
  }

  /// 批量移入 [parentId]（null = 顶层）。选中的节点必须同层，按当前顺序
  /// 依次追加到目标末尾。
  Future<void> moveManyToParent(List<String> ids, String? parentId) async {
    if (ids.isEmpty) return;
    final all = await visibleTasks();
    final byId = {for (final n in all) n.id: n};
    final nodes = <TaskState>[
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
    if (nodes.isEmpty) return;

    final parent = nodes.first.parentId == null
        ? null
        : effectiveParentOf(nodes.first, byId);
    for (final node in nodes) {
      final p = node.parentId == null ? null : effectiveParentOf(node, byId);
      if (p != parent) {
        throw ArgumentError('多选只能在同一个层次内移动');
      }
    }
    for (final node in nodes) {
      final reason = validateMove(all, node.id, parentId);
      if (reason != null) throw ArgumentError(reason);
    }
    if (parent == parentId) return; // 原地不动，不写版本

    // 按当前显示顺序搬，保持相对次序。
    nodes.sort((a, b) => compareNodes(a, b));
    await _db.transaction((txn) async {
      var order = await _appendOrder(txn, parentId);
      for (final node in nodes) {
        await _writeField(txn, node.id, TaskField.parent, parentId);
        await _writeField(txn, node.id, TaskField.order, order);
        order += kOrderStep;
      }
    });
  }

  /// 同层内批量上移/下移一位（[delta] = -1 / +1）。
  ///
  /// 先把选中块整体挪一格；选中的兄弟保持原有相对顺序，不会互相穿过。
  Future<void> nudgeMany(List<String> ids, int delta) async {
    if (ids.isEmpty || (delta != -1 && delta != 1)) return;
    final all = await visibleTasks();
    final byId = {for (final n in all) n.id: n};
    final selected = <String>{
      for (final id in ids)
        if (byId.containsKey(id)) id,
    };
    if (selected.isEmpty) return;

    final first = byId[selected.first]!;
    final parent = first.parentId == null ? null : effectiveParentOf(first, byId);
    final siblings = siblingsOf(all, parent);
    for (final id in selected) {
      final node = byId[id];
      if (node == null) continue;
      final p = node.parentId == null ? null : effectiveParentOf(node, byId);
      if (p != parent) throw ArgumentError('多选只能在同一个层次内移动');
    }

    final order = [for (final n in siblings) n.id];
    final indexes = [
      for (var i = 0; i < order.length; i++)
        if (selected.contains(order[i])) i,
    ];

    if (delta < 0) {
      // 从上往下：上面那个没被选中才换。
      for (final i in indexes) {
        if (i == 0) continue;
        if (selected.contains(order[i - 1])) continue;
        final tmp = order[i - 1];
        order[i - 1] = order[i];
        order[i] = tmp;
      }
    } else {
      // 从下往上，避免刚换过的又被换回去。
      for (final i in indexes.reversed) {
        if (i == order.length - 1) continue;
        if (selected.contains(order[i + 1])) continue;
        final tmp = order[i + 1];
        order[i + 1] = order[i];
        order[i] = tmp;
      }
    }

    await _db.transaction((txn) async {
      for (var i = 0; i < order.length; i++) {
        final node = byId[order[i]];
        if (node == null) continue;
        final wanted = (i + 1) * kOrderStep;
        if (node.order == wanted) continue;
        await _writeField(txn, order[i], TaskField.order, wanted);
      }
    });
  }

  /// 批量恢复（回收站「全部恢复」/ 多选恢复）。
  ///
  /// 先恢复分组（一级在前、二级在后），再恢复任务：同一批里的子任务能
  /// 认回刚恢复的父组，不会因为「恢复瞬间父组还是删着的」被甩到顶层。
  /// 父组不在本批、或父组本身不合法（二级组想挂组），才退回顶层。
  Future<void> restoreMany(Iterable<String> ids) async {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return;
    final state = await exportState();
    final alive = <String, TaskState>{
      for (final n in state.tasks.values)
        if (!n.isDeleted) n.id: n,
    };
    final targets = <TaskState>[
      for (final id in wanted)
        if (state.tasks[id]?.isDeleted ?? false) state.tasks[id]!,
    ];
    if (targets.isEmpty) return;

    int depthOf(TaskState group) {
      var depth = 1;
      var cur = group;
      while (cur.parentId != null) {
        final parent = state.tasks[cur.parentId];
        if (parent == null) break;
        depth++;
        cur = parent;
      }
      return depth;
    }

    targets.sort((a, b) {
      final ra = a.isGroup ? depthOf(a) : 100;
      final rb = b.isGroup ? depthOf(b) : 100;
      if (ra != rb) return ra.compareTo(rb);
      return compareNodes(a, b);
    });

    await _db.transaction((txn) async {
      for (final node in targets) {
        final parentId = node.parentId;
        final parent = parentId == null ? null : alive[parentId];
        final parentOk = parentId == null ||
            (parent != null &&
                parent.isGroup &&
                (!node.isGroup || parent.parentId == null));
        if (!parentOk) {
          final order = await _appendOrder(txn, null);
          await _writeField(txn, node.id, TaskField.parent, null);
          await _writeField(txn, node.id, TaskField.order, order);
        }
        await _writeField(txn, node.id, TaskField.deletedAt, null);
        alive[node.id] = node;
      }
    });
  }

  /// 当前所有「已完成、未删除」的任务 id（1.36）。
  ///
  /// 只算任务不算组：组的 done 恒为 0，混进来会把组也当成完成项。
  /// 顺序与列表一致（order → createdAt → id），删除时的提示数与列表看到的一致。
  Future<List<String>> completedTaskIds() async {
    final rows = await _db.query(
      'tasks',
      columns: ['id'],
      where: 'deleted_at IS NULL AND done = 1 AND kind = 0',
      orderBy: 'order_index, created_at, id',
    );
    return [for (final row in rows) row['id'] as String];
  }
}
