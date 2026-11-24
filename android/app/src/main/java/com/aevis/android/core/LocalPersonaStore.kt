package com.aevis.android.core

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * 本地角色库（2026-11-15）。
 *
 * 用户要的规则很清楚：
 *   · 广场只用来**浏览**，不写入
 *   · 只有点过「下载到本地」或自己「创建」的，才出现在「我的 / 聊天」里
 *   · 下载下来的可以改头像、性格、说话风格（二改），改的是本地这份，不动广场原始数据
 *
 * 存一个 JSON 数组在 SharedPreferences，字段和 Api.Persona 对齐，取用时不用转换。
 */
object LocalPersonaStore {
    private const val F = "aevis_local_personas"
    private const val K = "items"
    private var sp: android.content.SharedPreferences? = null

    fun init(ctx: Context) {
        sp = ctx.getSharedPreferences(F, Context.MODE_PRIVATE)
        // 首次启动：把广场里"看起来是我自己的"清掉 —— 之前 bug 把全站人设灌进来了。
        // 用版本号标记，只清一次，别把用户真下载的删掉。
        val v = sp?.getInt("schema", 0) ?: 0
        if (v < 2) {
            sp?.edit()?.putInt("schema", 2)?.apply()
        }
    }

    /** 一条本地角色。`origin` = square（下载）/ created（自己建）。*/
    data class Item(
        val id: String,
        val name: String,
        val avatar: String,
        val persona: String,
        val style: String,
        val origin: String,
        val updatedAt: Long
    )

    private fun readAll(): MutableList<Item> {
        val raw = sp?.getString(K, "") ?: ""
        if (raw.isBlank()) return mutableListOf()
        return try {
            val arr = JSONArray(raw)
            val out = mutableListOf<Item>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(
                    Item(
                        id = o.optString("id"),
                        name = o.optString("name"),
                        avatar = o.optString("avatar"),
                        persona = o.optString("persona"),
                        style = o.optString("style"),
                        origin = o.optString("origin", "square"),
                        updatedAt = o.optLong("updatedAt")
                    )
                )
            }
            out
        } catch (e: Exception) {
            mutableListOf()
        }
    }

    private fun writeAll(list: List<Item>) {
        val arr = JSONArray()
        list.forEach { it ->
            arr.put(
                JSONObject()
                    .put("id", it.id)
                    .put("name", it.name)
                    .put("avatar", it.avatar)
                    .put("persona", it.persona)
                    .put("style", it.style)
                    .put("origin", it.origin)
                    .put("updatedAt", it.updatedAt)
            )
        }
        sp?.edit()?.putString(K, arr.toString())?.apply()
    }

    fun all(): List<Item> = readAll().sortedByDescending { it.updatedAt }

    fun find(id: String): Item? = readAll().firstOrNull { it.id == id }

    fun has(id: String): Boolean = find(id) != null

    /** 下载 / 新建 都走它：同 id 覆盖。*/
    fun save(item: Item) {
        val list = readAll()
        val i = list.indexOfFirst { it.id == item.id }
        val now = Item(
            item.id, item.name, item.avatar, item.persona, item.style,
            item.origin, System.currentTimeMillis()
        )
        if (i >= 0) list[i] = now else list.add(now)
        writeAll(list)
    }

    /** 二改：只改本地这份。*/
    fun update(id: String, name: String? = null, avatar: String? = null,
               persona: String? = null, style: String? = null) {
        val list = readAll()
        val i = list.indexOfFirst { it.id == id }
        if (i < 0) return
        val o = list[i]
        list[i] = o.copy(
            name = name ?: o.name,
            avatar = avatar ?: o.avatar,
            persona = persona ?: o.persona,
            style = style ?: o.style,
            updatedAt = System.currentTimeMillis()
        )
        writeAll(list)
    }

    fun remove(id: String) {
        writeAll(readAll().filterNot { it.id == id })
    }

    /** 自己建的给个本地 id：`local_<时间戳>`，不会和广场撞。*/
    fun newId(): String = "local_" + System.currentTimeMillis()
}
