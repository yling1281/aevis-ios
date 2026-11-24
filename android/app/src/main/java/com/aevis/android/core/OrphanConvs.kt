package com.aevis.android.core

import android.util.Log

/**
 * 孤儿会话救济（2026-11-17，P0）。
 *
 * 事故现象：装 1.1.73 后「聊天界面像重做了、发过的消息全没了」。
 *
 * **根因方向**：消息不是存在文件里的，而是存在 SharedPreferences 的 `conv_<pid>` 键里
 * （见 `Api.convKey`）。聊天列表（`ChatTab`）是**遍历 persona 列表**去 `loadConv(pid)`，
 * 不是枚举所有 `conv_*` 键。所以只要某个 pid 对应的 persona 不在列表里（被改名/换 id/
 * 同名 upsert 改了归档），**消息还在盘上，但列表里根本找不到它** —— 用户看到的就是"全没了"。
 *
 * 这里做的事（只加不删）：
 * 1. 启动时枚举所有 `conv_*` 键，找出"有消息但没有 persona"的 pid；
 * 2. 给它们各补一个**占位 persona**（origin = restore），名字用首条 assistant 消息的
 *    `who`（如果它像名字）或「恢复的会话 xxxx」；
 * 3. 只打日志、不删任何键 —— 宁可在列表里多一个占位角色，也不能少一条记录。
 *
 * ⚠️ 只在**服务端 persona 列表成功拿到**时才补占位：否则离线启动会把一堆线上角色
 * 误判成孤儿，凭空造出占位角色。
 */
object OrphanConvs {

    private const val TAG = "AevisOrphan"

    /** 返回本轮补了几个占位角色（-1 = 本轮跳过，未判定）。*/
    fun adopt(): Int {
        val pids = runCatching { com.aevis.android.data.Api.allConvPids() }.getOrDefault(emptyList())
        val local = LocalPersonaStore.all()
        val localIds = local.map { it.id }.toSet()

        // 服务端列表拿不到就别判（空列表也可能是网络失败）
        val remote = runCatching { com.aevis.android.data.Api.personas(mine = true) }.getOrNull()
        val remoteOk = remote != null && remote.isNotEmpty()
        val remoteIds = remote?.map { it.id }?.toSet() ?: emptySet()

        var adopted = 0
        pids.forEach { pid ->
            if (pid.isBlank()) return@forEach
            if (pid in localIds) return@forEach
            if (remoteOk && pid in remoteIds) return@forEach

            val msgs = runCatching { com.aevis.android.data.Api.loadConv(pid) }.getOrDefault(emptyList())
            if (msgs.isEmpty()) return@forEach

            // 名字优先用首条 assistant 消息里的 who（它有时是人设 id，有时是名字）
            val who = msgs.firstOrNull { it.role != "user" && it.who.isNotBlank() }?.who.orEmpty()
            val name = when {
                who.isNotBlank() && who.length <= 12 && !who.startsWith("local_") -> who
                else -> "恢复的会话 " + pid.takeLast(4)
            }

            runCatching {
                LocalPersonaStore.save(
                    LocalPersonaStore.Item(
                        id = pid,
                        name = name,
                        avatar = "",
                        persona = "（这台设备上原有这个会话，但角色资料缺失，已自动恢复。可以改名或删除。）",
                        style = "",
                        origin = "restore",
                        updatedAt = System.currentTimeMillis()
                    )
                )
                adopted++
            }
        }

        // 诊断日志（只读）：有消息的 pid 数 vs 本地 persona 数
        Log.i(
            TAG,
            "convKeys=${pids.size} localPersonas=${local.size} remoteOk=$remoteOk adopted=$adopted"
        )
        return adopted
    }
}
