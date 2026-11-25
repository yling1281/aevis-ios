package com.aevis.android.core

import android.content.Context
import com.aevis.android.data.Api
import org.json.JSONObject

/**
 * 增长链接硬缓存（2026-11-25，对标 iOS HardCache）。
 *
 * 服务端 `/v1/growth/config` 的四个链接可后台热更新 —— 客户端不写死 URL：
 * 每次进设置页 force 拉一次，成功即覆盖；断网 / 失败用上次缓存，绝不退回空串或写死地址。
 */
object GrowthCache {
    private const val KEY = "growth_config_v1"

    fun load(ctx: Context): Api.GrowthConfig {
        val raw = SecureCache.getText(ctx, KEY) ?: return Api.GrowthConfig()
        return runCatching {
            val o = JSONObject(raw)
            Api.GrowthConfig(
                groupJoinUrl = o.optString("groupJoinUrl"),
                wechatWorkUrl = o.optString("wechatWorkUrl"),
                activityUrl = o.optString("activityUrl"),
                inviteBaseUrl = o.optString("inviteBaseUrl"),
                ok = true
            )
        }.getOrDefault(Api.GrowthConfig())
    }

    fun save(ctx: Context, c: Api.GrowthConfig) {
        if (!c.ok) return
        runCatching {
            SecureCache.putText(
                ctx, KEY,
                JSONObject()
                    .put("groupJoinUrl", c.groupJoinUrl)
                    .put("wechatWorkUrl", c.wechatWorkUrl)
                    .put("activityUrl", c.activityUrl)
                    .put("inviteBaseUrl", c.inviteBaseUrl)
                    .toString()
            )
        }
    }
}
