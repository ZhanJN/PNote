part of 'task_dao.dart';

/// 时间系统（1.31）的写操作。
///
/// 为什么单独一个 part：时间字段一共五个，但真正落库的逻辑只有「值 + 精度
/// 必须一起改」这一条。放在同一个事务里，两台设备同步时不会出现
/// 「有值但精度是 0」这种半截状态。
extension TimeOps on TaskDao {
  /// 设置任务时间。[at] 为 null 或 [precision] 为 none 时等于清空时间。
  ///
  /// 只改 due / due_precision 两个字段，**不清空标题、日期以外的任何东西**；
  /// 改精度也只改标记，保留值（见项目说明 7.16）。
  Future<void> setDue(
    String id, {
    DateTime? at,
    DuePrecision precision = DuePrecision.none,
  }) async {
    if (at == null || precision == DuePrecision.none) {
      await _db.transaction((txn) async {
        await _writeField(txn, id, TaskField.due, null);
        await _writeField(txn, id, TaskField.duePrecision, DuePrecision.none.code);
        // 1.34：没有时间的任务不能重复。清时间时一起清规则，避免
        // 「有重复规则却不知道该从哪天算下一期」的半截状态。
        await _writeField(txn, id, TaskField.repeatRule, null);
      });
      return;
    }
    final value = precision == DuePrecision.date
        ? encodeDueDate(at)
        : encodeDueDateTime(at);
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.due, value);
      await _writeField(txn, id, TaskField.duePrecision, precision.code);
    });
  }

  /// 清空时间。与 [setDue] 传 null 等价，单独留一个名字给 UI 用。
  Future<void> clearDue(String id) => setDue(id);

  /// 提前提醒分钟数；null 表示跟随（组级 → 全局）默认。提醒本身下一阶段做。
  Future<void> setRemindLead(String id, int? minutes) async {
    await _db.transaction(
      (txn) => _writeField(txn, id, TaskField.remindLead, minutes),
    );
  }

  /// 重复规则原文；null 表示不重复。重复任务本身下一阶段做。
  Future<void> setRepeatRule(String id, String? rule) async {
    await _db.transaction(
      (txn) => _writeField(txn, id, TaskField.repeatRule, rule),
    );
  }
}
