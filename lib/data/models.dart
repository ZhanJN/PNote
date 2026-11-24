/// 数据模型：任务、字段、版本。
/// 纯 Dart，不 import Flutter。对应《PNote项目说明》第 6 节与附录 A。
library;

import 'package:pnote/sync/hlc.dart';

/// 「可合并字段」。
/// 这是本项目全部同步复杂度的来源：合并只发生在字段级别，不发生在记录级别。
///
/// 1.20 新增 [order]：用户手动拖拽排序的位置。它和 title/done 一样是
/// **带独立版本的可合并字段** —— 拖一次就写一个新版本，另一台设备下次同步
/// 拿到的就是「谁最后拖的谁说了算」（字段级 LWW）。
/// 为什么用 double：便于在两条任务之间插值（前一条 + 后一条 的中点），
/// 不必每次拖拽都重排整张表。值相同时用 createdAt、id 兜底，顺序稳定。
///
/// 1.24（M12 分组）新增三个字段：
///   [parent]    父节点 id（null = 一级）。组也是节点，所以任务挂组、组挂组
///               都只靠这一列，不需要第二张表。
///   [collapsed] 组的折叠状态（1/0）。它是**同步字段**：按用户要求，
///               折叠在两台设备上保持一致（LWW 决定谁最后点）。
///   [color]     组的颜色序号（0-7）。任务不用，留着也是 0。
/// 组的「身份」（是任务还是组）不是可合并字段，见 [TaskKind]。
///
/// 1.31（时间系统）新增五个字段。它们的共同点是「只描述时间，不描述状态」：
///   [due]          时间值。全天存 `YYYY-MM-DD`（当地日期，不带时区）；
///                  精确存带原始偏移的 ISO 字符串。改精度不清值。
///   [duePrecision] 精度：0 无 / 1 只到日 / 2 到分钟。
///   [remindLead]   提前多少分钟提醒；null = 跟随（组级或全局）默认。
///   [repeatRule]   重复规则（每日/每周/每月/每年…），null = 不重复。
///   [seriesId]     同一串重复任务共用的 id（勾完成生成下一期时沿用）。
enum TaskField {
  title('title'),
  done('done'),
  deletedAt('deleted_at'),
  order('order'),
  parent('parent'),
  collapsed('collapsed'),
  color('color'),
  due('due'),
  duePrecision('due_precision'),
  remindLead('remind_lead'),
  repeatRule('repeat_rule'),
  seriesId('series_id');

  const TaskField(this.wireName);

  /// 写进数据库、写进报文时使用的名字（下划线风格）。
  final String wireName;

  static TaskField fromWire(String name) {
    for (final f in TaskField.values) {
      if (f.wireName == name) return f;
    }
    throw FormatException('未知字段名: $name');
  }
}

/// 一条记录是「任务」还是「组」。
///
/// 为什么不做成可合并字段：组的身份是记录的骨架，不是用户编辑的内容。
/// 两台设备不可能各把它当一次组、一次任务（同一个 id 只会在创建时确定身份），
/// 所以合并时「本机已经有这条记录就保本机身份，否则取远端的」。
/// 进报文用 "task"/"group"，进数据库用 0/1。
enum TaskKind {
  task('task', 0),
  group('group', 1);

  const TaskKind(this.wireName, this.code);

  final String wireName;
  final int code;

  static TaskKind fromWire(String? name) {
    // 1.23 及更早的备份里没有 kind 字段：一律当任务（老数据没有组）。
    if (name == null) return TaskKind.task;
    for (final k in TaskKind.values) {
      if (k.wireName == name) return k;
    }
    throw FormatException('未知记录类型: $name');
  }

  static TaskKind fromCode(int code) =>
      code == TaskKind.group.code ? TaskKind.group : TaskKind.task;
}

/// 一个字段的值 + 它的版本。
/// 值类型固定：title 是 String，done 是 int(0/1)，deletedAt 是 int(毫秒) 或 null。
class FieldValue {
  const FieldValue(this.value, this.hlc);

  final Object? value;
  final Hlc hlc;

  Map<String, Object?> toJson() => {'value': value, 'hlc': hlc.toJson()};

  factory FieldValue.fromJson(Map<String, Object?> json) {
    final hlc = json['hlc'];
    if (hlc is! Map) throw const FormatException('字段缺少 hlc');
    return FieldValue(
      json['value'],
      Hlc.fromJson(Map<String, Object?>.from(hlc)),
    );
  }
}

/// 一台设备上的「一个任务或一个组」的完整可见状态。
class TaskState {
  const TaskState({
    required this.id,
    required this.createdAt,
    required this.fields,
    this.kind = TaskKind.task,
  });

  /// 客户端生成的 UUIDv4，全局唯一，永远是主键。
  final String id;

  /// 创建时间（毫秒）。只用于列表排序，**不参与冲突判定**。
  final int createdAt;

  final Map<TaskField, FieldValue> fields;

  /// 记录身份：任务 / 组。创建后不再变，不属于字段级合并。
  final TaskKind kind;

  bool get isGroup => kind == TaskKind.group;

  String get title => (fields[TaskField.title]?.value as String?) ?? '';

  bool get done => (fields[TaskField.done]?.value as int? ?? 0) == 1;

  /// 墓碑：deletedAt 有值即为已删除。
  /// 注意这是「字段有值」，不是「字段存在」——从没删过的任务没有 deleted_at 版本。
  bool get isDeleted => fields[TaskField.deletedAt]?.value != null;

  int? get deletedAt => fields[TaskField.deletedAt]?.value as int?;

  /// 手动排序位置（1.20）。老数据没有这个字段时按 0 处理，
  /// 排序的兜底键是 createdAt + id，所以视觉上仍然是「先建的在前」。
  /// 注意 JSON 解出来的数字可能是 int 也可能是 double，统一转 double。
  double get order =>
      (fields[TaskField.order]?.value as num?)?.toDouble() ?? 0;

  /// 父节点 id；null 表示一级（没有父组）。
  String? get parentId => fields[TaskField.parent]?.value as String?;

  /// 组是否折叠（1.24）。任务没有这个字段，按 false 处理。
  bool get collapsed => (fields[TaskField.collapsed]?.value as int? ?? 0) == 1;

  /// 组的颜色序号（0-7），任务不用。
  int get color => (fields[TaskField.color]?.value as num?)?.toInt() ?? 0;

  /// 时间值（1.31）。没有设置时间时为 null。
  String? get dueValue => fields[TaskField.due]?.value as String?;

  /// 时间精度：0 无 / 1 只到日 / 2 到分钟。没有时间时也返回 0。
  int get duePrecision =>
      (fields[TaskField.duePrecision]?.value as num?)?.toInt() ?? 0;

  /// 提前提醒的分钟数；null 表示跟随默认（组级 → 全局）。
  int? get remindLead => (fields[TaskField.remindLead]?.value as num?)?.toInt();

  /// 重复规则原文（1.34 起真正生效；解析见 repeat.dart）。
  /// 1.31 只预留了列，1.34 才实现完成时生成下一期。
  String? get repeatRule => fields[TaskField.repeatRule]?.value as String?;

  /// 重复任务串 id。不是重复任务时为 null；第一次设置重复时写成任务自己的 id。
  String? get seriesId => fields[TaskField.seriesId]?.value as String?;

  TaskState copyWith({Map<TaskField, FieldValue>? fields, TaskKind? kind}) =>
      TaskState(
        id: id,
        createdAt: createdAt,
        fields: fields ?? this.fields,
        kind: kind ?? this.kind,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'kind': kind.wireName,
        'fields': {
          for (final e in fields.entries) e.key.wireName: e.value.toJson(),
        },
      };

  factory TaskState.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final createdAt = json['createdAt'];
    final fields = json['fields'];
    final kind = json['kind'];
    if (id is! String || createdAt is! int || fields is! Map) {
      throw const FormatException('任务结构不合法（需要 id:String, createdAt:int, fields:Map）');
    }
    if (kind != null && kind is! String) {
      throw const FormatException('任务类型不合法（kind 必须是字符串）');
    }
    final parsed = <TaskField, FieldValue>{};
    for (final e in fields.entries) {
      final name = e.key;
      final body = e.value;
      if (name is! String || body is! Map) {
        throw const FormatException('任务字段结构不合法');
      }
      parsed[TaskField.fromWire(name)] =
          FieldValue.fromJson(Map<String, Object?>.from(body));
    }
    return TaskState(
      id: id,
      createdAt: createdAt,
      fields: parsed,
      kind: TaskKind.fromWire(kind as String?),
    );
  }
}

/// 一次同步所交换的「全量状态」。
/// 第一版刻意交换全量：幂等、无游标、新设备零特殊处理（见 ADR-004）。
class SyncState {
  const SyncState({
    required this.deviceId,
    required this.deviceName,
    required this.tasks,
    this.purged = const {},
  });
  final String deviceId;
  final String deviceName;
  final Map<String, TaskState> tasks;

  /// 在回收站里被「永久删除」的任务 id → 该次清除的版本。
  ///
  /// 1.11 起它不再是「一个不可辩驳的黑名单」，而是一条**带版本的事件**：
  /// 只有清除版本比任务所有字段版本都新时，清除才生效（见 merge.dart）。
  /// 这样「清空回收站之后导入备份」才能把任务救回来（见项目说明 7.10）。
  final Map<String, Hlc> purged;

  static const empty = SyncState(deviceId: '', deviceName: '', tasks: {});

  /// 本状态里出现过的最大 HLC（用于接收端推进时钟）。
  Hlc? get maxHlc {
    Hlc? best;
    for (final task in tasks.values) {
      for (final fv in task.fields.values) {
        if (best == null || fv.hlc > best) best = fv.hlc;
      }
    }
    for (final hlc in purged.values) {
      if (best == null || hlc > best) best = hlc;
    }
    return best;
  }

  List<TaskState> get visibleTasks {
    final list = tasks.values.where((t) => !t.isDeleted).toList()
      ..sort((a, b) {
        final byCreated = a.createdAt.compareTo(b.createdAt);
        return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
      });
    return list;
  }
}
