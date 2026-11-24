/// 任务读写（DAO）。所有 SQL 只出现在本文件（分组相关的方法在同库的
/// task_dao_groups.dart 里，用 part 拆开只为控制单文件长度）。
///
/// 关键约定（违反即为缺陷）：
///   INV-01 字段值与它的版本必须在同一事务内写入；时钟状态也在同一事务里落库。
///   INV-02 删除只写 deleted_at 墓碑，绝不 DELETE 行。
library;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/merge.dart';
import 'package:pnote/data/due_time.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/data/repeat.dart';
import 'package:pnote/data/tree.dart';

part 'task_dao_groups.dart';
part 'task_dao_batch.dart';
part 'task_dao_time.dart';
part 'task_dao_repeat.dart';

const String _kMetaDeviceId = 'device_id';
const String _kMetaHlcMs = 'hlc_ms';
const String _kMetaHlcC = 'hlc_counter';

/// 手动排序的步长（1.20）。新任务排在最后 = 当前最大 order + 这个值；
/// 重排时按 1..n 乘以它编号，留出足够间隔，避免浮点插值耗尽精度。
const double kOrderStep = 1024;

class TaskDao {
  TaskDao._(this._db, this.clock);

  final Database _db;

  /// 时钟由 DAO 拥有：任何字段写入都必须经过它，避免有人偷偷用 DateTime.now()。
  final HlcClock clock;

  /// 打开后用一次：读取 meta，得到设备 ID 与上次的时钟，避免重启后版本回退。
  static Future<TaskDao> attach(Database db, {DateTime Function()? now}) async {
    final rows = await db.query('meta');
    final meta = <String, String>{
      for (final r in rows) r['key'] as String: r['value'] as String,
    };

    var deviceId = meta[_kMetaDeviceId];
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await db.insert(
        'meta',
        {'key': _kMetaDeviceId, 'value': deviceId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final dao = TaskDao._(
      db,
      HlcClock(
        deviceId: deviceId,
        lastMs: int.tryParse(meta[_kMetaHlcMs] ?? '') ?? 0,
        lastC: int.tryParse(meta[_kMetaHlcC] ?? '') ?? 0,
        now: now,
      ),
    );
    return dao;
  }

  // ---------------------------------------------------------------- 设置项

  /// 读一个通用设置（存在 meta 表里，和设备 ID、时钟状态同表）。
  /// 没有这一项返回 null —— 调用方负责给默认值。
  ///
  /// 这类键值**不参与同步**：主题是本机偏好，不该跟着数据跑到别的设备上。
  Future<String?> readSetting(String key) async {
    final rows = await _db.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// 写一个通用设置（覆盖同名键）。
  Future<void> writeSetting(String key, String value) async {
    await _db.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------------------------------------------------------- 读取

  /// 界面上要显示的列表：未删除，按手动顺序，其次创建时间。
  /// 1.20 起主排序键是 order（拖拽可改）；order 相同时用 created_at、id 兜底，
  /// 保证任意两端排出来的顺序一致（order 相同是可能的：LWW 冲突或老数据）。
  /// 1.24 起结果里既有任务也有组，父子关系由 `parentId` 表示。
  Future<List<TaskState>> visibleTasks() async {
    final rows = await _db.query(
      'tasks',
      where: 'deleted_at IS NULL',
      orderBy: 'order_index ASC, created_at ASC, id ASC',
    );
    final versions = await _loadVersions();
    return [
      for (final row in rows)
        _taskFromRow(
          row,
          versions[row['id'] as String] ?? const <TaskField, FieldValue>{},
        ),
    ];
  }

  /// 回收站里的列表：已软删除的任务/组，最近删的排前面。
  Future<List<TaskState>> deletedTasks() async {
    final rows = await _db.query(
      'tasks',
      where: 'deleted_at IS NOT NULL',
      orderBy: 'deleted_at DESC, id ASC',
    );
    final versions = await _loadVersions();
    return [
      for (final row in rows)
        _taskFromRow(
          row,
          versions[row['id'] as String] ?? const <TaskField, FieldValue>{},
        ),
    ];
  }

  /// 打包成同步用的全量状态（阶段 3 直接发这个）。
  Future<SyncState> exportState({String deviceName = '本机'}) async {
    final rows = await _db.query('tasks');
    final versions = await _loadVersions();
    final tasks = <String, TaskState>{};
    for (final row in rows) {
      final id = row['id'] as String;
      tasks[id] = _taskFromRow(
        row,
        versions[id] ?? const <TaskField, FieldValue>{},
      );
    }
    final purgedRows = await _db.query(
      'purged',
      columns: ['id', 'hlc_ms', 'hlc_c', 'device_id'],
    );
    return SyncState(
      deviceId: clock.deviceId,
      deviceName: deviceName,
      tasks: tasks,
      purged: {
        for (final row in purgedRows)
          row['id'] as String: Hlc(
            row['hlc_ms'] as int,
            row['hlc_c'] as int,
            row['device_id'] as String,
          ),
      },
    );
  }

  Future<Map<String, Map<TaskField, FieldValue>>> _loadVersions() async {
    // 值存在 tasks 表（列），版本存在 field_versions 表（行），这里一次 JOIN 取齐。
    final rows = await _db.rawQuery('''
      SELECT f.task_id, f.field, f.hlc_ms, f.hlc_c, f.device_id,
             t.title AS v_title, t.done AS v_done, t.deleted_at AS v_deleted_at,
             t.order_index AS v_order, t.parent_id AS v_parent,
             t.collapsed AS v_collapsed, t.color AS v_color,
             t.due_value AS v_due, t.due_precision AS v_due_precision,
             t.remind_lead AS v_remind, t.repeat_rule AS v_repeat,
             t.series_id AS v_series
      FROM field_versions f
      JOIN tasks t ON t.id = f.task_id
    ''');
    final out = <String, Map<TaskField, FieldValue>>{};
    for (final row in rows) {
      final taskId = row['task_id'] as String;
      final field = TaskField.fromWire(row['field'] as String);
      final Object? value = switch (field) {
        TaskField.title => row['v_title'],
        TaskField.done => row['v_done'],
        TaskField.deletedAt => row['v_deleted_at'],
        TaskField.order => row['v_order'],
        TaskField.parent => row['v_parent'],
        TaskField.collapsed => row['v_collapsed'],
        TaskField.color => row['v_color'],
        TaskField.due => row['v_due'],
        TaskField.duePrecision => row['v_due_precision'],
        TaskField.remindLead => row['v_remind'],
        TaskField.repeatRule => row['v_repeat'],
        TaskField.seriesId => row['v_series'],
      };
      out.putIfAbsent(taskId, () => {})[field] = FieldValue(
        value,
        Hlc(
          row['hlc_ms'] as int,
          row['hlc_c'] as int,
          row['device_id'] as String,
        ),
      );
    }
    return out;
  }

  TaskState _taskFromRow(
    Map<String, Object?> row,
    Map<TaskField, FieldValue> versions,
  ) {
    return TaskState(
      id: row['id'] as String,
      createdAt: row['created_at'] as int,
      fields: versions,
      kind: TaskKind.fromCode((row['kind'] as int?) ?? 0),
    );
  }

  // ---------------------------------------------------------------- 写入

  /// 新建一条任务。1.24 起可以指定挂在哪个组下（[parentId] 为 null 即一级）。
  Future<String> addTask(String title, {String? parentId}) =>
      _insertNode(title: title, kind: TaskKind.task, parentId: parentId);

  Future<String> _insertNode({
    required String title,
    required TaskKind kind,
    String? parentId,
    int color = 0,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError(kind == TaskKind.group ? '组名不能为空' : '标题不能为空');
    }
    final id = const Uuid().v4();
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    // 新节点排到同级的最后：取同父级当前最大 order 加一个间隔，留出插值空间。
    final order = await _appendOrder(_db, parentId);

    await _db.transaction((txn) async {
      await txn.insert('tasks', {
        'id': id,
        'title': trimmed,
        'done': 0,
        'deleted_at': null,
        'created_at': createdAt,
        'order_index': order,
        'parent_id': parentId,
        'kind': kind.code,
        'color': color,
        'collapsed': 0,
      });
      // 字段都写上版本，这样对方「首次见到」时数据是完整的。
      await _writeField(txn, id, TaskField.title, trimmed);
      await _writeField(txn, id, TaskField.done, 0);
      await _writeField(txn, id, TaskField.order, order);
      await _writeField(txn, id, TaskField.parent, parentId);
      if (kind == TaskKind.group) {
        await _writeField(txn, id, TaskField.collapsed, 0);
        await _writeField(txn, id, TaskField.color, color);
      }
    });
    return id;
  }

  /// 取同父级（[parentId] 为 null 即一级）当前最大 order + 一步。
  /// 用 `IS ?` 而不是 `= ?`，这样 NULL 也能比较。
  Future<double> _appendOrder(DatabaseExecutor ex, String? parentId) async {
    final maxRow = await ex.rawQuery(
      'SELECT MAX(order_index) AS m FROM tasks '
      'WHERE deleted_at IS NULL AND parent_id IS ?',
      [parentId],
    );
    final maxOrder = (maxRow.first['m'] as num?)?.toDouble() ?? 0;
    return maxOrder + kOrderStep;
  }

  /// 把某个节点挪到「同父级列表」的第 [index] 位（0 起，拖拽排序用）。
  ///
  /// 为什么整段重排而不是只写一条：两点之间反复插值会把 double 的间隔耗尽
  /// （1e-15 之后就没有中间值了）。这里直接把同级列表按 [kOrderStep] 重新
  /// 编号，只给**顺序真的变了**的节点写新版本，避免无谓的同步流量。
  /// 全部写在同一个事务里：要么整体生效，要么一条都不动。
  Future<void> moveTaskToIndex(String id, int index) async {
    final all = await visibleTasks();
    final byId = {for (final n in all) n.id: n};
    final node = byId[id];
    if (node == null) return;
    final parentId = effectiveParentOf(node, byId);
    final siblings = siblingsOf(all, parentId);
    final from = siblings.indexWhere((t) => t.id == id);
    if (from < 0) return;
    final to = index.clamp(0, siblings.length - 1);
    if (from == to) return;

    final reordered = [...siblings]..removeAt(from);
    reordered.insert(to, siblings[from]);

    await _db.transaction((txn) async {
      for (var i = 0; i < reordered.length; i++) {
        final task = reordered[i];
        final wanted = (i + 1) * kOrderStep;
        if (task.order == wanted) continue; // 位置没变，不写版本
        await _writeField(txn, task.id, TaskField.order, wanted);
      }
    });
  }

  Future<void> renameTask(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw ArgumentError('名字不能为空');
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.title, trimmed);
    });
  }

  /// 勾选/取消勾选。1.34 起：勾选一条重复任务会顺手生成下一期
  /// （同一事务，见 task_dao_repeat.dart）；取消勾选不会删掉已生成的下一期。
  Future<void> setDone(String id, bool done) async {
    if (done) {
      await completeRepeating(id);
      return;
    }
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.done, 0);
    });
  }

  /// 软删除：写墓碑，不删行。值用当前毫秒，便于界面/排查显示「何时删的」。
  Future<void> softDelete(String id) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await _writeField(txn, id, TaskField.deletedAt, stamp);
    });
  }

  /// 从回收站恢复：把 deleted_at 写成一个「值为 null 的新版本」。
  /// null 也是一个正常的字段值，所以它照样有 HLC，能正常参与合并。
  ///
  /// 1.24：如果它原来的父组已经被删/不存在，就顺手挪回一级（否则恢复出来
  /// 也是孤儿，看不见）。孤儿上浮的规则见 tree.dart。
  /// 1.30：单条与批量共用 restoreMany —— 恢复一组父子时先父后子，不会把
  /// 子任务甩到顶层。
  Future<void> restoreTask(String id) => restoreMany([id]);

  /// 永久删除（只在回收站里由用户手动触发）：物理删行 + 记一条**带版本**的
  /// 清除记录。它会随同步发出去，让另一台设备也删掉；但因为它带 HLC，
  /// 之后任何更新的恢复/编辑（比如导入备份）都能压过它，见项目说明 7.10。
  Future<int> purgeTasks(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return 0;
    var removed = 0;
    await _db.transaction((txn) async {
      for (final id in list) {
        final hlc = clock.send();
        removed += await txn.delete('tasks', where: 'id = ?', whereArgs: [id]);
        await txn.insert(
          'purged',
          {
            'id': id,
            'hlc_ms': hlc.ms,
            'hlc_c': hlc.c,
            'device_id': hlc.deviceId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _persistClock(txn);
    });
    return removed;
  }

  /// 应用一次合并结果：把合并后的状态整体写回本地。
  /// 返回以本地为基准的统计（供阶段 3 的提示文案使用）。
  Future<MergeStats> applyRemote(SyncState remote) async {
    final local = await exportState(deviceName: '本机');
    final maxRemote = maxHlcOf(local, remote);
    if (maxRemote != null) {
      // 先推进时钟，保证本机之后产生的事件大于看到的任何远端版本。
      clock.receive(maxRemote);
    }
    final outcome = mergeStates(local, remote);

    await _db.transaction((txn) async {
      for (final task in outcome.merged.tasks.values) {
        await txn.insert(
          'tasks',
          {
            'id': task.id,
            'title': task.title,
            'done': task.done ? 1 : 0,
            'deleted_at': task.deletedAt,
            'created_at': task.createdAt,
            'order_index': task.order,
            'parent_id': task.parentId,
            'kind': task.kind.code,
            'color': task.color,
            'collapsed': task.collapsed ? 1 : 0,
            'due_value': task.dueValue,
            'due_precision': task.duePrecision,
            'remind_lead': task.remindLead,
            'repeat_rule': task.repeatRule,
            'series_id': task.seriesId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        for (final entry in task.fields.entries) {
          await txn.insert(
            'field_versions',
            {
              'task_id': task.id,
              'field': entry.key.wireName,
              'hlc_ms': entry.value.hlc.ms,
              'hlc_c': entry.value.hlc.c,
              'device_id': entry.value.hlc.deviceId,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await _persistClock(txn);
    });

    // 合并结果里的清除记录才是权威：写进去，并把「已被更新的恢复/编辑压过」
    // 的那些清除记录从本地删掉（否则下一轮同步又会把任务清掉）。
    final effective = outcome.merged.purged;
    await _db.transaction((txn) async {
      final rows = await txn.query('purged', columns: ['id']);
      for (final row in rows) {
        final id = row['id'] as String;
        if (!effective.containsKey(id)) {
          await txn.delete('purged', where: 'id = ?', whereArgs: [id]);
        }
      }
      for (final entry in effective.entries) {
        await txn.delete('tasks', where: 'id = ?', whereArgs: [entry.key]);
        await txn.insert(
          'purged',
          {
            'id': entry.key,
            'hlc_ms': entry.value.ms,
            'hlc_c': entry.value.c,
            'device_id': entry.value.deviceId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });

    return outcome.stats;
  }

  /// 导入一份备份：把备份里的内容**当成用户的一次恢复动作**写回本机。
  ///
  /// 为什么不能只用 [applyRemote]：墓碑（deleted_at）和永久删除（purged）都是
  /// 带版本的记录，而且通常比备份里的标题/勾选**更晚**，所以纯合并在
  /// 「删光之后再导入」时会一条都不变（表现就是「没有发现新内容」）。
  /// 可备份是用户手里唯一的一份数据，导入应当把它还原出来。
  ///
  /// 做法：
  ///   - 备份里看得见、本机只是被软删除的 → 把 deleted_at 写成 null（新版本）。
  ///   - 备份里看得见、本机已永久删除（行都没了）→ 用**新版本号**把任务重新
  ///     插回去，并删掉那条清除记录。因为新版本比清除记录更新，下一轮同步时
  ///     另一台也会跟着恢复（清除记录被判定为作废）。
  ///   - 备份里本来就是删除状态的任务 → 不动（尊重备份里的墓碑）。
  Future<ImportOutcome> importBundle(SyncState bundle) async {
    final merge = await applyRemote(bundle);

    var restored = 0;
    var revived = 0;
    for (final task in bundle.tasks.values) {
      if (task.isDeleted) continue; // 备份里就是删掉的，不复活

      final rows = await _db.query(
        'tasks',
        columns: ['deleted_at'],
        where: 'id = ?',
        whereArgs: [task.id],
        limit: 1,
      );

      if (rows.isEmpty) {
        // 行已经不在了：只可能是被永久删除过。用新版本号重新插回去。
        await _db.transaction((txn) async {
          await txn.delete('purged', where: 'id = ?', whereArgs: [task.id]);
          await _insertWithFreshVersions(txn, task);
        });
        revived++;
        continue;
      }
      if (rows.first['deleted_at'] == null) continue; // 本来就看得见

      await _db.transaction(
        (txn) => _writeField(txn, task.id, TaskField.deletedAt, null),
      );
      restored++;
    }

    return ImportOutcome(
      merge: merge,
      restored: restored,
      revived: revived,
    );
  }

  /// 用当前时钟重新给任务盖一遍版本号再插回去（导入恢复专用）。
  Future<void> _insertWithFreshVersions(
    DatabaseExecutor txn,
    TaskState source,
  ) async {
    final fields = <TaskField, FieldValue>{};
    for (final entry in source.fields.entries) {
      if (entry.key == TaskField.deletedAt) continue; // 恢复：不带墓碑
      fields[entry.key] = FieldValue(entry.value.value, clock.send());
    }
    if (!fields.containsKey(TaskField.done)) {
      fields[TaskField.done] = FieldValue(0, clock.send());
    }
    await txn.insert(
      'tasks',
      {
        'id': source.id,
        'title': (fields[TaskField.title]?.value as String?) ?? source.title,
        'done': (fields[TaskField.done]?.value as int?) ?? 0,
        'deleted_at': null,
        'created_at': source.createdAt,
        'order_index':
            (fields[TaskField.order]?.value as num?)?.toDouble() ??
                source.order,
        'parent_id': source.parentId,
        'kind': source.kind.code,
        'color': source.color,
        'collapsed': source.collapsed ? 1 : 0,
        'due_value': source.dueValue,
        'due_precision': source.duePrecision,
        'remind_lead': source.remindLead,
        'repeat_rule': source.repeatRule,
        'series_id': source.seriesId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    for (final entry in fields.entries) {
      await txn.insert(
        'field_versions',
        {
          'task_id': source.id,
          'field': entry.key.wireName,
          'hlc_ms': entry.value.hlc.ms,
          'hlc_c': entry.value.hlc.c,
          'device_id': entry.value.hlc.deviceId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await _persistClock(txn);
  }

  // ---------------------------------------------------------------- 内部

  Future<void> _writeField(
    DatabaseExecutor txn,
    String taskId,
    TaskField field,
    Object? value,
  ) async {
    final hlc = clock.send();
    final column = _columnOf(field);
    final updated = await txn.rawUpdate(
      'UPDATE tasks SET $column = ? WHERE id = ?',
      [value, taskId],
    );
    if (updated == 0) {
      throw StateError('任务不存在：$taskId');
    }
    await txn.insert(
      'field_versions',
      {
        'task_id': taskId,
        'field': field.wireName,
        'hlc_ms': hlc.ms,
        'hlc_c': hlc.c,
        'device_id': hlc.deviceId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _persistClock(txn);
  }

  /// 把内存里推进过的时钟写回 meta 表。
  ///
  /// 任务写库时由各自的写事务顺带调用；笔记同步（1.47）不是数据库事务，
  /// 所以需要一个单独入口，免得两种数据用两个不同的时钟。
  Future<void> persistClock() => _persistClock(_db);

  Future<void> _persistClock(DatabaseExecutor txn) async {
    await txn.insert(
      'meta',
      {'key': _kMetaHlcMs, 'value': '${clock.lastMs}'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await txn.insert(
      'meta',
      {'key': _kMetaHlcC, 'value': '${clock.lastC}'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

/// 字段名 → tasks 表的列名（唯一映射处，别在别处再写一份）。
String _columnOf(TaskField field) => switch (field) {
      TaskField.title => 'title',
      TaskField.done => 'done',
      TaskField.deletedAt => 'deleted_at',
      TaskField.order => 'order_index',
      TaskField.parent => 'parent_id',
      TaskField.collapsed => 'collapsed',
      TaskField.color => 'color',
      TaskField.due => 'due_value',
      TaskField.duePrecision => 'due_precision',
      TaskField.remindLead => 'remind_lead',
      TaskField.repeatRule => 'repeat_rule',
      TaskField.seriesId => 'series_id',
    };

/// 一次导入的结果：合并统计 + 从回收站里救回来几条 + 从永久删除里复活几条。
class ImportOutcome {
  const ImportOutcome({
    required this.merge,
    required this.restored,
    required this.revived,
  });

  final MergeStats merge;

  /// 本机只是软删除、被这次导入恢复的任务数。
  final int restored;

  /// 本机已永久删除（行都没了）、被这次导入重新插回来的任务数。
  final int revived;

  /// 真的什么都没变（合并无变化、也没救回任何任务）。
  bool get isNoop => merge.isNoop && restored == 0 && revived == 0;

  /// 给用户看的一句话。有内容时把"恢复"放前面，因为那是最容易被忽略的。
  String describe() {
    final recovered = restored + revived;
    final parts = <String>[
      if (recovered > 0) '恢复 $recovered',
      if (merge.addedTasks > 0) '新增 ${merge.addedTasks}',
      if (merge.updatedFields > 0) '更新 ${merge.updatedFields}',
      if (merge.deletedTasks > 0) '删除 ${merge.deletedTasks}',
    ];
    return parts.isEmpty ? '没有发现新内容' : parts.join(' · ');
  }
}
