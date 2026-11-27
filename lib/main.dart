import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'package:pnote/app.dart';
import 'package:pnote/data/db.dart';
import 'package:pnote/data/task_dao.dart';
import 'package:pnote/notes/notes_sync.dart';
import 'package:pnote/platform/keep_alive.dart';
import 'package:pnote/sync/account.dart';
import 'package:pnote/sync/sync_service.dart';
import 'package:pnote/theme/theme.dart';
import 'package:pnote/ui/settings/notes_prefs.dart';

/// 启动顺序：初始化 Flutter 绑定 → 打开数据库 → 读取/生成设备 ID 与时钟 →
/// 读主题偏好（1.18）→ 建同步服务（只开门，不自动同步）→ 请求「后台保活」→
/// 显示界面。任何一步失败都要显示错误页，而不是静默白屏。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final db = await openAppDatabase();
    final dao = await TaskDao.attach(db);
    // 主题要在 runApp 之前定下来：否则会先闪一下白底再变黑。
    final themeMode = parseThemeMode(await dao.readSetting(kThemeModeKey));
    final reduceMotion = parseReduceMotion(
      await dao.readSetting(kReduceMotionKey),
    );
    // 1.59：笔记列表是否显示首行预览（本机偏好，设置页里改）。
    noteListPreview.value =
        (await dao.readSetting(kNoteListPreviewKey)) == '1';
    // 1.47：笔记也进同步。版本用同一个 HLC 时钟，读写在笔记库目录里，
    // 和任务库互不依赖（笔记同步失败不该影响任务同步，反之亦然）。
    final notesSync = NotesSync(
      clock: dao.clock,
      persistClock: dao.persistClock,
    );
    final sync = SyncService(
      dao: dao,
      deviceName: defaultDeviceName(),
      notes: notesSync.toChannel(),
      account: normalizeAccount(await dao.readSetting(kAccountKey) ?? kDefaultAccount),
    );
    // 先显示界面，再补后台保活与通知权限：这两步要弹系统对话框，
    // 不能挡在首屏前面（也失败得起 —— 见 BackgroundKeepAlive 里的说明）。
    runApp(
      PNoteApp(
        dao: dao,
        sync: sync,
        initialThemeMode: themeMode,
        initialReduceMotion: reduceMotion,
      ),
    );
    await _enableKeepAlive();
  } catch (e) {
    runApp(StartupErrorApp(error: e));
  }
}

/// 让手机在后台也不被系统冻结（问题 1 的修复点）。
/// 只对 Android 生效；Windows 上 KeepAlive 的方法一律安全返回 false。
Future<void> _enableKeepAlive() async {
  if (!BackgroundKeepAlive.isSupported) return;
  await BackgroundKeepAlive.start();
  if (!await BackgroundKeepAlive.hasNotificationPermission()) {
    await BackgroundKeepAlive.requestNotificationPermission();
  }
  if (!await BackgroundKeepAlive.isIgnoringBatteryOptimizations()) {
    await BackgroundKeepAlive.requestIgnoreBatteryOptimizations();
  }
}

/// 对端列表里显示的设备名。用户只有两台设备，用「电脑 / 手机」最好认。
String defaultDeviceName() {
  if (Platform.isWindows) return '电脑';
  if (Platform.isAndroid) return '手机';
  if (Platform.isMacOS) return 'Mac';
  if (Platform.isLinux) return 'Linux';
  return '设备';
}
