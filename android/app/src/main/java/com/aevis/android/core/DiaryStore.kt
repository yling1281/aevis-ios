package com.aevis.android.core

import android.content.Context
import com.aevis.android.data.Api
import org.json.JSONArray
import org.json.JSONObject

/**
 * AI 日记 / 周记（2026-11-15）。
 *
 * 用户：「还会主动写日记，不是要我说，他会主动写日记和周记的，就是每天都会写」。
 *
 * **为什么在客户端生成**：聊天记录存在手机本地（`Api.loadConv`），
 * 服务器拿不到对话内容，后端生成只能瞎编。所以放在客户端：
 * 本地有完整历史 → 拼成提示词 → 调 `/v1/chat/completions` → 存本地。
 * 好处是隐私不出手机，坏处是换设备看不到（以后做云端同步再说）。
 *
 * **「主动」怎么实现**：不靠后台定时（国产 ROM 会把 WorkManager 杀掉，
 * 还费电）。改成**打开 App 时检查**：今天还没写、而且今天聊过，就自动补一篇。
 * 用户感知上就是「它自己写了」。
 */
object DiaryStore {

    private const val P = "aevis_diary"

    data class Entry(
        val pid: String,
        val name: String,
        val date: String,
        val kind: String,      // day / week
        val content: String,
        val at: Long
    )

    private var ctxRef: Context? = null

    fun init(ctx: Context) {
        ctxRef = ctx.applicationContext
    }

    private fun prefs() = ctxRef!!.getSharedPreferences(P, Context.MODE_PRIVATE)

    private fun today() = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        .format(java.util.Date())

    // ---------------- 读写 ----------------


    /**
     * 去掉 emoji。
     *
     * 模型写日记爱夹表情符号，而系统字体多半没有对应的彩色字形，
     * 渲染出来就是一串「~」或豆腐块（用户截图里全是这样）。
     * 日记要的是文字，表情去掉反而更干净。
     */
    private fun stripEmoji(s: String): String {
        val noEmoji = s.replace(
            Regex("[\uD83C-\uD83E\uD800-\uDFFF\u2600-\u27BF\uFE0F\u200D]"),
            ""
        )
        // 顺手把多出来的空格收一下
        return noEmoji.replace(Regex(" {2,}"), " ").replace(" ", " ").trim()
    }

    fun list(pid: String? = null, kind: String = "day"): List<Entry> {
        val raw = prefs().getString("rows", "") ?: return emptyList()
        if (raw.isBlank()) return emptyList()
        val out = ArrayList<Entry>()
        runCatching {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("kind") != kind) continue
                if (pid != null && o.optString("pid") != pid) continue
                out.add(
                    Entry(
                        pid = o.optString("pid"),
                        name = o.optString("name"),
                        date = o.optString("date"),
                        kind = o.optString("kind"),
                        content = o.optString("content"),
                        at = o.optLong("at")
                    )
                )
            }
        }
        return out.sortedByDescending { it.date }
    }

    private fun saveAll(rows: List<Entry>) {
        val arr = JSONArray()
        rows.forEach {
            arr.put(
                JSONObject()
                    .put("pid", it.pid).put("name", it.name)
                    .put("date", it.date).put("kind", it.kind)
                    .put("content", it.content).put("at", it.at)
            )
        }
        prefs().edit().putString("rows", arr.toString()).apply()
    }

    fun has(pid: String, date: String, kind: String): Boolean =
        list(pid, kind).any { it.date == date }

    // ---------------- 生成 ----------------

    /**
     * 给一个人设补写今天的日记。今天没聊过、或已经写过，直接返回 null。
     * 这是阻塞调用，必须放到 IO 线程。
     */
    fun makeDay(pid: String, name: String): Entry? {
        val conv = Api.loadConv(pid)
        if (conv.isEmpty()) return null                 // 今天没聊过，不编
        val d = today()
        if (has(pid, d, "day")) return null             // 写过就不重复（省钱）

        val convo = conv.takeLast(30).joinToString("\n") { m ->
            (if (m.role == "user") "对方" else name.ifBlank { "我" }) + "：" + m.content
        }
        val prompt = "你是「${name.ifBlank { "AI" }}」。请用**你自己的第一人称口吻**写一篇今天的日记，" +
            "记录和对方相处的感受。200-300 字，口语化，要有具体细节（提到今天聊过的内容），" +
            "不要写成总结报告，不要分点，不要标题。\n\n今天的对话：\n$convo"

        val text = Api.chat(
            model = "deepseek-flash",
            history = listOf(Api.Msg("user", prompt))
        ) ?: return null

        val entry = Entry(pid, name, d, "day", stripEmoji(text), System.currentTimeMillis())
        val all = list(null, "day") + list(null, "week") + entry
        saveAll(all)
        return entry
    }

    /** 周记：基于最近 7 天日记写一篇。周日打开 App 时补。 */
    fun makeWeek(pid: String, name: String): Entry? {
        val days = list(pid, "day").take(7)
        if (days.size < 3) return null                  // 不到三天不写周记，太空
        val d = today()
        if (has(pid, d, "week")) return null

        val body = days.joinToString("\n\n") { "[${it.date}]\n${it.content}" }
        val prompt = "你是「${name.ifBlank { "AI" }}」。下面是你这几天的日记，请用你自己的口吻写一篇**周记**，" +
            "回顾这几天的变化和心情。250-350 字，自然口语，不要分点，不要标题。\n\n$body"

        val text = Api.chat(
            model = "deepseek-flash",
            history = listOf(Api.Msg("user", prompt))
        ) ?: return null

        val entry = Entry(pid, name, d, "week", stripEmoji(text), System.currentTimeMillis())
        saveAll(list(null, "day") + list(null, "week") + entry)
        return entry
    }

    /**
     * 打开 App 时调一次：把所有聊过的会话扫一遍，今天没写的补上。
     * 返回这次新写了几篇。
     *
     * `persons` 默认**空列表**（2026-11-16）：以前默认值是 `Api.contacts()` ——
     * 那是一次阻塞网络请求写在默认参数里，谁不小心在非 IO 线程调一下，
     * 主线程就直接卡住。现在由调用方（`DiaryScreen`）在 IO 线程拉好
     * `PersonaLib.merged()` 再传进来。
     */
    fun catchUp(persons: List<Api.Persona> = emptyList()): Int {
        var n = 0
        persons.forEach { p ->
            runCatching { if (makeDay(p.id, p.name) != null) n++ }
        }
        return n
    }
}
