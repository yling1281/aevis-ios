package com.aevis.android.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue

/**
 * 主题（2026-11-16）。
 *
 * 用户：「我想变成浅色模式，不知道怎么变，你没开那个开关」——
 * 之前 `AevisTheme` 里写死 `val dark = true`（2026-11-15 用户要「默认夜间黑」），
 * 结果就是**根本没有浅色这条路**。这里补上三档开关。
 *
 * 写法照 `AnimPrefs`（同一套 SharedPreferences + object），
 * 但多一个 `version`：`mode` 是普通 getter，改了不会自己触发重组 ——
 * `AevisTheme` 里读一次 `version` 就订阅上了，切主题立刻整棵树刷新。
 */
object ThemePrefs {
    private const val F = "aevis_theme"
    private const val K = "mode"

    private var sp: android.content.SharedPreferences? = null

    const val FOLLOW_SYSTEM = 0
    const val LIGHT = 1
    const val DARK = 2

    /** 读它 = 订阅「主题变了」。`AevisTheme` 里读一次。*/
    var version by mutableIntStateOf(0)
        private set

    /**
     * `0` 跟随系统 / `1` 浅色 / `2` 深色。**默认 0（跟随系统）**（2026-11-16，120）。
     *
     * 之前默认 `2`（深色）是为了「老用户升级不能突然变白」，但用户现在明确要
     * 「主题默认跟随系统」—— 系统是浅色的人第一次打开就该是浅色，不该先去设置里找开关。
     */
    var mode: Int
        get() = (sp?.getInt(K, FOLLOW_SYSTEM) ?: FOLLOW_SYSTEM)
            .coerceIn(FOLLOW_SYSTEM, DARK)
        set(v) {
            val n = v.coerceIn(FOLLOW_SYSTEM, DARK)
            if (n == mode) return          // 没变就别白重建一次整棵树
            sp?.edit()?.putInt(K, n)?.apply()
            version++
        }

    fun init(ctx: Context) {
        sp = ctx.getSharedPreferences(F, Context.MODE_PRIVATE)
    }

    /** 设置页里显示用的名字。*/
    fun label(m: Int): String = when (m) {
        LIGHT -> "浅色"
        DARK -> "深色"
        else -> "跟随系统"
    }
}
