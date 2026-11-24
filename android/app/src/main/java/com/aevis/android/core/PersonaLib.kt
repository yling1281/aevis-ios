package com.aevis.android.core

import com.aevis.android.data.Api

/**
 * 「我的角色」这一层的**唯一入口**（2026-11-16）。
 *
 * 用户把规则说得很死：
 *   · **广场只浏览**，点进去只看得见设定，不写任何东西；
 *   · 只有点过「下载到本地」的、以及自己「创建」的，才算「我的」；
 *   · 下载之后可以改（头像 / 性格 / 说话风格），改的是**本地那一份**，不动广场原始数据。
 *
 * 所以列表口径不能再是 `Api.contacts()`（那是老逻辑：领养记录 + 聊过的 + 兜底全站 20 个），
 * 而是这里的两份合并：本地库（[LocalPersonaStore]）∪ 服务端「我发布的」（`mine=true`）。
 *
 * ⚠️ [merged] 里有网络请求，**调用方必须放在 IO 线程**（`withContext(Dispatchers.IO)`）。
 *    故意不在这里自己切线程：UI 层经常要把「拉列表 + 读最近消息」放在同一个 IO 块里做完，
 *    内部再切一次只会多一层调度，还容易把取消信号吞掉。
 */
object PersonaLib {

    /**
     * **读路径：只读本地，绝不出网**（2026-11-16，121 追加架构约束）。
     *
     * 用户原话：「聊天记录和人设应该在本地存档，一般不需要加载，为了流畅本地要有硬缓存」。
     * 所以列表页 / 群成员 / 聊天页选人，**一律用这个**：
     * 本地库（[LocalPersonaStore]）里有什么就显示什么，一个网络请求都不发。
     * 云端那份只在「本地为空」时由 [restoreFromCloud] 写进来 —— 那是恢复，不是读。
     *
     * 跟 [merged] 的区别就在这：`merged` 会顺带拉 `/v1/psquare/mine`，
     * 进页面就等网络 = 飞行模式下白屏。那条路径现在**只留给诊断/兜底**，UI 不要用。
     */
    fun localList(): List<Api.Persona> = LocalPersonaStore.all().map { toPersona(it) }

    /**
     * 本地 ∪ 服务端（mine=true），按 id 去重。
     *
     * ⚠️ 2026-11-16（121）：**UI 读路径不要再用它** —— 它会发网络请求，
     *    违反「本地优先、不能在首屏等网络」。留着是给"诊断/手动刷新"这类场景兜底用。
     */
    fun merged(): List<Api.Persona> {
        // 服务端失败就当空 —— 没网的时候本地库必须照样能用，这是底线
        val remote = runCatching { Api.personas(mine = true) }.getOrElse { emptyList() }
        val local = LocalPersonaStore.all()          // 已按 updatedAt 倒序
        val localIds = HashSet<String>(local.size)
        local.forEach { localIds.add(it.id) }

        val out = ArrayList<Api.Persona>(local.size + remote.size)
        local.forEach { out.add(toPersona(it)) }
        remote.forEach { if (!localIds.contains(it.id)) out.add(it) }
        return out
    }

    /**
     * 本地一条 → 界面用的 [Api.Persona]。
     *
     * 字段映射是刻意的：
     *   · `tagline` 装 `persona` —— 整个 UI（列表副标题、详情页「性格」）都读 `tagline`，
     *     这样不用给 `Persona` 加字段，也不用改任何一处现有界面；
     *   · `official = false` / `adopt = 0` / `relation = ""` —— 本地这份没有官方标记、
     *     没有领养计数、没有服务端关系，**宁可空着也不编一个假的**。
     */
    fun toPersona(item: LocalPersonaStore.Item): Api.Persona = Api.Persona(
        id = item.id,
        name = item.name,
        tagline = item.persona,
        avatar = item.avatar,
        adopt = 0,
        official = false,
        relation = ""
    )

    /** 本地这份（没有下载/没创建过返回 null）。*/
    fun localOf(id: String): LocalPersonaStore.Item? = LocalPersonaStore.find(id)

    /**
     * 聊天系统提示词用的「人设」。
     *
     * 优先级：本地 persona → 本地 style → 服务端 tagline（[fallbackTagline]）。
     * 为什么带上 style：只写了说话风格、没写性格的角色很常见
     * （用户建角色时就是想「它说话这样」），这种时候至少得把风格喂给模型，
     * 不然它就是个没有特征的通用助手。
     */
    fun personaText(id: String, fallbackTagline: String): String {
        val it = LocalPersonaStore.find(id) ?: return fallbackTagline
        if (it.persona.isNotBlank()) return it.persona
        if (it.style.isNotBlank()) return it.style
        return fallbackTagline
    }

    /** 说话风格（本地才有，服务端没有这个字段）。没有返回空串。*/
    fun styleText(id: String): String =
        LocalPersonaStore.find(id)?.style?.trim().orEmpty()

    /**
     * 把「我的角色」从云端写回本地（2026-11-16，121）。
     *
     * 用户：「云端的那个人设也要自动下载」—— 重装/换机后本地库是空的，
     * 但服务端 `persona_public WHERE account_id=?`（`/v1/psquare/mine`）还留着。
     *
     * `force = false`：**本地已有角色就什么都不做**（不覆盖用户的二改）。
     * `force = true`：设置页手动触发，按 id 覆盖写。
     *
     * 返回 `(恢复数量, 错误文案)`。字段映射跟 [toPersona] 保持同一口径：
     * 服务端的 `tagline` 在这里就是「人设正文」。
     * 服务端没有 `style`（说话风格只在本地），所以恢复出来的角色 style 是空的 ——
     * 宁可空，也不编一个假的风格。
     */
    fun restoreFromCloud(force: Boolean = false): Pair<Int, String> {
        if (!force && LocalPersonaStore.all().isNotEmpty()) return 0 to ""
        val (remote, err) = Api.personasMine()
        if (err.isNotBlank()) return 0 to err
        if (remote.isEmpty()) return 0 to ""
        var n = 0
        remote.forEach { p ->
            if (p.id.isBlank()) return@forEach
            runCatching {
                LocalPersonaStore.save(
                    LocalPersonaStore.Item(
                        id = p.id,
                        name = p.name.ifBlank { "未命名角色" },
                        avatar = p.avatar,
                        persona = p.tagline,
                        style = "",
                        origin = "square",
                        updatedAt = 0L   // save() 内部会补成当前时间
                    )
                )
                n++
            }
        }
        return n to ""
    }
}
