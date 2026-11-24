package com.aevis.android.core

import android.content.Context

/**
 * 崩溃自动上报 + QQ 登录"点火日志"（2026-11-16，101）。
 *
 * 背景：QQ 登录一点就闪退，但拿不到栈（无线调试掉线、服务端也没有 qqlogin 请求 ——
 * 说明崩在 SDK 拉起阶段，根本没走到网络）。先把"以后能看见崩溃"这件事解决。
 *
 * 设计要点（按 team-lead 要求）：
 * 1. 崩溃时**先落盘再交给原 handler** —— 不吞异常，系统崩溃流程照常走；
 * 2. 只存最近 5 条，用 `\n---\n` 分隔；
 * 3. 下次启动 `flush()` 把积压的发到 `POST /v1/crash`（不需要登录），成功才清空；
 * 4. QQ 登录各步骤记 `qq_step`，随下一次 flush 一起上报（`tag=qq_step`）。
 */
object CrashReporter {

    private const val PREF = "aevis_crash"
    private const val KEY_PENDING = "crash_pending"
    private const val KEY_QQ = "qq_step"
    private const val SEP = "\n---\n"
    private const val MAX = 5

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    private var app: Context? = null

    /** 装机：接管未捕获异常 → 先落盘，再交给原来的 handler。*/
    fun install(context: Context) {
        app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            // ⚠️ 不吞异常：这里只负责"崩之前把栈写下来"
            runCatching { save(context, "crash", dump(throwable)) }
            // 交回系统原来的 handler（保持原有崩溃流程/系统弹窗）
            previous?.uncaughtException(thread, throwable)
        }
    }

    /** 把 Throwable 变成带设备信息的字符串。*/
    fun dump(t: Throwable): String {
        val sw = java.io.StringWriter()
        t.printStackTrace(java.io.PrintWriter(sw))
        return sw.toString()
    }

    /** 当前设备串（服务端会一起记录）。*/
    fun deviceInfo(): String =
        "${android.os.Build.MODEL} / Android ${android.os.Build.VERSION.RELEASE}（API ${android.os.Build.VERSION.SDK_INT}）"

    /** 记一条 QQ 登录步骤（覆盖式，只留最后一次序列）。*/
    fun step(name: String) {
        val c = app ?: return
        runCatching {
            val old = prefs(c).getString(KEY_QQ, "").orEmpty()
            val line = "${System.currentTimeMillis() % 100000} $name"
            val next = if (old.isBlank()) line else (old + " → " + line).take(600)
            prefs(c).edit().putString(KEY_QQ, next).apply()
        }
    }

    /** 写一条待上报（最多保留 5 条）。*/
    private fun save(context: Context, tag: String, stack: String) {
        val p = prefs(context)
        val old = p.getString(KEY_PENDING, "").orEmpty()
        val entry = "[$tag]\n$stack"
        val list = ArrayList<String>()
        if (old.isNotBlank()) list.addAll(old.split(SEP))
        list.add(entry)
        while (list.size > MAX) list.removeAt(0)
        p.edit().putString(KEY_PENDING, list.joinToString(SEP)).apply()
    }

    /**
     * 下次启动时调：把积压的崩溃 + QQ 步骤发到服务端，成功才清空。
     * ⚠️ 必须放后台线程（`MainActivity` 里用 Thread 包了）。
     */
    fun flush(context: Context) {
        val p = prefs(context)
        val pending = p.getString(KEY_PENDING, "").orEmpty()
        val qq = p.getString(KEY_QQ, "").orEmpty()

        var pendingOk = true
        if (pending.isNotBlank()) {
            pending.split(SEP).forEach { entry ->
                val tag = entry.substringAfter("[", "crash").substringBefore("]").ifBlank { "crash" }
                val body = entry.substringAfter("]\n", entry)
                val ok = runCatching {
                    com.aevis.android.data.Api.postCrash(tag, body, deviceInfo())
                }.getOrDefault(false)
                if (!ok) pendingOk = false
            }
        }
        if (pending.isNotBlank() && pendingOk) {
            p.edit().putString(KEY_PENDING, "").apply()
        }

        // QQ 步骤：发完就清（它是"上一次尝试"的过程记录，不需要长期保留）
        if (qq.isNotBlank()) {
            val ok = runCatching {
                com.aevis.android.data.Api.postCrash("qq_step", qq, deviceInfo())
            }.getOrDefault(false)
            if (ok) p.edit().putString(KEY_QQ, "").apply()
        }
    }
}
