package com.aevis.android.core

import android.content.Context

/**
 * 动效手感（2026-11-15）。
 *
 * 用户原话：「视频你解不了吗？那你就弄参数吧…或者可以让用户调啊」。
 * 这里存三个数，`tapable` 和页面转场都读它。
 */
object AnimPrefs {
    private const val F = "aevis_anim"
    private var sp: android.content.SharedPreferences? = null

    fun init(ctx: Context) {
        sp = ctx.getSharedPreferences(F, Context.MODE_PRIVATE)
    }

    private fun getInt(k: String, d: Int): Int = sp?.getInt(k, d) ?: d

    /** 按下时缩到多少（80–100，代表 0.80–1.00）。*/
    var pressPct: Int
        get() = getInt("press", 94).coerceIn(80, 100)
        set(v) = sp?.edit()?.putInt("press", v.coerceIn(80, 100))?.apply() ?: Unit

    /** 页面/弹层上浮位移，dp。*/
    var shiftDp: Int
        get() = getInt("shift", 18).coerceIn(0, 40)
        set(v) = sp?.edit()?.putInt("shift", v.coerceIn(0, 40))?.apply() ?: Unit

    /** 回弹力度（25–90，代表阻尼 0.25–0.90，越小越弹）。*/
    var bouncePct: Int
        get() = getInt("bounce", 45).coerceIn(25, 90)
        set(v) = sp?.edit()?.putInt("bounce", v.coerceIn(25, 90))?.apply() ?: Unit

    val pressScale: Float get() = pressPct / 100f
    val damping: Float get() = bouncePct / 100f

    /**
     * 「点一下」到「真的跳过去」之间的等待，毫秒（2026-11-16）。
     *
     * 用户：「点击跳转的时候…你要等按下的这个弹跳的这个动作弄完才能转过去」。
     * `tapable` 是按下缩到 0.94、松手 spring 弹回（约 200ms 稳定），
     * 但 `clickable` 在抬手那一瞬就回调 —— 不等一下的话页面立刻推入，
     * 用户根本看不到"弹回来"那一下，观感就是"点一下直接闪走"。
     *
     * 140ms：肉眼已经看不出回弹没走完，再长就会觉得"点了没反应"。
     * ⚠️ 先写死常量，**不要**加进「动效手感」页（用户没要多一个滑杆）；
     *    以后真要放开，把这里换成 `getInt("navDelay", 140)` 即可。
     */
    val navDelayMs: Int get() = 140
}
