package com.aevis.android.core

import android.content.Context
import com.aevis.android.data.Api
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * 广场（人设 / 表情包）磁盘硬缓存（2026-11-24，对标 iOS `PlazaCacheStore`）。
 *
 * 需求：冷启动先读本地缓存**立刻显示**，云端有更新才覆盖；连不上服务器 / 更新失败
 * 保留旧缓存（界面提示"连不上服务器"）。
 *
 * 实现要点：
 * - 走 [SecureCache]：AES 加密写 filesDir，不落明文；写失败静默，绝不影响 UI。
 * - 后端 `/v1/psquare/list`、`/v1/emoji/list` **没有 ETag / 304**，所以按内容
 *   [signature] 判断"是否真变了"：没变就不重绘、不写盘。
 * - [load] 同步读，损坏 / 缺失返回空 Payload，不抛异常。
 */
object PlazaCache {
    private const val KEY = "plaza_cache_v1"

    data class Payload(
        val personas: List<Api.Persona> = emptyList(),
        val packs: List<Api.EmojiPack> = emptyList(),
        val signature: String = "",
        val checkedAt: Long = 0L
    ) {
        val isEmpty: Boolean get() = personas.isEmpty() && packs.isEmpty()
    }

    /** 同步读缓存。JSON 损坏 / 没写过 → 空 Payload。*/
    fun load(ctx: Context): Payload {
        val raw = SecureCache.getText(ctx, KEY) ?: return Payload()
        return runCatching {
            val o = JSONObject(raw)
            val pa = o.optJSONArray("personas") ?: JSONArray()
            val personas = ArrayList<Api.Persona>(pa.length())
            for (i in 0 until pa.length()) {
                val x = pa.optJSONObject(i) ?: continue
                personas.add(
                    Api.Persona(
                        x.optString("id"), x.optString("name"), x.optString("tagline"),
                        x.optString("avatar"), x.optInt("adopt"),
                        x.optBoolean("official"), x.optString("relation")
                    )
                )
            }
            val ea = o.optJSONArray("packs") ?: JSONArray()
            val packs = ArrayList<Api.EmojiPack>(ea.length())
            for (i in 0 until ea.length()) {
                val x = ea.optJSONObject(i) ?: continue
                val ia = x.optJSONArray("items") ?: JSONArray()
                val items = ArrayList<String>(ia.length())
                for (j in 0 until ia.length()) {
                    val u = ia.optString(j)
                    if (u.isNotEmpty()) items.add(u)
                }
                packs.add(
                    Api.EmojiPack(
                        x.optString("id"), x.optString("name"), x.optString("intro"),
                        x.optString("cover"), x.optInt("count", items.size),
                        x.optBoolean("official"), items
                    )
                )
            }
            Payload(personas, packs, o.optString("signature"), o.optLong("checkedAt"))
        }.getOrDefault(Payload())
    }

    /** 写缓存。失败静默（缓存写不进去不该影响功能）。*/
    fun save(ctx: Context, payload: Payload) {
        runCatching {
            val pa = JSONArray()
            payload.personas.forEach {
                pa.put(
                    JSONObject()
                        .put("id", it.id).put("name", it.name).put("tagline", it.tagline)
                        .put("avatar", it.avatar).put("adopt", it.adopt)
                        .put("official", it.official).put("relation", it.relation)
                )
            }
            val ea = JSONArray()
            payload.packs.forEach {
                val ia = JSONArray()
                it.items.forEach { u -> ia.put(u) }
                ea.put(
                    JSONObject()
                        .put("id", it.id).put("name", it.name).put("intro", it.intro)
                        .put("cover", it.cover).put("count", it.count)
                        .put("official", it.official).put("items", ia)
                )
            }
            val o = JSONObject()
                .put("signature", payload.signature)
                .put("checkedAt", payload.checkedAt)
                .put("personas", pa)
                .put("packs", ea)
            SecureCache.putText(ctx, KEY, o.toString())
        }
    }

    /**
     * 内容签名：只覆盖会影响 UI 的字段，顺序固定。
     * FNV-1a 只为省空间，不用于安全 —— 和 iOS 同一套口径。
     */
    fun signature(personas: List<Api.Persona>, packs: List<Api.EmojiPack>): String {
        val sb = StringBuilder()
        personas.forEach {
            sb.append("p|").append(it.id).append('|').append(it.name).append('|')
                .append(it.tagline).append('|').append(it.avatar).append('|')
                .append(it.adopt).append('|').append(it.official).append('\n')
        }
        packs.forEach {
            sb.append("e|").append(it.id).append('|').append(it.name).append('|')
                .append(it.intro).append('|').append(it.cover).append('|')
                .append(it.count).append('|').append(it.items.joinToString(",")).append('\n')
        }
        var h = 0x811c9dc5L
        for (b in sb.toString().toByteArray(Charsets.UTF_8)) {
            h = (h xor (b.toLong() and 0xff)) and 0xffffffffL
            h = (h * 0x01000193L) and 0xffffffffL
        }
        return String.format(Locale.US, "%016x", h)
    }
}
