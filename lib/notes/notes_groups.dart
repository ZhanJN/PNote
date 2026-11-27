/// 笔记「组」（1.55：支持子组、置顶）。
///
/// * 一篇笔记**最多属于一个组**；没写就是未分组。
/// * 组有：名字 / 颜色 / 折叠 / 排序 / 上级组 / 置顶。
/// * 组可以任意层级嵌套（`parent` 指向上一级组名，空串 = 一级组）。
/// * 置顶：组置顶后排在同级组的最前；笔记置顶后排在本组的最前。
///   其余仍按用户拖出来的手动顺序。
/// * 手动顺序按组分开记在 `order` 里；时间排序只是临时视图，**不会覆盖**它。
/// * 组清单存在库根 `.groups.json`，随笔记同步（整文件 LWW）。
///
/// 老格式：v1（1.48–1.53，多对多）、v2（1.54，单组）。读取时自动迁移。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 存在笔记库根的组清单文件名。
const String kGroupsFileName = '.groups.json';

/// 当前组清单格式版本。
const int kGroupsVersion = 3;

/// 组的颜色只存索引，具体色值由界面决定（和待办的 8 色一致）。
const int kGroupColorCount = 8;

/// 同一级里每两个组之间的排序间隔。
const double kGroupOrderStep = 1024;

/// 防坏数据成环：往上找父组的最大层数。
const int _kMaxDepth = 64;

/// 一个组：名字、颜色、折叠、排序、上级、置顶。
class NoteGroupDef {
  const NoteGroupDef({
    required this.name,
    this.color = 0,
    this.collapsed = false,
    this.order = 0,
    this.parent = '',
    this.pinned = false,
  });

  final String name;
  final int color;
  final bool collapsed;
  final double order;

  /// 上级组名；空串 = 一级组。
  final String parent;

  final bool pinned;

  NoteGroupDef copyWith({
    String? name,
    int? color,
    bool? collapsed,
    double? order,
    String? parent,
    bool? pinned,
  }) {
    return NoteGroupDef(
      name: name ?? this.name,
      color: color ?? this.color,
      collapsed: collapsed ?? this.collapsed,
      order: order ?? this.order,
      parent: parent ?? this.parent,
      pinned: pinned ?? this.pinned,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'color': color,
        'collapsed': collapsed,
        'order': order,
        'parent': parent,
        'pinned': pinned,
      };

  factory NoteGroupDef.fromJson(Map<String, Object?> map) {
    final name = (map['name'] as String?)?.trim() ?? '';
    final color = map['color'];
    final collapsed = map['collapsed'];
    final order = map['order'];
    final parent = (map['parent'] as String?)?.trim() ?? '';
    return NoteGroupDef(
      name: name,
      color: color is num ? color.toInt().clamp(0, kGroupColorCount - 1) : 0,
      collapsed: collapsed == true,
      order: order is num ? order.toDouble() : 0,
      parent: parent,
      pinned: map['pinned'] == true,
    );
  }
}

/// 组清单的只读快照。
class NoteGroups {
  const NoteGroups({
    this.groups = const <NoteGroupDef>[],
    this.assign = const <String, String>{},
    this.order = const <String, List<String>>{},
    this.pins = const <String>{},
  });

  const NoteGroups.empty() : this();

  /// 组定义（读取时按「父组 + 同级顺序」排好；名字唯一）。
  final List<NoteGroupDef> groups;

  /// 笔记相对路径 → 组名。没有键 = 未分组。
  final Map<String, String> assign;

  /// 组名（`''` 表示未分组）→ 用户拖出来的手动顺序。
  final Map<String, List<String>> order;

  /// 组内置顶的笔记路径。
  final Set<String> pins;

  /// 全部组名（按清单顺序，含子组）。
  List<String> get names => <String>[for (final group in groups) group.name];

  NoteGroupDef? groupNamed(String name) {
    for (final group in groups) {
      if (group.name == name) return group;
    }
    return null;
  }

  /// 组实际生效的父组名（父组不存在 / 自己指向自己 → 当成一级组）。
  String parentOf(String name) {
    final def = groupNamed(name);
    if (def == null) return '';
    final parent = def.parent;
    if (parent.isEmpty || parent == name) return '';
    return groupNamed(parent) == null ? '' : parent;
  }

  /// 一级组（父组为空），已按置顶 + 手动顺序排好。
  List<NoteGroupDef> get roots => childrenOf('');

  /// 某一级下的子组，已按置顶 + 手动顺序排好。
  List<NoteGroupDef> childrenOf(String parent) {
    final list = <NoteGroupDef>[
      for (final group in groups)
        if (parentOf(group.name) == parent) group,
    ];
    list.sort(_compareSiblings);
    return list;
  }

  static int _compareSiblings(NoteGroupDef a, NoteGroupDef b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
  }

  /// 层级：一级组 = 0。
  int depthOf(String name) {
    var depth = 0;
    var current = parentOf(name);
    final seen = <String>{name};
    while (current.isNotEmpty && seen.add(current) && depth < _kMaxDepth) {
      depth++;
      current = parentOf(current);
    }
    return depth;
  }

  /// 某个组及其全部下级组的名字（含自己）。
  List<String> subtreeNames(String name) {
    final out = <String>[];
    void walk(String current) {
      if (out.contains(current)) return;
      out.add(current);
      for (final child in childrenOf(current)) {
        walk(child.name);
      }
    }

    walk(name);
    return out;
  }

  /// 这些组里的笔记路径（[includeDescendants] 为真时连子组一起）。
  List<String> pathsOf(String? group, {bool includeDescendants = false}) {
    if (group == null) {
      return <String>[
        for (final entry in assign.entries)
          if (entry.value.isEmpty) entry.key,
      ];
    }
    final names = includeDescendants
        ? subtreeNames(group).toSet()
        : <String>{group};
    return <String>[
      for (final entry in assign.entries)
        if (names.contains(entry.value)) entry.key,
    ];
  }

  String? groupOf(String relPath) => assign[relPath];

  bool isCollapsed(String name) => groupNamed(name)?.collapsed ?? false;

  bool isPinned(String name) => groupNamed(name)?.pinned ?? false;

  bool isPinnedNote(String relPath) => pins.contains(relPath);

  /// 未分组的笔记路径（按 assign 的键；调用方自己再看文件在不在）。
  List<String> get ungroupedPaths => <String>[
        for (final entry in assign.entries)
          if (entry.value.isEmpty) entry.key,
      ];

  NoteGroups copyWith({
    List<NoteGroupDef>? groups,
    Map<String, String>? assign,
    Map<String, List<String>>? order,
    Set<String>? pins,
  }) {
    return NoteGroups(
      groups: groups ?? this.groups,
      assign: assign ?? this.assign,
      order: order ?? this.order,
      pins: pins ?? this.pins,
    );
  }

  NoteGroups withCollapsed(String name, bool collapsed) {
    return copyWith(groups: <NoteGroupDef>[
      for (final group in groups)
        group.name == name ? group.copyWith(collapsed: collapsed) : group,
    ]);
  }

  /// 组置顶 / 取消置顶。
  NoteGroups withGroupPinned(String name, bool pinned) {
    return copyWith(groups: <NoteGroupDef>[
      for (final group in groups)
        group.name == name ? group.copyWith(pinned: pinned) : group,
    ]);
  }

  /// 笔记置顶 / 取消置顶（只影响它所在分区的显示顺序）。
  NoteGroups withNotePinned(String relPath, bool pinned) {
    final next = <String>{...pins};
    if (pinned) {
      next.add(relPath.replaceAll('\\', '/'));
    } else {
      next.remove(relPath.replaceAll('\\', '/'));
    }
    return copyWith(pins: next);
  }

  NoteGroups withNoteGroup(String relPath, String? group) {
    final next = <String, String>{...assign};
    if (group == null || group.isEmpty) {
      next.remove(relPath);
    } else {
      next[relPath] = group;
    }
    return copyWith(assign: next);
  }

  NoteGroups withOrder(String key, List<String> ids) {
    final next = <String, List<String>>{
      for (final entry in order.entries) entry.key: List<String>.of(entry.value),
    };
    next[key] = List<String>.of(ids);
    return copyWith(order: next);
  }

  /// 新建组；重名直接返回自身。父组不存在时落到一级。
  NoteGroups addGroup(String name, {int color = 0, String parent = ''}) {
    final clean = name.trim();
    if (clean.isEmpty || groupNamed(clean) != null) return this;
    final safeParent = parent.isEmpty ? '' : (groupNamed(parent) == null ? '' : parent);
    var maxOrder = 0.0;
    for (final group in groups) {
      if (parentOf(group.name) == safeParent && group.order > maxOrder) {
        maxOrder = group.order;
      }
    }
    return copyWith(
      groups: <NoteGroupDef>[
        ...groups,
        NoteGroupDef(
          name: clean,
          color: color.clamp(0, kGroupColorCount - 1),
          order: groups.isEmpty ? 0 : maxOrder + kGroupOrderStep,
          parent: safeParent,
        ),
      ],
    );
  }

  /// 改组名：笔记归属、手动顺序、子组的父指针一起搬过去。
  NoteGroups renameGroup(String from, String to) {
    final clean = to.trim();
    if (clean.isEmpty || clean == from || groupNamed(clean) != null) return this;
    final nextGroups = <NoteGroupDef>[
      for (final group in groups)
        if (group.name == from)
          group.copyWith(name: clean)
        else if (parentOf(group.name) == from)
          group.copyWith(parent: clean)
        else
          group,
    ];
    final nextAssign = <String, String>{
      for (final entry in assign.entries)
        entry.key: entry.value == from ? clean : entry.value,
    };
    final nextOrder = <String, List<String>>{};
    order.forEach((key, value) {
      nextOrder[key == from ? clean : key] = List<String>.of(value);
    });
    return NoteGroups(
      groups: nextGroups,
      assign: nextAssign,
      order: nextOrder,
      pins: pins,
    );
  }

  /// 删组：笔记回「未分组」，子组上移到它的父级。
  NoteGroups deleteGroup(String name) {
    final parent = parentOf(name);
    var nextOrderValue = 0.0;
    for (final group in childrenOf(parent)) {
      if (group.name != name && group.order > nextOrderValue) {
        nextOrderValue = group.order;
      }
    }
    final nextGroups = <NoteGroupDef>[
      for (final group in groups)
        if (group.name != name)
          parentOf(group.name) == name
              ? group.copyWith(
                  parent: parent,
                  order: nextOrderValue += kGroupOrderStep,
                )
              : group,
    ];
    final nextAssign = <String, String>{};
    assign.forEach((path, group) {
      if (group != name) nextAssign[path] = group;
    });
    final nextOrder = <String, List<String>>{};
    order.forEach((key, value) {
      if (key != name) nextOrder[key] = List<String>.of(value);
    });
    return NoteGroups(
      groups: nextGroups,
      assign: nextAssign,
      order: nextOrder,
      pins: pins,
    );
  }

  /// 组上移 / 下移（只在同级里换位置；置顶组之间、普通组之间各自移动）。
  NoteGroups moveGroup(String name, int delta) {
    if (delta == 0) return this;
    final parent = parentOf(name);
    final siblings = childrenOf(parent);
    final index = siblings.indexWhere((group) => group.name == name);
    if (index < 0) return this;
    var target = index + delta;
    if (target < 0 || target >= siblings.length) return this;
    // 置顶组和普通组不互相跨越：只在同一块里换。
    if (siblings[target].pinned != siblings[index].pinned) {
      target = target < index ? index - 1 : index + 1;
      if (target < 0 || target >= siblings.length) return this;
      if (siblings[target].pinned != siblings[index].pinned) return this;
    }
    final next = List<NoteGroupDef>.of(siblings);
    final item = next.removeAt(index);
    next.insert(target, item);
    // 同时把 `groups` 列表里这几个同级组的先后重排，`names` / 序列化顺序才跟视图一致。
    final out = <NoteGroupDef>[];
    var k = 0;
    for (final group in groups) {
      if (parentOf(group.name) == parent) {
        out.add(next[k].copyWith(order: k * kGroupOrderStep));
        k++;
      } else {
        out.add(group);
      }
    }
    return copyWith(groups: out);
  }

  NoteGroups withColor(String name, int color) {
    return copyWith(groups: <NoteGroupDef>[
      for (final group in groups)
        group.name == name
            ? group.copyWith(color: color.clamp(0, kGroupColorCount - 1))
            : group,
    ]);
  }
}

/// 四位数字目录 = 时间目录（`2026`），不再算组；保留给旧数据迁移与新笔记路径用。
bool isYearDir(String name) => RegExp(r'^\d{4}$').hasMatch(name);

/// 内部目录 / 文件：不出现在组标签里。
bool isInternalName(String name) {
  if (name.isEmpty) return true;
  if (name.startsWith('.')) return true;
  if (name.endsWith('.assets')) return true;
  return false;
}

/// 从 JSON 文本解析；坏掉就当「没有组」，绝不让笔记库打不开。
NoteGroups parseGroups(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const NoteGroups.empty();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const NoteGroups.empty();
    final map = Map<String, Object?>.from(decoded);
    final version = map['version'];
    if (version is num && version >= 3 && map['groups'] is List) {
      return _parseV2(map).copyWith(pins: _parsePins(map));
    }
    if (version is num && version == 2 && map['groups'] is List) {
      return _parseV2(map);
    }
    return _migrateV1(map);
  } catch (_) {
    return const NoteGroups.empty();
  }
}

Set<String> _parsePins(Map<String, Object?> map) {
  final raw = map['pins'];
  if (raw is! List) return const <String>{};
  return <String>{
    for (final item in raw)
      if (item is String && item.trim().isNotEmpty)
        item.trim().replaceAll('\\', '/'),
  };
}

/// v2（1.54）与 v3（1.55）共用：v3 多出的 parent/pinned/pins 缺失时取默认值。
NoteGroups _parseV2(Map<String, Object?> map) {
  final groups = <NoteGroupDef>[];
  final seen = <String>{};
  for (final item in (map['groups'] as List)) {
    if (item is! Map) continue;
    final def = NoteGroupDef.fromJson(Map<String, Object?>.from(item));
    if (def.name.isEmpty || !seen.add(def.name)) continue;
    groups.add(def);
  }
  // 父组必须存在，且不能成环；坏数据降为一级组。
  final byName = <String, NoteGroupDef>{
    for (final group in groups) group.name: group,
  };
  final cleaned = <NoteGroupDef>[];
  for (final group in groups) {
    var parent = group.parent;
    if (parent.isEmpty || !byName.containsKey(parent) || parent == group.name) {
      parent = '';
    } else {
      var walk = parent;
      var depth = 0;
      while (walk.isNotEmpty && depth < _kMaxDepth) {
        if (walk == group.name) {
          parent = '';
          break;
        }
        final up = byName[walk]?.parent ?? '';
        walk = byName.containsKey(up) ? up : '';
        depth++;
      }
    }
    cleaned.add(group.copyWith(parent: parent));
  }
  cleaned.sort((a, b) {
    final byParent = a.parent.compareTo(b.parent);
    if (byParent != 0) return byParent;
    return NoteGroups._compareSiblings(a, b);
  });
  final namesList = <String>[for (final group in cleaned) group.name];
  final assign = <String, String>{};
  final assignRaw = map['assign'];
  if (assignRaw is Map) {
    assignRaw.forEach((key, value) {
      if (key is! String || value is! String) return;
      final name = value.trim();
      if (!namesList.contains(name)) return;
      assign[key.replaceAll('\\', '/')] = name;
    });
  }
  final order = <String, List<String>>{};
  final orderRaw = map['order'];
  if (orderRaw is Map) {
    orderRaw.forEach((key, value) {
      if (key is! String || value is! List) return;
      if (key.isNotEmpty && !namesList.contains(key)) return;
      final ids = <String>[
        for (final item in value)
          if (item is String && item.trim().isNotEmpty)
            item.trim().replaceAll('\\', '/'),
      ];
      if (ids.isNotEmpty) order[key] = ids;
    });
  }
  return NoteGroups(groups: cleaned, assign: assign, order: order);
}

/// 1.48–1.53 的 `{组名: [路径]}` 多对多格式 → 单组（先出现的组赢）。
NoteGroups _migrateV1(Map<String, Object?> map) {
  final groups = <NoteGroupDef>[];
  final assign = <String, String>{};
  var index = 0;
  map.forEach((key, value) {
    if (value is! List) return;
    final name = key.trim();
    if (name.isEmpty) return;
    groups.add(NoteGroupDef(
      name: name,
      color: index % kGroupColorCount,
      order: index * kGroupOrderStep,
    ));
    index++;
    for (final item in value) {
      if (item is! String) continue;
      final path = item.trim().replaceAll('\\', '/');
      if (path.isEmpty) continue;
      assign.putIfAbsent(path, () => name);
    }
  });
  return NoteGroups(groups: groups, assign: assign);
}

/// 序列化成便于人看的 JSON（带 version，1.55 格式）。
String encodeGroups(NoteGroups groups) {
  final body = <String, Object?>{
    'version': kGroupsVersion,
    'groups': <Object?>[for (final group in groups.groups) group.toJson()],
    'assign': <String, Object?>{
      for (final key in (groups.assign.keys.toList()..sort()))
        key: groups.assign[key],
    },
    'order': <String, Object?>{
      for (final key in (groups.order.keys.toList()..sort()))
        key: List<String>.of(groups.order[key]!),
    },
    'pins': <String>[...groups.pins]..sort(),
  };
  return const JsonEncoder.withIndent('  ').convert(body);
}

/// 读库根清单（文件不存在 / 坏掉 → 空）。
NoteGroups readGroupsSync(Directory root) {
  final file = File(p.join(root.path, kGroupsFileName));
  if (!file.existsSync()) return const NoteGroups.empty();
  try {
    return parseGroups(file.readAsStringSync());
  } catch (_) {
    return const NoteGroups.empty();
  }
}
