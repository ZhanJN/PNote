package com.pnote.pnote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 让 App 在切到后台时不被系统「冻结」的前台服务。
 *
 * 为什么需要它：Android 会把处于后台的普通应用进程放进 freezer cgroup
 * （/sys/fs/cgroup/apps/uid_xxx/pid_yyy/cgroup.freeze = 1）。被冻结的进程
 * 一个线程都不跑，于是「TCP 能连上、但没人应答 WebSocket 握手」——
 * 现象就是电脑点同步，等 5 秒后超时。
 *
 * 前台服务把进程的 procstate 提到 FOREGROUND_SERVICE，系统就不会冻结它，
 * 代价是必须常驻一条通知（这是 Android 的硬性规则，不是我们想加广告）。
 */
class SyncForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 1.16：用户从通知栏点「暂停后台同步」时走这里 —— 明确停掉，不再重启。
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // 被系统杀掉后自动重启，尽量保持「随时能被另一台设备连上」。
        return START_STICKY
    }

    // 1.16 起**不再**在用户划掉最近任务时停掉自己。
    //
    // 1.12–1.15 的实现里有 onTaskRemoved { stopSelf() }，本意是"划掉 App 就
    // 不留幽灵通知"。但这与后台同步的目标直接冲突：用户划掉卡片后进程还挂在
    // 缓存里，服务已经停了 —— 于是电脑按同步必然超时，而用户以为 App 还在。
    // 现在改成：划掉卡片只关界面，同步服务继续跑；要停就点通知上的
    // 「暂停后台同步」（或者在系统设置里强行停止）。

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "局域网同步",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持 PNote 在后台也能被另一台设备同步"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        // 1.16：给用户一个明确的「我不想要后台同步了」的开关。
        // 以前是靠"划掉 App"来表达，结果和后台同步互相打架；现在改成点这个按钮。
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, SyncForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_close_clear_cancel,
            "暂停后台同步",
            stopIntent,
        ).build()
        return builder
            .setContentTitle("PNote同步中")
            .setContentText("保持后台运行")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(openApp)
            .addAction(stopAction)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "pnote_sync"
        private const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.pnote.pnote.action.STOP_KEEP_ALIVE"

        fun start(context: Context) {
            val intent = Intent(context, SyncForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SyncForegroundService::class.java))
        }
    }
}
