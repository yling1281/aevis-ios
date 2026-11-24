package com.aevis.android.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import com.aevis.android.data.Api
import org.json.JSONArray
import org.json.JSONObject

/**
 * 本地群聊（2026-11-16）。
 *
 * 用户：「我要能拉一个群，几个人设一起在里面说话」。
 *
 * 后端**没有群**这层概念（人设是单人的，会话也是单人会话表），
 * 所以群和群成员先只存在本地 —— 跟 `LocalPersonaStore` 一个路数：
 * SharedPreferences 里一个 JSON 数组，字段直接对得上，取用不用转换。
 *
 * 群的 id 就是会话 id（`Api.loadConv(gid)`），所以「消息」这块完全复用现有那套，
 * 不需要另建一张消息表。
 */
object GroupStore {
    private const val F = "aevis_groups"
    private const val K = "items"

    private var sp: android.content.SharedPreferences? = null

    /**
     * 群数据版本号（2026-11-16，95）。
     *
     * 群资料页、建群页都是**二级页**：改完返回时，下面那个聊天列表 Composable
     * 并不会重建，`remember` 里的旧群列表会一直用到下次切 tab。
     * 所以每次写盘把版本 +1，列表侧 `LaunchedEffect(GroupStore.version)` 重新读一遍。
     */
    var version by mutableIntStateOf(0)
        private set

    fun init(ctx: Context) {
        sp = ctx.getSharedPreferences(F, Context.MODE_PRIVATE)
    }

    /** 一个群。`memberIds` 是人设 id 列表（顺序 = 用户勾选的顺序）。*/
    data class Group(
        val id: String,
        val name: String,
        val memberIds: List<String>,
        val updatedAt: Long,
        /**
         * 群头像（2026-11-16，95）。
         *
         * 存的是 `/v1/media/xxx.jpg` 这种**服务端相对路径**（跟人设头像同一个口径），
         * `Avatar()` 认它、按网络图缓存；空串 = 还没设，界面用首字占位。
         * 老版本写进去的群没有这个字段 —— `optString` 读出来是空串，照样能用。
         */
        val avatar: String = ""
    )

    private fun readAll(): MutableList<Group> {
        val raw = sp?.getString(K, "") ?: ""
        if (raw.isBlank()) return mutableListOf()
        return try {
            val arr = JSONArray(raw)
            val out = mutableListOf<Group>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val ids = ArrayList<String>()
                val ja = o.optJSONArray("members")
                if (ja != null) {
                    for (j in 0 until ja.length()) {
                        val id = ja.optString(j)
                        if (id.isNotEmpty()) ids.add(id)
                    }
                }
                out.add(
                    Group(
                        id = o.optString("id"),
                        name = o.optString("name"),
                        memberIds = ids,
                        updatedAt = o.optLong("updatedAt"),
                        avatar = o.optString("avatar")
                    )
                )
            }
            out
        } catch (e: Exception) {
            mutableListOf()
        }
    }

    private fun writeAll(list: List<Group>) {
        val arr = JSONArray()
        list.forEach { g ->
            val ja = JSONArray()
            g.memberIds.forEach { ja.put(it) }
            arr.put(
                JSONObject()
                    .put("id", g.id)
                    .put("name", g.name)
                    .put("members", ja)
                    .put("updatedAt", g.updatedAt)
                    .put("avatar", g.avatar)
            )
        }
        sp?.edit()?.putString(K, arr.toString())?.apply()
        version++
    }

    /** 最近活跃的群在前（`updatedAt` 倒序）。*/
    fun all(): List<Group> = readAll().sortedByDescending { it.updatedAt }

    fun find(id: String): Group? = readAll().firstOrNull { it.id == id }

    /** 同 id 覆盖。`updatedAt` 由这里统一补成当前时间，调用方传 0 就行。*/
    fun save(g: Group) {
        val list = readAll()
        val i = list.indexOfFirst { it.id == g.id }
        val now = g.copy(updatedAt = System.currentTimeMillis())
        if (i >= 0) list[i] = now else list.add(now)
        writeAll(list)
    }

    /**
     * 只改群资料（名字 / 头像），**不动 `updatedAt`**（2026-11-16，95）。
     *
     * 跟 `save()` 分开的原因：`save()` 会把时间戳刷成现在，群就跳到会话列表最前。
     * 改一个群头像不该让这个群跑到所有人上面 —— 那只有"真的聊了"才该发生。
     */
    fun updateProfile(id: String, name: String? = null, avatar: String? = null) {
        val list = readAll()
        val i = list.indexOfFirst { it.id == id }
        if (i < 0) return
        val g = list[i]
        list[i] = g.copy(
            name = name?.takeIf { it.isNotBlank() } ?: g.name,
            avatar = avatar ?: g.avatar
        )
        writeAll(list)
    }

    /** 解散：群定义 + 这个群的会话记录一起清掉。*/
    fun remove(id: String) {
        writeAll(readAll().filterNot { it.id == id })
        runCatching { Api.clearConv(id) }
    }

    fun newId(): String = "grp_" + System.currentTimeMillis()
}
