package com.aevis.android.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import org.json.JSONObject
import java.util.Locale

/**
 * 中英文（2026-11-14 用户：「iOS 帮我做下多语言适配，中英文要，安卓也要，小程序也要」）。
 *
 * **为什么用「中文原文当 key」而不是 strings.xml**：
 * 这个 App 的文案是直接写在界面代码里的（一百多处），换成 `R.string.xxx`
 * 要重写每一处调用、还要另起一套 key 命名，改漏一处就是空白。
 * 这里 key 就是中文原文：中文时原样返回（**零风险**），英文时查表，
 * 查不到退回中文（不会空白、不会崩）。词典在 `assets/i18n/zh-en.json`，
 * 跟 iOS / 小程序共用同一份，改文案不用动代码。
 *
 * 默认跟随系统语言，用户可以在「我 → 语言」里手动钉住（会落盘）。
 */
object I18n {

    /** 读它 = 订阅「语言变了」。`MainActivity` 里 `key(tick, I18n.version)` 重建整棵树。*/
    var version by mutableIntStateOf(0)
        private set

    @Volatile
    private var en: Map<String, String> = emptyMap()

    /** "zh" / "en" */
    @Volatile
    var lang: String = "zh"
        private set

    private const val PREFS = "aevis_i18n"

    fun init(ctx: Context) {
        if (en.isEmpty()) {
            runCatching {
                val text = ctx.assets.open("i18n/zh-en.json")
                    .bufferedReader().use { it.readText() }
                val obj = JSONObject(text)
                val m = HashMap<String, String>(obj.length())
                for (k in obj.keys()) {
                    if (k.startsWith("_")) continue   // _meta 之类
                    m[k] = obj.optString(k)
                }
                en = m
            }
        }
        // 手动选过就以手动为准，没选过才跟随系统
        val saved = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("lang", "").orEmpty()
        lang = saved.ifEmpty {
            if (Locale.getDefault().language.startsWith("zh")) "zh" else "en"
        }
    }

    /** 纯切换（不落盘）。*/
    fun setLang(l: String) {
        if (l == lang) return
        lang = l
        version++
    }

    /** 用户在「我 → 语言」里选 —— 落盘，下次启动直接用它。*/
    fun setLang(ctx: Context, l: String) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString("lang", l).apply()
        setLang(l)
    }

    /** 当前语言的名字，给设置行显示。*/
    fun label(): String = if (lang == "zh") "简体中文" else "English"

    /** 纯文案。`tr("登录")` */
    fun tr(zh: String): String = if (lang == "zh") zh else en[zh] ?: zh

    /**
     * 带变量的文案，词表里写成 `%s` / `%d`。
     * `tr("编号 %s", id)` —— 英文没翻到时退回中文并用原文格式化。
     */
    fun tr(zh: String, vararg args: Any?): String {
        val s = tr(zh)
        if (args.isEmpty()) return s
        return try {
            String.format(s, *args)
        } catch (e: Exception) {
            s
        }
    }
}
