/// 数据库的打开与建表。对应《PNote项目说明》附录 A。
///
/// 平台差异只在这一处处理：
///   Android/iOS  -> sqflite 插件（SQLite 由系统提供）
///   Windows/Linux/macOS -> sqflite_common_ffi（自带 SQLite，走 FFI）
/// 其余代码只认 `Database` 接口，因此可以随便在两边跑。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// 用前缀导入 sqflite：移动端要靠它的默认工厂（插件实现），桌面端不用。
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库结构版本。每次改表都要 +1，并在 [_onUpgrade] 里写迁移。
///   1 -> 初始版本（tasks / field_versions / meta）
///   2 -> 新增 purged 表（回收站里「永久删除」过的 id，用来阻止对端把任务推回来）
///   3 -> purged 记录带上 HLC（清除变成「带版本的事件」，可被更新的恢复压过）
///   4 -> tasks 增加 order_index（1.20 手动拖拽排序）；老任务的顺序值初始化成
///        created_at，并补一条 order 字段的版本行（设备记 legacy），
///        这样升级后列表顺序不变、也不会在同步时把对端的顺序打乱
///   5 -> tasks 增加 parent_id / kind / color / collapsed（1.24 两级分组）。
///        老数据默认都是「一级任务」：parent_id 为 NULL、kind=0、color=0、
///        collapsed=0，升级后看到的东西和升级前一模一样。
///   6 -> tasks 增加时间系统五列（1.31）：due_value / due_precision /
///        remind_lead / repeat_rule / series_id。老数据全部是「没有时间」，
///        界面与升级前一致。
const int kSchemaVersion = 6;

/// 根据当前平台选择 SQLite 实现。
DatabaseFactory resolveDatabaseFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  // Android/iOS：交给 sqflite 插件注册的默认工厂。
  return sqflite.databaseFactory;
}

/// 打开（或创建）应用数据库。
/// [overridePath] 仅供测试使用，传入 `inMemoryDatabasePath` 即得到内存库。
Future<Database> openAppDatabase({String? overridePath}) async {
  final factory = resolveDatabaseFactory();
  final String path;
  if (overridePath != null) {
    path = overridePath;
  } else {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    path = p.join(dir.path, 'pnote.db');
  }

  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: kSchemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    ),
  );
}

Future<void> _onCreate(Database db, int version) async {
  final batch = db.batch();

  batch.execute('''
    CREATE TABLE tasks (
      id          TEXT    PRIMARY KEY NOT NULL,
      title       TEXT    NOT NULL DEFAULT '',
      done        INTEGER NOT NULL DEFAULT 0,
      deleted_at  INTEGER,
      created_at  INTEGER NOT NULL,
      order_index REAL    NOT NULL DEFAULT 0,
      parent_id   TEXT,
      kind        INTEGER NOT NULL DEFAULT 0,
      color       INTEGER NOT NULL DEFAULT 0,
      collapsed   INTEGER NOT NULL DEFAULT 0,
      due_value   TEXT,
      due_precision INTEGER NOT NULL DEFAULT 0,
      remind_lead INTEGER,
      repeat_rule TEXT,
      series_id   TEXT
    )
  ''');

  batch.execute('''
    CREATE TABLE field_versions (
      task_id   TEXT    NOT NULL,
      field     TEXT    NOT NULL,
      hlc_ms    INTEGER NOT NULL,
      hlc_c     INTEGER NOT NULL,
      device_id TEXT    NOT NULL,
      PRIMARY KEY (task_id, field),
      FOREIGN KEY (task_id) REFERENCES tasks (id) ON DELETE CASCADE
    )
  ''');

  batch.execute('''
    CREATE TABLE meta (
      key   TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    )
  ''');

  // 回收站里点「永久删除」之后，任务行被物理删掉；这里留一个 id 记念，
  // 防止对端在下次同步时把这条任务当成「它那边有、你这边没有」又推回来。
  batch.execute(_purgedTableSql);

  batch.execute('CREATE INDEX idx_tasks_visible ON tasks (deleted_at, created_at)');
  batch.execute('CREATE INDEX idx_tasks_parent ON tasks (parent_id, deleted_at)');

  await batch.commit(noResult: true);
}

const String _purgedTableSql = '''
  CREATE TABLE purged (
    id        TEXT    PRIMARY KEY NOT NULL,
    hlc_ms    INTEGER NOT NULL,
    hlc_c     INTEGER NOT NULL,
    device_id TEXT    NOT NULL
  )
''';

/// 1.9 时代的 purged 结构（只有 id + 墙钟毫秒），仅用于 2 -> 3 升级时搬家。
const String _purgedTableSqlV2 = '''
  CREATE TABLE purged (
    id TEXT    PRIMARY KEY NOT NULL,
    at INTEGER NOT NULL
  )
''';

Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
  // 1 -> 2：加 purged 表。旧数据的 tasks/field_versions 完全不用动。
  if (oldVersion < 2) {
    await db.execute(_purgedTableSqlV2);
  }
  // 2 -> 3：purged 从「只有 id + 墙钟」升级为「带 HLC 的清除记录」。
  // 老记录的 at 直接当作 hlc_ms、计数器 0、设备记为 legacy —— 它仍然能压住
  // 老任务（那些任务的版本都早于这次清除）。
  if (oldVersion < 3) {
    await db.transaction((txn) async {
      await txn.execute('ALTER TABLE purged RENAME TO purged_v2');
      await txn.execute(_purgedTableSql);
      await txn.execute('''
        INSERT INTO purged (id, hlc_ms, hlc_c, device_id)
        SELECT id, at, 0, 'legacy' FROM purged_v2
      ''');
      await txn.execute('DROP TABLE purged_v2');
    });
  }
  // 3 -> 4：tasks 增加 order_index（1.20 手动排序）。
  // 老任务没有顺序值：用 created_at 顶上（视觉顺序不变），并补一条
  // order 字段的版本行，否则导出状态时这个字段会被当成「没有版本」而丢掉，
  // 对端拿到后按 0 排，顺序会乱。设备记 legacy —— 和 purged 的老数据同待遇。
  if (oldVersion < 4) {
    await db.transaction((txn) async {
      await txn.execute(
        'ALTER TABLE tasks ADD COLUMN order_index REAL NOT NULL DEFAULT 0',
      );
      await txn.execute('UPDATE tasks SET order_index = created_at');
      await txn.execute('''
        INSERT OR IGNORE INTO field_versions (task_id, field, hlc_ms, hlc_c, device_id)
        SELECT id, 'order', created_at, 0, 'legacy' FROM tasks
      ''');
    });
  }
  // 4 -> 5：tasks 增加分组相关的四列（1.24 两级分组）。
  // 老数据一律视为「一级任务」；parent/collapsed/color 没有版本行也没关系 ——
  // 缺版本 = 值按默认处理（parent 空 = 一级），同步时对端拿到的也一样。
  if (oldVersion < 5) {
    await db.transaction((txn) async {
      await txn.execute('ALTER TABLE tasks ADD COLUMN parent_id TEXT');
      await txn.execute(
        'ALTER TABLE tasks ADD COLUMN kind INTEGER NOT NULL DEFAULT 0',
      );
      await txn.execute(
        'ALTER TABLE tasks ADD COLUMN color INTEGER NOT NULL DEFAULT 0',
      );
      await txn.execute(
        'ALTER TABLE tasks ADD COLUMN collapsed INTEGER NOT NULL DEFAULT 0',
      );
      await txn.execute(
        'CREATE INDEX idx_tasks_parent ON tasks (parent_id, deleted_at)',
      );
    });
  }
  // 5 -> 6：时间系统五列（1.31）。老数据没有时间，精度默认 0（无时间），
  // 其余列留空 —— 和「从没设置过」完全等价，不需要补版本行。
  if (oldVersion < 6) {
    await db.transaction((txn) async {
      await txn.execute('ALTER TABLE tasks ADD COLUMN due_value TEXT');
      await txn.execute(
        'ALTER TABLE tasks ADD COLUMN due_precision INTEGER NOT NULL DEFAULT 0',
      );
      await txn.execute('ALTER TABLE tasks ADD COLUMN remind_lead INTEGER');
      await txn.execute('ALTER TABLE tasks ADD COLUMN repeat_rule TEXT');
      await txn.execute('ALTER TABLE tasks ADD COLUMN series_id TEXT');
    });
  }
}
