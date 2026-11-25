package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api

/**
 * 角色设置页（2026-11-16，88，路由 `roleset:<pid>`）。
 *
 * 用户给了参考图：点聊天页右上角 `⋯` 直接进这一页 —— 头部是这样一个人，
 * 下面是「认识天数 / 消息 / 表情」三格统计，再下面是三张常用卡。
 * 「聊天设置」那张卡打开底部半窗（[ChatSettingsSheet] 里的 B 部分）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoleSetScreen(
    pid: String,
    onBack: () -> Unit,
    onOpenPersona: () -> Unit,
    // 资源库（129）
    onOpenLibrary: () -> Unit = {}
) {
    val ink = MaterialTheme.colorScheme.onSurface
    // R-06：订阅 prefs 版本 —— 否则在半窗里改完 chatMode，这页的副标题不会刷新
    val uiVer = com.aevis.android.core.ChatPrefs.uiVersion
    var persona by remember { mutableStateOf<Api.Persona?>(null) }
    var msgs by remember { mutableStateOf<List<Api.Msg>>(emptyList()) }
    var showChatSettings by remember(uiVer) { mutableStateOf(false) }
    var showModePick by remember { mutableStateOf(false) }

    LaunchedEffect(pid) {
        withContext(Dispatchers.IO) {
            persona = runCatching { Api.personas(mine = true) }.getOrNull()
                ?.firstOrNull { it.id == pid }
            msgs = runCatching { Api.loadConv(pid) }.getOrDefault(emptyList())
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = tr("角色设置"), onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(4.dp))

            // ---------- 头部卡片（130：磨砂玻璃，卡片里透出背后那块模糊背景）----------
            GlassSurface(
                dark = isDarkTheme(),
                modifier = Modifier.padding(horizontal = V2.gutter)
            ) {
                Row(
                    Modifier.padding(horizontal = V2.cardPad, vertical = V2.cardPad),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Avatar(persona?.avatar.orEmpty(), persona?.name.orEmpty(), 48.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            persona?.name ?: tr("这个角色"),
                            fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis
                        )
                        val tag = persona?.tagline.orEmpty().replace("\n", " ").take(14)
                        if (tag.isNotBlank()) {
                            Spacer(Modifier.height(2.dp))
                            Text(
                                tag, fontSize = 11.sp, color = ink.copy(alpha = 0.45f),
                                maxLines = 1, overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                    Text(
                        tr("编辑"), fontSize = 12.sp, color = V2.accent,
                        modifier = Modifier.clip(squircle(9.dp))
                            .background(V2.accent.copy(alpha = 0.12f))
                            .tapable { onOpenPersona() }
                            .padding(horizontal = 11.dp, vertical = 5.dp)
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            // ---------- 三格统计 ----------
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Row(Modifier.fillMaxWidth()) {
                    StatCell(tr("认识天数"), daysWith(pid).toString(), Modifier.weight(1f))
                    StatCell(tr("消息"), msgs.size.toString(), Modifier.weight(1f))
                    StatCell(
                        tr("表情"),
                        msgs.count { it.img.isNotEmpty() }.toString(),
                        Modifier.weight(1f)
                    )
                }
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 常用 ----------
            Text(
                tr("常用"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
            )
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                // 主动唤醒（2026-11-16，132）：默认关；本地先存，再往服务端报
                var proactiveOn by remember {
                    mutableStateOf(com.aevis.android.core.ChatPrefs.proactiveOn(pid))
                }
                val scope = rememberCoroutineScope()
                Row(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            tr("主动唤醒"), fontSize = V2.body,
                            fontWeight = FontWeight.Medium
                        )
                        Spacer(Modifier.height(1.dp))
                        Text(
                            tr("TA 会自己来找你（默认关）"),
                            fontSize = 10.5.sp, color = ink.copy(alpha = 0.4f)
                        )
                    }
                    androidx.compose.material3.Switch(
                        checked = proactiveOn,
                        onCheckedChange = { on ->
                            proactiveOn = on
                            com.aevis.android.core.ChatPrefs.setProactiveOn(pid, on)
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    runCatching { Api.proactivePref(on, pid) }
                                }
                            }
                        }
                    )
                }
                ThinLine()
                QuickRow(
                    icon = R.drawable.ic_chat_mode, title = tr("聊天模式"),
                    sub = if (ChatPrefs.chatMode == 0) tr("普通") else tr("内心 OS"),
                    onClick = { showModePick = true }
                )
                ThinLine()
                QuickRow(
                    icon = R.drawable.ic_set_person, title = tr("角色档案"),
                    sub = tr("人设 · 开场白"),
                    onClick = { onOpenPersona() }
                )
                ThinLine()
                QuickRow(
                    icon = R.drawable.ic_set_sliders, title = tr("聊天设置"),
                    sub = tr("回复方式 · 记忆"),
                    onClick = { showChatSettings = true }
                )
                ThinLine()
                QuickRow(
                    icon = R.drawable.ic_set_layers, title = tr("资源库"),
                    sub = tr("照片 · 视频 · 文件"),
                    onClick = { onOpenLibrary() }
                )
            }

            Spacer(Modifier.height(34.dp))
        }
    }

    // 聊天模式三选一
    if (showModePick) {
        val cur = ChatPrefs.chatMode
        ModalBottomSheet(
            onDismissRequest = { showModePick = false },
            containerColor = frostedSheetColor(),
            scrimColor = frostedScrimColor()
        ) {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .navigationBarsPadding()
            ) {
                Text(tr("聊天模式"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                // 两项（2026-11-16 用户口径）：逐字不是模式，是显示效果
                ModeRow(tr("普通"), tr("像发消息一样，一条条回"), cur == 0) {
                    ChatPrefs.chatMode = 0; showModePick = false
                }
                ModeRow(tr("内心 OS"), tr("带上 TA 的心里话，整段流式输出"), cur == 1) {
                    ChatPrefs.chatMode = 1; showModePick = false
                }
                Spacer(Modifier.height(16.dp))
            }
        }
    }

    if (showChatSettings) {
        // 完成/关闭只关半窗；「角色档案」那行自己走 onOpenPersona
        ChatSettingsSheet(
            pid = pid,
            onOpenPersona = { showChatSettings = false; onOpenPersona() },
            onClose = { showChatSettings = false }
        )
    }
}

/** 认识天数：第一条消息的时间（没有就用 convAt），不足一天算 1。*/
private fun daysWith(pid: String): Int {
    val at = Api.convAt(pid)
    if (at <= 0L) return 1
    val d = (System.currentTimeMillis() - at) / 86_400_000L
    return (d + 1).toInt().coerceAtLeast(1)
}

@Composable
private fun StatCell(label: String, value: String, modifier: Modifier = Modifier) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = ink)
        Spacer(Modifier.height(2.dp))
        Text(label, fontSize = 10.sp, color = ink.copy(alpha = 0.42f))
    }
}

@Composable
private fun QuickRow(
    @androidx.annotation.DrawableRes icon: Int,
    title: String,
    sub: String,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        androidx.compose.material3.Icon(
            androidx.compose.ui.res.painterResource(icon), null,
            tint = ink.copy(alpha = 0.72f),
            modifier = Modifier.size(24.dp)
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = V2.body, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(2.dp))
            Text(sub, fontSize = V2.micro, color = ink.copy(alpha = 0.45f))
        }
        androidx.compose.material3.Icon(
            androidx.compose.ui.res.painterResource(R.drawable.ic_chevron), null,
            tint = ink.copy(alpha = 0.25f),
            modifier = Modifier.size(15.dp)
        )
    }
}

@Composable
private fun ModeRow(title: String, sub: String, on: Boolean, onClick: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().clip(squircle(12.dp)).tapable { onClick() }
            .padding(horizontal = 8.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                title, fontSize = V2.body, fontWeight = FontWeight.Medium,
                color = if (on) V2.accent else ink
            )
            Spacer(Modifier.height(2.dp))
            Text(sub, fontSize = 11.sp, color = ink.copy(alpha = 0.42f))
        }
        if (on) androidx.compose.material3.Icon(
            androidx.compose.ui.res.painterResource(R.drawable.ic_login_check), null,
            tint = V2.accent, modifier = Modifier.size(16.dp)
        )
    }
}

@Composable
private fun ThinLine() {
    Box(
        Modifier.fillMaxWidth().height(0.5.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f))
    )
}
