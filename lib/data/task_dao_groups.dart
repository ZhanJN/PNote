part of 'task_dao.dart';

/// 分组（两级）的写操作。1.24 新增。
///
/// 为什么写成 extension 而不是直接塞进 [TaskDao]：Dart 没有「partial class」，
/// 拆文件只能靠 part + extension/mixin。extension 在同库里可以访问私有成员，
/// 所以既能复用 `_writeField`（保证「值 + 版本 + 时钟」在同一事务里，INV-01），
/// 又不必把 500 多行的 DAO 再撑大。
///
/// 每个方法都遵守两条底线：
///   - 一次用户操作 = 一个事务（要么全成，要么全不动）。
///   - 只改 parent/order/deleted_at 这些字段，**不清空日期、不碰标题**。
extension GroupOps on TaskDao {
  /// 新建一个组。[parentId] 非空时是二级组（父必须是一级组）。
  Future<String> addGroup(
    String title, {
    String? parentId,
    int color = 0,
  }) async {
    if (parentId != null) {
      final all = await visibleTasks();
      final parents = all.where((n) => n.id == parentId).toList();
      if (parents.isEmpty || !parents.first.isGroup) {
        throw ArgumentError('目标不是分组');
      }
      if (parents.first.parentId != null) {
        throw ArgumentError('最多两级，不能在二级分组里再建');
      }
    }
    return _insertNode(
      title: title,
      kind: TaskKind.group,
      parentId: parentId,
      color: color.clamp(0, 7),
    );
  }

  /// 折叠/展开一个组。折叠状态是同步字段（见 models.dart 的 TaskField.collapsed）。
  Future<void> setGroupCollapsed(String id, bool collapsed) async {
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.collapsed, collapsed ? 1 : 0);
    });
  }

  /// 换组颜色（0-7，调色板下标）。
  Future<void> setGroupColor(String id, int color) async {
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.color, color.clamp(0, 7));
    });
  }

  /// 把节点（任务或组）移到 [parentId] 下；null = 移到顶层。
  ///
  /// 只改父节点和顺序：日期、勾选状态、子节点都原样跟着走
  /// （「整组连内容搬」）。非法移动会抛 [ArgumentError]，消息可直接给用户看。
  Future<void> moveToParent(String id, String? parentId) async {
    final all = await visibleTasks();
    final reason = validateMove(all, id, parentId);
    if (reason != null) throw ArgumentError(reason);

    final byId = {for (final n in all) n.id: n};
    final node = byId[id]!;
    if (effectiveParentOf(node, byId) == parentId) return; // 没动，不写版本

    // 排到新同级的末尾。
    final order = await _appendOrder(_db, parentId);
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.parent, parentId);
      await _writeField(txn, id, TaskField.order, order);
    });
  }

  /// 同一父级内按给定顺序重排（拖拽用）。只给顺序真的变了的节点写版本。
  Future<void> reorderSiblings(List<String> orderedIds) async {
    if (orderedIds.length < 2) return;
    final all = await visibleTasks();
    final byId = {for (final n in all) n.id: n};
    if (!byId.containsKey(orderedIds.first)) return;

    await _db.transaction((txn) async {
      for (var i = 0; i < orderedIds.length; i++) {
        final node = byId[orderedIds[i]];
        if (node == null) continue;
        final wanted = (i + 1) * kOrderStep;
        if (node.order == wanted) continue;
        await _writeField(txn, orderedIds[i], TaskField.order, wanted);
      }
    });
  }

  /// 删除一个组。
  ///
  /// [cascade] 为 false（默认）：先把组里还活着的内容整体上移到组原来的位置
  /// （保留各自顺序），再给组写墓碑 —— 也就是「内容上移后删空壳」，不会连累
  /// 你自己的任务。
  /// [cascade] 为 true：组和它下面所有内容一起进回收站（逐个写墓碑）。
  ///
  /// 两种情况都是软删除，回收站里都能恢复。
  Future<void> deleteGroup(String id, {bool cascade = false}) async {
    final all = await visibleTasks();
    final byId = {for (final n in all) n.id: n};
    final group = byId[id];
    if (group == null || !group.isGroup) {
      throw ArgumentError('要删除的不是分组');
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction((txn) async {
      if (cascade) {
        // 先删子孙（深的先删），最后删组自己。
        final ids = descendantIds(all, id).toList()
          ..sort((a, b) => _depthOf(byId, b).compareTo(_depthOf(byId, a)));
        for (final childId in ids) {
          await _writeField(txn, childId, TaskField.deletedAt, stamp);
        }
      } else {
        // 内容上移：顺序沿用它们在组里的顺序，接在目标父级末尾。
        var order = await _appendOrder(txn, group.parentId);
        for (final child in childrenOf(all, id)) {
          await _writeField(txn, child.id, TaskField.parent, group.parentId);
          await _writeField(txn, child.id, TaskField.order, order);
          order += kOrderStep;
        }
      }
      await _writeField(txn, id, TaskField.deletedAt, stamp);
    });
  }

  /// 从根到该节点的层数（1 = 一级）。只用于删除时确定「先删深的」。
  int _depthOf(Map<String, TaskState> byId, String id) {
    var depth = 1;
    var current = byId[id];
    var guard = 0;
    while (current != null && guard < 8) {
      final parentId = current.parentId;
      if (parentId == null) break;
      current = byId[parentId];
      depth++;
      guard++;
    }
    return depth;
  }
}
