part of 'task_dao.dart';

/// 重复任务（1.34）的读写。
///
/// 完成一条重复任务时，在**同一个事务**里做两件事：
///   1. 生成下一期（新的 id、同一个 series_id、时间往后挪一期）；
///   2. 把当前这一期标记为完成。
/// 这样即使中途崩溃也不会出现「下一期有了、这期还没打勾」的半截状态。
extension RepeatOps on TaskDao {
  /// 设置/清除重复规则。规则必须挂在有时间的任务上。
  Future<void> setRepeat(String id, RepeatRule? rule) async {
    final state = await exportState();
    final task = state.tasks[id];
    if (task == null || task.isGroup) return;
    if (rule != null && dueOf(task) == null) {
      throw ArgumentError('先给任务设置时间，再设置重复');
    }
    await _db.transaction((txn) async {
      await _writeField(
        txn,
        id,
        TaskField.repeatRule,
        rule == null ? null : encodeRepeatRule(rule),
      );
      // 第一次设置重复时，把「这一串」的 id 记成任务自己的 id。
      if (rule != null && task.seriesId == null) {
        await _writeField(txn, id, TaskField.seriesId, task.id);
      }
    });
  }

  /// 完成一条任务。非重复任务只打勾；重复任务会顺手生成下一期。
  ///
  /// 返回新生成的任务 id；没有生成（不是重复 / 已到结束条件 / 下一期已存在）
  /// 返回 null。无论有没有生成，当前任务都会被标记为完成。
  Future<String?> completeRepeating(String id) async {
    final state = await exportState();
    final task = state.tasks[id];
    if (task == null || task.done) return null;
    if (task.isGroup) {
      await _markDone(id);
      return null;
    }

    final rule = parseRepeatRule(task.repeatRule);
    final due = dueOf(task);
    final nextDue =
        (rule == null || due == null) ? null : nextDueAfter(due, rule);
    if (rule == null ||
        due == null ||
        nextDue == null ||
        !rule.allows(nextDue)) {
      await _markDone(id);
      return null;
    }

    final advanced = rule.advance();
    final series = task.seriesId ?? task.id;
    final nextId = occurrenceId(series, advanced);
    final precision = DuePrecision.fromCode(task.duePrecision);
    final dueValue = encodeNextDue(nextDue, precision);
    final order = await _appendOrder(_db, task.parentId);
    final createdAt = DateTime.now().millisecondsSinceEpoch;

    var created = false;
    await _db.transaction((txn) async {
      // 同一期可能已经生成过（取消完成再勾一次、或另一台设备生成后同步过来）。
      // id 是确定性的，查一下就知道，不会出现两条一样的。
      final existing = await txn.query(
        'tasks',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [nextId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('tasks', {
          'id': nextId,
          'title': task.title,
          'done': 0,
          'deleted_at': null,
          'created_at': createdAt,
          'order_index': order,
          'parent_id': task.parentId,
          'kind': TaskKind.task.code,
          'color': 0,
          'collapsed': 0,
          'due_value': dueValue,
          'due_precision': precision.code,
          'remind_lead': task.remindLead,
          'repeat_rule': encodeRepeatRule(advanced),
          'series_id': series,
        });
        await _writeField(txn, nextId, TaskField.title, task.title);
        await _writeField(txn, nextId, TaskField.done, 0);
        await _writeField(txn, nextId, TaskField.order, order);
        await _writeField(txn, nextId, TaskField.parent, task.parentId);
        await _writeField(txn, nextId, TaskField.due, dueValue);
        await _writeField(txn, nextId, TaskField.duePrecision, precision.code);
        if (task.remindLead != null) {
          await _writeField(txn, nextId, TaskField.remindLead, task.remindLead);
        }
        await _writeField(
          txn,
          nextId,
          TaskField.repeatRule,
          encodeRepeatRule(advanced),
        );
        await _writeField(txn, nextId, TaskField.seriesId, series);
        created = true;
      }
      await _writeField(txn, id, TaskField.done, 1);
    });
    return created ? nextId : null;
  }

  Future<void> _markDone(String id) async {
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.done, 1);
    });
  }
}
