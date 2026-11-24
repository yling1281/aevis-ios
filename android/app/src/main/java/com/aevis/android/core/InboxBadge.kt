package com.aevis.android.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * 站内信未读红点（2026-11-16，104）。
 *
 * 用户：「通知要能真正提醒到人」——以前只有进站内信页才看得到未读数。
 * 现在登录后、App 回到前台时各拉一次，底部「我」tab 挂一个小红点（只显示点，不显示数字）。
 * **不做轮询**。
 */
object InboxBadge {

    /** 有没有未读（Compose 状态，Shell 直接读）。*/
    var hasUnread by mutableStateOf(false)
        private set

    /** 拉一次未读数（后台线程调用）。*/
    fun refresh() {
        if (!com.aevis.android.data.Api.signedIn()) {
            hasUnread = false
            return
        }
        val n = runCatching { com.aevis.android.data.Api.inboxUnread() }.getOrDefault(0)
        hasUnread = n > 0
    }

    /** 站内信页打开后清掉（先本地清，再上报）。*/
    fun clear() {
        hasUnread = false
        runCatching { com.aevis.android.data.Api.inboxMarkRead() }
    }
}
