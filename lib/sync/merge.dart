/// 合并算法：把「本地全量状态」与「远端全量状态」合成一份新状态。
///
/// 这是本项目唯一需要「动脑」的纯函数，规则见《PNote项目说明》7.3。
/// 三条不变量（由 test/merge_test.dart 强制）：
///   INV-03 只用 (ms, c, deviceId) 全序判定胜负，函数内不读时钟、不读数据库。
///   NFR-01 幂等：再次合并同一远端，结果不变、统计全为 0。
///   NFR-02 交换律：merge(a,b) 与 merge(b,a) 得到的数据完全一致。
library;

import 'package:pnote/data/models.dart';
import 'package:pnote/sync/hlc.dart';

/// 一次合并的统计，用于界面上那行「新增 2 · 更新 1 · 删除 1」。
class MergeStats {
  const MergeStats({
    this.addedTasks = 0,
    this.updatedFields = 0,
    this.deletedTasks = 0,
    this.unchangedTasks = 0,
    this.remoteOnlyTasks = 0,
  });

  final int addedTasks;
  final int updatedFields;
  final int deletedTasks;
  final int unchangedTasks;

  /// 远端独有、且被判定为已删除的任务数量（只统计，不显示）。
  final int remoteOnlyTasks;

  bool get isNoop => addedTasks == 0 && updatedFields == 0 && deletedTasks == 0;

  MergeStats operator +(MergeStats o) => MergeStats(
        addedTasks: addedTasks + o.addedTasks,
        updatedFields: updatedFields + o.updatedFields,
        deletedTasks: deletedTasks + o.deletedTasks,
        unchangedTasks: unchangedTasks + o.unchangedTasks,
        remoteOnlyTasks: remoteOnlyTasks + o.remoteOnlyTasks,
      );

  Map<String, Object?> toJson() => {
        'addedTasks': addedTasks,
        'updatedFields': updatedFields,
        'deletedTasks': deletedTasks,
        'unchangedTasks': unchangedTasks,
      };

  @override
  String toString() =>
      '新增 $addedTasks · 更新 $updatedFields · 删除 $deletedTasks';
}

class MergeOutcome {
  const MergeOutcome({required this.merged, required this.stats});

  /// 合并后的全量状态（字段值取自胜者）。
  final SyncState merged;

  /// 以「本地」为基准的统计。
  final MergeStats stats;
}

/// 合并两个全量状态。
///
/// 规则（对每个任务、每个字段独立执行）：
///   1. 两侧都有该字段 → 取 HLC 较大者的值；HLC 完全相同由 deviceId 决出。
///   2. 只有一侧有该字段 → 直接取该侧（这是「新增」或「另一方还没这个字段」）。
///   3. 从未出现过的字段不写入 —— 尤其 deleted_at：没有版本 = 从未删除。
///   4. 永久删除（purged）是**带版本的事件**：只有清除版本比该任务所有字段
///      版本都新时，任务才被清除；否则说明任务在清除之后又被写过（恢复/编辑），
///      任务胜，清除记录作废。见项目说明 7.10。
MergeOutcome mergeStates(SyncState local, SyncState remote) {
  final purges = _unionPurges(local.purged, remote.purged);
  final ids = <String>{...local.tasks.keys, ...remote.tasks.keys};
  final mergedTasks = <String, TaskState>{};

  var added = 0;
  var updated = 0;
  var deleted = 0;
  var unchanged = 0;
  var remoteOnlyDeleted = 0;

  for (final id in ids) {
    final l = local.tasks[id];
    final r = remote.tasks[id];
    final fields = <TaskField, FieldValue>{};

    for (final field in TaskField.values) {
      final lv = l?.fields[field];
      final rv = r?.fields[field];
      if (lv == null && rv == null) continue;
      if (lv == null) {
        fields[field] = rv!;
      } else if (rv == null) {
        fields[field] = lv;
      } else {
        // 核心一行：版本大者胜。比较是纯函数，不含时间读取。
        fields[field] = rv.hlc > lv.hlc ? rv : lv;
      }
    }

    final int createdAt;
    if (l == null) {
      createdAt = r!.createdAt;
    } else if (r == null) {
      createdAt = l.createdAt;
    } else {
      createdAt = l.createdAt <= r.createdAt ? l.createdAt : r.createdAt;
    }

    // 记录身份（任务/组）不参与字段级 LWW：本机已经有这条记录就保本机的，
    // 只有本机从没见过时才取远端的。同一个 id 不可能两边一个当组一个当任务
    // （身份在创建时固定），这里只是防御性写法。
    final kind = (l ?? r)!.kind;

    mergedTasks[id] =
        TaskState(id: id, createdAt: createdAt, fields: fields, kind: kind);
  }

  // 清除 vs 恢复：清除版本更新才真的清除，否则任务活下来、清除记录作废。
  final effectivePurges = <String, Hlc>{};
  for (final entry in purges.entries) {
    final task = mergedTasks[entry.key];
    final taskHlc = task == null ? null : _maxFieldHlc(task);
    if (taskHlc == null || entry.value > taskHlc) {
      mergedTasks.remove(entry.key);
      effectivePurges[entry.key] = entry.value;
    }
  }

  for (final entry in mergedTasks.entries) {
    final l = local.tasks[entry.key];
    final task = entry.value;
    if (l == null) {
      // 本地没有这个任务：这是远端带来的新任务。
      if (task.isDeleted) {
        remoteOnlyDeleted++;
      } else {
        added++;
      }
      continue;
    }
    if (!l.isDeleted && task.isDeleted) deleted++;
    final changed = _changedFieldCount(l, task);
    updated += changed;
    if (changed == 0 && l.isDeleted == task.isDeleted) unchanged++;
  }

  // 本地原来有、合并结果里没了的 = 被永久删除。
  for (final id in local.tasks.keys) {
    if (!mergedTasks.containsKey(id)) deleted++;
  }

  return MergeOutcome(
    merged: SyncState(
      // 合并结果不属于任何单一设备；保留本地身份，避免误用。
      deviceId: local.deviceId,
      deviceName: local.deviceName,
      tasks: mergedTasks,
      purged: effectivePurges,
    ),
    stats: MergeStats(
      addedTasks: added,
      updatedFields: updated,
      deletedTasks: deleted,
      unchangedTasks: unchanged,
      remoteOnlyTasks: remoteOnlyDeleted,
    ),
  );
}

/// 两侧清除记录的并集，同一个 id 取版本较大的那一次。
Map<String, Hlc> _unionPurges(Map<String, Hlc> a, Map<String, Hlc> b) {
  final out = <String, Hlc>{...a};
  for (final entry in b.entries) {
    final cur = out[entry.key];
    if (cur == null || entry.value > cur) out[entry.key] = entry.value;
  }
  return out;
}

/// 一个任务里最新的字段版本（没有任何字段时返回 null）。
Hlc? _maxFieldHlc(TaskState task) {
  Hlc? best;
  for (final fv in task.fields.values) {
    if (best == null || fv.hlc > best) best = fv.hlc;
  }
  return best;
}

/// 相对本地，有多少个字段的值真的变了（包括被对方覆盖、以及本地独有字段）。
int _changedFieldCount(TaskState before, TaskState after) {
  var n = 0;
  for (final entry in after.fields.entries) {
    final old = before.fields[entry.key];
    if (old == null || old.value != entry.value.value) n++;
  }
  // 理论上 after 不会比 before 少字段（合并只增不减）。
  return n;
}

/// 取两侧 HLC 的最大值，供接收方推进本地时钟（见 HlcClock.receive）。
Hlc? maxHlcOf(SyncState a, SyncState b) {
  final ha = a.maxHlc;
  final hb = b.maxHlc;
  if (ha == null) return hb;
  if (hb == null) return ha;
  return ha > hb ? ha : hb;
}
