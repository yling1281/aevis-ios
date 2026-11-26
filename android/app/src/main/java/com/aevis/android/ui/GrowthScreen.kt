package com.aevis.android.ui

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.GrowthCache
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 社区与活动页（2026-11-25，对标 iOS GrowthView）。
 *
 * 四个链接（群聊 / 企微客服 / 活动 / 邀请）从 `/v1/growth/config` 热拉取，
 * 每次进页面 force 刷新，断网用硬缓存兜底 —— 不写死 URL、不编造活动。
 * 另有：活动列表、邀请码绑定、对话日志（用户可见部分）。
 */
@Composable
fun GrowthScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val ink = MaterialTheme.colorScheme.onSurface
    val cached = remember { GrowthCache.load(ctx) }
    var cfg by remember { mutableStateOf(cached) }
    var activities by remember { mutableStateOf<List<Api.GrowthActivity>>(emptyList()) }
    var offline by remember { mutableStateOf(false) }
    var inviteCode by remember { mutableStateOf("") }
    var logs by remember { mutableStateOf<List<Api.ChatLogEntry>>(emptyList()) }

    LaunchedEffect(Unit) {
        // force 刷新 config；失败用缓存
        val fresh = withContext(Dispatchers.IO) { runCatching { Api.growthConfig() }.getOrNull() }
        if (fresh != null && fresh.ok) {
            cfg = fresh
            GrowthCache.save(ctx, fresh)
            offline = false
        } else if (cached.ok) {
            offline = true
        }
        activities = withContext(Dispatchers.IO) {
            runCatching { Api.growthActivities() }.getOrDefault(emptyList())
        }
        logs = withContext(Dispatchers.IO) {
            runCatching { Api.chatLogs().first }.getOrDefault(emptyList())
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = tr("社区与活动"), onBack = onBack)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            if (offline) {
                Text(
                    tr("连不上服务器，正在显示本地缓存"),
                    fontSize = V2.micro, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
                )
            }

            // ---- 入口链接（有才显示，不写死 URL；2026-11-25 按 flag 门禁）----
            val links = buildList {
                if (Api.featureEnabled("growth")) {
                    add(tr("加入群聊") to cfg.groupJoinUrl)
                    add(tr("活动中心") to cfg.activityUrl)
                }
                // 企微客服 = 工单入口；企微二维码单独一个开关
                if (Api.featureEnabled("tickets")) add(tr("企业微信客服") to cfg.wechatWorkUrl)
                if (Api.featureEnabled("wecomQr")) {
                    add(tr("扫码联系客服") to (
                        if (cfg.wechatWorkQrUrl.startsWith("http")) cfg.wechatWorkQrUrl
                        else Api.baseUrl() + cfg.wechatWorkQrUrl
                    ))
                }
                if (Api.featureEnabled("invite")) add(tr("邀请好友") to cfg.inviteBaseUrl)
            }.filter { it.second.isNotEmpty() }
            if (links.isNotEmpty()) {
                V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp), pad = 0.dp) {
                    links.forEachIndexed { i, (label, url) ->
                        if (i > 0) androidx.compose.material3.HorizontalDivider(
                            Modifier.padding(start = V2.gutter), thickness = 0.5.dp,
                            color = ink.copy(alpha = 0.07f)
                        )
                        Row(
                            Modifier.fillMaxWidth()
                                .tapable { openUrl(ctx, url) }
                                .padding(horizontal = V2.gutter, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(label, fontSize = V2.body, modifier = Modifier.weight(1f))
                            androidx.compose.material3.Icon(
                                painterResource(R.drawable.ic_chevron_right), null,
                                tint = ink.copy(alpha = 0.3f), modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                }
            } else {
                Text(
                    tr("暂无可用入口（后台未下发链接）"),
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.42f),
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 16.dp)
                )
            }

            // ---- 邀请码绑定（invite 开关）----
            if (Api.featureEnabled("invite")) {
            Spacer(Modifier.height(14.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Text(tr("绑定邀请码"), fontSize = V2.sub, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                androidx.compose.foundation.text.BasicTextField(
                    value = inviteCode, onValueChange = { inviteCode = it },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = V2.body, color = ink
                    ),
                    modifier = Modifier.fillMaxWidth()
                        .background(ink.copy(alpha = 0.05f))
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                )
                Spacer(Modifier.height(10.dp))
                Box(
                    Modifier.fillMaxWidth().clip(squircle(12.dp))
                        .background(if (inviteCode.isNotBlank()) V2.accent else ink.copy(alpha = 0.06f))
                        .tapable(enabled = inviteCode.isNotBlank()) {
                            val code = inviteCode.trim()
                            kotlinx.coroutines.MainScope().launch {
                                val r = withContext(Dispatchers.IO) { runCatching { Api.bindInvite(code) }.getOrNull() }
                                Toast.makeText(
                                    ctx,
                                    if (r?.ok == true) tr("绑定成功，+%d 墨点", r.points)
                                    else (r?.message ?: tr("绑定失败")),
                                    Toast.LENGTH_SHORT
                                ).show()
                            }
                        }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(tr("绑定"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                        color = if (inviteCode.isNotBlank()) Color.White else ink.copy(alpha = 0.4f))
                }
            }
            }

            // ---- 活动列表 ----
            if (Api.featureEnabled("growth") && activities.isNotEmpty()) {
                Spacer(Modifier.height(14.dp))
                Text(tr("进行中的活动"), fontSize = V2.sub, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = V2.gutter))
                V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp), pad = 0.dp) {
                    activities.forEachIndexed { i, a ->
                        if (i > 0) androidx.compose.material3.HorizontalDivider(
                            Modifier.padding(start = V2.gutter), thickness = 0.5.dp,
                            color = ink.copy(alpha = 0.07f)
                        )
                        Column(
                            Modifier.fillMaxWidth()
                                .then(if (a.url.isNotEmpty()) Modifier.tapable { openUrl(ctx, a.url) } else Modifier)
                                .padding(horizontal = V2.gutter, vertical = 12.dp)
                        ) {
                            Text(a.title.ifBlank { tr("活动") }, fontSize = V2.body,
                                fontWeight = FontWeight.Medium)
                            if (a.summary.isNotEmpty()) {
                                Spacer(Modifier.height(3.dp))
                                Text(a.summary, fontSize = V2.micro, color = ink.copy(alpha = 0.5f))
                            }
                            if (a.rewardPoints > 0) {
                                Spacer(Modifier.height(3.dp))
                                Text(tr("奖励 %d 墨点", a.rewardPoints), fontSize = V2.micro,
                                    color = pointAccentColor())
                            }
                        }
                    }
                }
            }

            // ---- 对话日志（第一页，growth 开关）----
            if (Api.featureEnabled("growth") && logs.isNotEmpty()) {
                Spacer(Modifier.height(14.dp))
                Text(tr("对话记录"), fontSize = V2.sub, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = V2.gutter))
                V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp), pad = 0.dp) {
                    logs.take(20).forEachIndexed { i, e ->
                        if (i > 0) androidx.compose.material3.HorizontalDivider(
                            Modifier.padding(start = V2.gutter), thickness = 0.5.dp,
                            color = ink.copy(alpha = 0.07f)
                        )
                        Column(Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 10.dp)) {
                            Text(
                                (if (e.role == "user") tr("我") else tr("助手")) +
                                    if (e.createdAt.isNotEmpty()) " · ${e.createdAt}" else "",
                                fontSize = V2.micro, color = ink.copy(alpha = 0.4f)
                            )
                            Spacer(Modifier.height(3.dp))
                            Text(e.content, fontSize = V2.tiny, color = ink.copy(alpha = 0.75f),
                                maxLines = 4)
                        }
                    }
                }
            }

            Spacer(Modifier.height(30.dp))
        }
    }
}
