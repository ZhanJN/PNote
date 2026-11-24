import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/data/backup.dart';
import 'package:pnote/data/models.dart';
import 'package:pnote/sync/hlc.dart';
import 'package:pnote/sync/merge.dart';
import 'package:pnote/sync/payload.dart';

/// M12 分组的同步测试：/5 编解码、parent/collapsed/color 的 LWW、旧备份兼容。
void main() {
  TaskState node(
    String id, {
    bool group = false,
    String? parent,
    bool collapsed = false,
    int color = 0,
    Hlc? titleHlc,
    Hlc? parentHlc,
  }) {
    final base = titleHlc ?? Hlc(1, 0, 'a');
    final fields = <TaskField, FieldValue>{
      TaskField.title: FieldValue(id, base),
      TaskField.done: FieldValue(0, base),
      TaskField.order: FieldValue(1024.0, base),
      TaskField.parent: FieldValue(parent, parentHlc ?? base),
    };
    if (group) {
      fields[TaskField.collapsed] = FieldValue(collapsed ? 1 : 0, base);
      fields[TaskField.color] = FieldValue(color, base);
    }
    return TaskState(
      id: id,
      createdAt: 1,
      fields: fields,
      kind: group ? TaskKind.group : TaskKind.task,
    );
  }

  SyncState state(List<TaskState> tasks) => SyncState(
        deviceId: 'dev-a',
        deviceName: '电脑',
        tasks: {for (final t in tasks) t.id: t},
        purged: const {},
      );

  test('协议升到 pnote-sync/8', () {
    expect(kProto, 'pnote-sync/8');
  });

  test('组 + 任务往返：kind / parent / collapsed / color 都保留', () {
    final g = node('g', group: true, collapsed: true, color: 6);
    final t = node('t', parent: 'g');
    final raw = encodeState(state([g, t]));
    final decoded = decodeState(raw);
    final dg = decoded.tasks['g']!;
    final dt = decoded.tasks['t']!;
    expect(dg.kind, TaskKind.group);
    expect(dg.collapsed, isTrue);
    expect(dg.color, 6);
    expect(dt.kind, TaskKind.task);
    expect(dt.parentId, 'g');
  });

  test('报文里能看到 "kind":"group" 与 parent 字段', () {
    final raw = encodeState(state([
      node('g', group: true),
      node('t', parent: 'g'),
    ]));
    final map = jsonDecode(raw) as Map<String, Object?>;
    final tasks = (map['tasks'] as List).cast<Map<String, Object?>>();
    final group = tasks.firstWhere((m) => m['id'] == 'g');
    expect(group['kind'], 'group');
    final task = tasks.firstWhere((m) => m['id'] == 't');
    expect(task['kind'], 'task');
    final fields = task['fields'] as Map<String, Object?>;
    expect(fields.keys, contains('parent'));
  });

  test('合并：parent 按 HLC 逐字段 LWW，远端更新则跟远端走', () {
    final local = node('t', parent: null, parentHlc: Hlc(10, 0, 'a'));
    final remote = node('t', parent: 'g', parentHlc: Hlc(20, 0, 'b'));
    final merged = mergeStates(state([local]), state([remote]));
    expect(merged.merged.tasks['t']!.parentId, 'g');
  });

  test('合并：本机版本更新时，远端的旧 parent 覆盖不了', () {
    final local = node('t', parent: 'g', parentHlc: Hlc(30, 0, 'a'));
    final remote = node('t', parent: null, parentHlc: Hlc(20, 0, 'b'));
    final merged = mergeStates(state([local]), state([remote]));
    expect(merged.merged.tasks['t']!.parentId, 'g');
  });

  test('合并：collapsed 也按版本走（用户要求折叠状态参与同步）', () {
    final local = node('g', group: true, collapsed: false);
    final remote = TaskState(
      id: 'g',
      createdAt: 1,
      kind: TaskKind.group,
      fields: {
        ...node('g', group: true).fields,
        TaskField.collapsed: FieldValue(1, Hlc(50, 0, 'b')),
      },
    );
    final merged = mergeStates(state([local]), state([remote]));
    expect(merged.merged.tasks['g']!.collapsed, isTrue);
  });

  test('合并：kind 不参与逐字段比较；两端不一致时保留本机的', () {
    final local = node('x', group: true);
    final remote = node('x'); // 远端把同一条当成任务
    final merged = mergeStates(state([local]), state([remote]));
    expect(merged.merged.tasks['x']!.kind, TaskKind.group);
  });

  test('/4 的老报文会被明确拒绝（不静默吞）', () {
    final raw = jsonEncode({
      'proto': 'pnote-sync/4',
      'type': 'state',
      'deviceId': 'old',
      'deviceName': '旧手机',
      'tasks': <Object?>[],
      'purged': <Object?>[],
    });
    expect(() => decodeState(raw), throwsA(isA<PayloadException>()));
  });

  test('1.23 的老备份（没有 kind / parent 字段）能导入：一律当一级任务', () {
    final raw = jsonEncode({
      'proto': kBundleProto,
      'exportedAt': 1,
      'deviceId': 'old',
      'deviceName': '旧电脑',
      'tasks': [
        {
          'id': 'old1',
          'createdAt': 1700000000000,
          'fields': {
            'title': {
              'value': '老任务',
              'hlc': {'ms': 1700000000000, 'c': 0, 'dev': 'old'},
            },
            'done': {
              'value': 0,
              'hlc': {'ms': 1700000000000, 'c': 0, 'dev': 'old'},
            },
          },
        },
      ],
      'purged': <Object?>[],
    });
    final state = decodeBundle(raw);
    final task = state.tasks['old1']!;
    expect(task.title, '老任务');
    expect(task.kind, TaskKind.task);
    expect(task.parentId, isNull);
    expect(task.collapsed, isFalse);
  });
}
