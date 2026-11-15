package com.aevis.android.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

/**
 * Android 16（API 36）的 **Live Updates** —— 用户说的「安卓的灵动岛」。
 *
 * 效果：通话 / 一起听进行中时，状态栏最左边出现一颗胶囊（ProgressStyle），
 * 点它直接回到 App。Android 16 以下系统没有这个能力，`supported()` 返回 false，
 * 调用方走普通通知就行 —— **不会崩，也不会装作有**。
 *
 * 用到的都是 API 36 才有的东西：
 *  - `Notification.ProgressStyle`（胶囊里那条进度）
 *  - `Notification#FLAG_PROMOTED_ONGOING` + `Builder#setFlag(...)`（申请升级成胶囊）
 *  - `Builder#setShortCriticalText(...)`（胶囊上那行短文本）
 *  - `NotificationManager#canPostPromotedNotifications()`（系统给不给）
 *
 * ⚠️ 2026-11-14：**只打通了能力，还没有调用方** ——
 * 实时通话本体（VoIP）还没做。等通话做完，在 `CallService` 开始/结束的地方
 * 调 `LiveUpdate.start(...)` / `LiveUpdate.stop(...)` 即可。
 */
object LiveUpdate {

    /** 单独一个渠道：Live Updates 必须是不静音、不高优先级的进行中通知。*/
    private const val CHANNEL_ID = "aevis_live"
    private const val NOTIFY_ID = 0xAE715

    /** 这台机器能不能显示胶囊。**每次现查** —— 用户可以随时在设置里关掉。*/
    fun supported(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 36) return false
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return false
        return nm.canPostPromotedNotifications()
    }

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID, "进行中", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "通话、一起听这类正在进行的活动"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(ch)
    }

    /**
     * 挂一颗胶囊。
     *
     * @param title 主标题（「和零砚通话中」）
     * @param text  副标题（「00:42」这种，也会作为胶囊上的短文本）
     * @param progress 0..100，负数 = 不显示进度（只显示计时）
     */
    fun start(
        ctx: Context,
        title: String,
        text: String,
        progress: Int = -1,
        smallIcon: Int
    ): Boolean {
        if (!supported(ctx)) return false
        ensureChannel(ctx)
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return false

        val builder = Notification.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_CALL)

        // ProgressStyle 是 API 36 的类；这里已经过了 supported() 的版本判断，
        // 但编译期是按 compileSdk=36 编的，运行时只有 36+ 才会走到这一行。
        val style = Notification.ProgressStyle()
        if (progress in 0..100) {
            style.setProgress(progress)
            style.setStyledByProgress(false)
        }
        style.addProgressSegment(Notification.ProgressStyle.Segment(100))
        builder.setStyle(style)
        // 胶囊上那行短文本（时长之类，越短越好）
        runCatching { builder.setShortCriticalText(text) }
        // 关键：这个 flag 才让它升级成状态栏胶囊，不是普通通知
        builder.setFlag(Notification.FLAG_PROMOTED_ONGOING, true)

        return try {
            nm.notify(NOTIFY_ID, builder.build())
            true
        } catch (e: Exception) {
            false
        }
    }

    fun stop(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        runCatching { nm.cancel(NOTIFY_ID) }
    }
}
