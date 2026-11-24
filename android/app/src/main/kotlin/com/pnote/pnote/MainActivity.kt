package com.pnote.pnote

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter 与 Android 原生之间唯一的桥：只做四件事 ——
 *   1. 开/关「后台保活」前台服务；
 *   2. 查/申请「忽略电池优化」（MIUI 等定制系统上，光有前台服务还不够）；
 *   3. 查/申请通知权限（Android 13+ 不加通知，前台服务的通知会看不见）；
 *   4. 上报当前是否真的在跑前台服务，方便界面上如实显示。
 *
 * Dart 侧见 lib/platform/keep_alive.dart。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "pnote/background"
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    SyncForegroundService.start(this)
                    result.success(true)
                }
                "stop" -> {
                    SyncForegroundService.stop(this)
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())
                "hasNotificationPermission" -> result.success(hasNotificationPermission())
                "requestNotificationPermission" -> requestNotificationPermission()
                else -> result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /** 系统会弹一个「是否允许忽略电池优化」的确认框；用户不同意也不影响前台服务。 */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                },
            )
            true
        } catch (e: Exception) {
            // 部分机型没有这个设置页，退回「应用详情」让用户手动找。
            try {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    },
                )
            } catch (_: Exception) {
            }
            false
        }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (hasNotificationPermission()) return
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST_CODE,
        )
    }

    companion object {
        private const val NOTIFICATION_REQUEST_CODE = 4001
    }
}
