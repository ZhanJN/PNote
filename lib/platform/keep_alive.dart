import 'dart:io';

import 'package:flutter/services.dart';

/// 「后台保活」在 Dart 侧的开关。
///
/// 背景（问题 1）：Android 会把退到后台的 App 进程**冻结**
/// （`/sys/fs/cgroup/apps/uid_xxx/pid_yyy/cgroup.freeze = 1`）。冻住之后
/// 内核仍会替它完成 TCP 三次握手，但 App 一个线程都不跑，没人读那句
/// WebSocket 升级请求 —— 于是另一台设备看到的现象就是「连上了，等 5 秒，
/// 超时」。
///
/// 解法是 Android 官方的「前台服务」：进程会被标成 FOREGROUND_SERVICE，
/// 系统不再冻结它。代价是必须挂一条常驻通知（Android 的硬性规则）。
///
/// 原生实现见 `android/app/src/main/kotlin/com/pnote/pnote/SyncForegroundService.kt`
/// 与同目录的 `MainActivity.kt`；本类只是 MethodChannel 的薄封装，
/// 在非 Android 平台（Windows、测试环境）上一律安全地返回 false。
class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static const MethodChannel _channel = MethodChannel('pnote/background');

  /// 是否当前平台支持后台保活（只有 Android 走这条路）。
  static bool get isSupported => Platform.isAndroid;

  /// 拉起前台服务。返回 false 表示调用失败（例如系统限制、通道不存在），
  /// 调用方应当照常继续 —— 保活失败只是"后台收不到同步"，不影响前台使用。
  static Future<bool> start() async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('start');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 停掉前台服务（通知随之消失）。
  static Future<bool> stop() async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('stop');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 是否已被允许「忽略电池优化」。国产系统（MIUI/HyperOS）里，
  /// 光有前台服务仍可能被省电策略杀掉，这一项是用来加固的。
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 弹系统对话框申请「忽略电池优化」。用户拒绝也没关系。
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Android 13+ 是否已授予通知权限（没授权就看不见常驻通知）。
  static Future<bool> hasNotificationPermission() async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('hasNotificationPermission');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 弹系统的通知权限请求（Android 13+）。
  static Future<void> requestNotificationPermission() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on PlatformException {
      // 用户拒绝或系统不支持：忽略。
    } on MissingPluginException {
      // 非 Android 平台：忽略。
    }
  }
}
