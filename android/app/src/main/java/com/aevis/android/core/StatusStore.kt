package com.aevis.android.core

import android.content.Context

/**
 * 角色状态存储（2026-11-16）。
 *
 * 状态**由模型自己给**（每次回复末尾带一行 `[[状态]]…`，客户端解析后删掉那一行），
 * 不是本地关键词推断 —— 用户明确要求「调用 API 不是本地，需要模型」，而且**每个角色单独一份**。
 *
 * 存法：`SharedPreferences("aevis_status")`，key = `status_<pid>`，
 * value = `"<文案>\n<毫秒时间戳>"`（一行文案一行时间，省一个 key）。
 */
object StatusStore {

    private fun prefs() =
        com.aevis.android.data.Api.appCtx
            .getSharedPreferences("aevis_status", Context.MODE_PRIVATE)

    /** 写一条状态（pid = 人设 id / 群里的发言人 id）。*/
    fun put(pid: String, text: String) {
        val t = text.trim()
        if (t.isEmpty() || pid.isEmpty()) return
        prefs().edit()
            .putString("status_" + pid, t + "\n" + System.currentTimeMillis())
            .apply()
        lastPid = pid
        lastText = t
        lastAt = System.currentTimeMillis()
    }

    /** 读：返回 (文案, 毫秒时间戳)；没有返回 null。*/
    fun get(pid: String): Pair<String, Long>? {
        val raw = prefs().getString("status_" + pid, "").orEmpty()
        if (raw.isBlank()) return null
        val lines = raw.split("\n")
        val text = lines.getOrNull(0).orEmpty().trim()
        val at = lines.getOrNull(1)?.toLongOrNull() ?: 0L
        if (text.isEmpty()) return null
        return text to at
    }

    /** 「3 分钟前」这种相对时间；超过 30 分钟由调用方淡化，这里只负责算。*/
    fun agoMinutes(at: Long): Long =
        if (at <= 0L) Long.MAX_VALUE
        else ((System.currentTimeMillis() - at) / 60_000L).coerceAtLeast(0L)

    // ---- 给「聊天设置」页看依据用（那个页面拿不到当前会话的消息，只拿到 pid）----
    @Volatile
    var lastPid: String = ""

    @Volatile
    var lastText: String = ""

    @Volatile
    var lastAt: Long = 0L
}

/**
 * 解析并**删除**模型回复里的状态标记行（2026-11-16）。
 *
 * 容错：`[[状态]]xxx`、`【状态】xxx`、`[[状态]]：xxx`、中间带空格都认。
 * 无论是否解析到，**带标记的那一行整行都不留**（用户绝不能在任何地方看到它）。
 *
 * @return Pair(清理后的正文, 状态文案)。状态没解析到就是空串（这轮保留上一次的状态）。
 */
fun splitStatusMarker(reply: String): Pair<String, String> {
    if (reply.isEmpty()) return reply to ""
    // [[状态]] / 【状态】 / [状态] ，后跟可选冒号
    val re = Regex("[\\[【]{1,2}\\s*状态\\s*[\\]】]{1,2}\\s*[:：]?\\s*(.*)$")
    var status = ""
    val kept = ArrayList<String>()
    reply.lines().forEach { line ->
        val m = re.find(line)
        if (m == null) {
            kept.add(line)
        } else {
            if (status.isEmpty()) {
                status = m.groupValues[1]
                    .trim()
                    .trimEnd('。', '，', '！', '？', '.', ',', ' ')
                    .take(16)
            }
            // 这一行整行丢弃
        }
    }
    val body = kept.joinToString("\n").trim()
    return body to status
}
