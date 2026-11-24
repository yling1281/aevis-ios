package com.aevis.android.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 常驻通知 + 前台服务（2026-11-16）。
 *
 * 用户要的是"通知栏有个常驻，点开回 App"，不用真的在后台跑逻辑 ——
 * 所以这个 Service **不做事**，只负责挂一条常驻通知（`START_STICKY` 也不会做耗电的活）。
 *
 * 开关：`ChatPrefs.keepAlive`（默认开）；关掉就 stopSelf + 撤通知。
 * 正文：最近一条消息摘要（`Api.lastPreview`，在 `saveConv` 里更新）。
 */
class AeviService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = build(this, title(), body())
        // Android 14+ 前台服务必须声明类型；这里用 specialUse（纯展示通知，不做定位/媒体）
        runCatching { startForeground(ID, n) }
        return START_STICKY
    }

    /**
     * 被「最近任务」划掉后兜一次（2026-11-16）。
     *
     * vivo 上 `START_STICKY` 经常不生效，服务直接被带走。这里在 `onTaskRemoved`
     * 里用 `AlarmManager` 定一个 1 秒后的闹钟把自己拉起来 —— 比 `startForegroundService`
     * 直调更耐 Android 12+ 的后台启动限制（后台起前台服务会被拒）。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (ChatPrefs.keepAlive) {
            runCatching {
                val restart = Intent(applicationContext, AeviService::class.java)
                val pi = PendingIntent.getService(
                    this, 1, restart,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
                val am = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
                am.set(android.app.AlarmManager.RTC, System.currentTimeMillis() + 1000, pi)
            }
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        runCatching { stopForeground(true) }
        super.onDestroy()
    }

    companion object {
        const val ID = 20261116

        /** 当前活着的实例（关闭时要对它 stopForeground/stopSelf）。*/
        @Volatile
        private var instance: AeviService? = null
        private const val CH = "aevis_keepalive"

        /** 最近一条消息摘要（由 `Api.saveConv` 更新，进程内存即可，不落盘）。*/
        @Volatile
        var lastPreview: String = ""

        private fun title() = "Aevi 在等你"

        private fun body() = lastPreview.ifBlank { "点一下回来继续聊" }

        /** 建通知（8.0+ 需要 channel）。*/
        fun build(ctx: Context, title: String, text: String): Notification {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (nm.getNotificationChannel(CH) == null) {
                    nm.createNotificationChannel(
                        NotificationChannel(CH, "常驻提醒", NotificationManager.IMPORTANCE_LOW)
                            .apply {
                                setShowBadge(false)
                                enableLights(false)
                                enableVibration(false)
                            }
                    )
                }
            }
            val pi = PendingIntent.getActivity(
                ctx, 0,
                Intent(ctx, Class.forName("com.aevis.android.MainActivity"))
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(ctx, CH) else @Suppress("DEPRECATION") Notification.Builder(ctx)
            return b.setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setOngoing(true)          // 常驻，划不掉
                .setOnlyAlertOnce(true)    // 更新时不响
                .setContentIntent(pi)
                .build()
        }

        /** 开/关（MainActivity 启动时调一次；设置里切换也调）。*/
        fun apply(ctx: Context) {
            if (ChatPrefs.keepAlive) start(ctx) else stop(ctx)
        }

        fun start(ctx: Context) {
            runCatching {
                ctx.startForegroundService(Intent(ctx, AeviService::class.java))
            }.onFailure {
                runCatching { ctx.startService(Intent(ctx, AeviService::class.java)) }
            }
        }

        /** 关掉开关：先撤前台状态再停服务（只撤通知会让服务变"后台"继续活着）。*/
        fun stop(ctx: Context) {
            runCatching { ctx.stopService(Intent(ctx, AeviService::class.java)) }
            runCatching { instance?.stopForeground(true) }
            runCatching { instance?.stopSelf() }
            runCatching {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(ID)
            }
        }

        /** 上次刷通知的时间（节流用）。*/
        @Volatile
        private var lastRefreshAt = 0L

        /** 收到/发出新消息时刷新通知正文（没开开关就什么都不做）。
         *  **30 秒内最多刷一次** —— 每条消息都 notify 会一直闪，也费电。*/
        fun refresh(ctx: Context) {
            if (!ChatPrefs.keepAlive) return
            val now = System.currentTimeMillis()
            if (now - lastRefreshAt < 30_000L) return
            lastRefreshAt = now
            runCatching {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(ID, build(ctx, title(), body()))
            }
        }
    }
}
