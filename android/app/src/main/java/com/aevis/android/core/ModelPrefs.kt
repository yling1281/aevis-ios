package com.aevis.android.core
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

import android.content.Context

/**
 * 默认模型（2026-11-15）。
 *
 * 原来聊天页把模型写死在代码里，切了也不保存。现在存下来，
 * 聊天页每次发消息读一次 —— 换模型是「设一次，以后都用它」。
 */
object ModelPrefs {

    private const val P = "aevis_model"
    private const val KEY = "current"
    const val DEFAULT = "deepseek-flash"

    private var ctxRef: Context? = null

    fun init(ctx: Context) {
        ctxRef = ctx.applicationContext
    }

    fun current(): String =
        ctxRef?.getSharedPreferences(P, Context.MODE_PRIVATE)
            ?.getString(KEY, DEFAULT)?.takeIf { it.isNotBlank() } ?: DEFAULT

    /** 变更计数（R-07）：给 Compose 当订阅点用。*/
    var version by androidx.compose.runtime.mutableIntStateOf(0)
        private set

    fun set(id: String) {
        ctxRef?.getSharedPreferences(P, Context.MODE_PRIVATE)
            ?.edit()?.putString(KEY, id)?.apply()
        version++
    }
}
