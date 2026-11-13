package com.aevis.android.ui

import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.BuildConfig
import com.aevis.android.R
import com.aevis.android.core.NativeCore
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** iOS 那张「V2Card」：24 圆角、纯白、无阴影。*/
@Composable
fun V2Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(V2.cardRadius))
            .background(MaterialTheme.colorScheme.surface)
            .padding(V2.cardPad),
        content = content
    )
}

/** 图标方块：40 圆角 13，淡色底。*/
@Composable
fun IconBox(@DrawableRes icon: Int, tint: Color = V2.accent) {
    Box(
        Modifier.size(V2.iconBox)
            .clip(RoundedCornerShape(V2.iconRadius))
            .background(tint.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center
    ) { Icon(painterResource(icon), null, tint = tint, modifier = Modifier.size(21.dp)) }
}


/**
 * 点击但**不要 Material 的水波纹**。
 *
 * 用户一直说「一看就是安卓味」—— 水波纹是最典型的那个味。iOS 上是整行按下变淡，
 * 这里用 `indication = null` 把涟漪去掉，按下态交给 `Modifier.alpha`（见 RowItem）。
 */
@Composable
fun Modifier.tapable(enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val src = remember { MutableInteractionSource() }
    return this.then(
        Modifier.clickable(
            interactionSource = src, indication = null, enabled = enabled, onClick = onClick
        )
    )
}

// ------------------------------------------------------------------ 主壳

private data class Tab(val title: String, @DrawableRes val icon: Int)

@Composable
fun Shell(onSignOut: () -> Unit) {
    val tabs = listOf(
        Tab("聊天", R.drawable.ic_tab_chat),
        Tab("通讯录", R.drawable.ic_tab_contacts),
        Tab("发现", R.drawable.ic_tab_discover),
        Tab("我", R.drawable.ic_tab_me)
    )
    var idx by remember { mutableIntStateOf(0) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            // iOS 的 UITabBar：细分割线 + 4 等分 + 图标 24 / 字 10.5。
            // 用户 2026-11-13：「下面那个四个框可以往上提一点」——
            // 除了给系统手势条留位置，再额外抬 6dp，别贴着屏幕底边。
            Column(
                Modifier.background(MaterialTheme.colorScheme.surface)
                    .navigationBarsPadding()
            ) {
                HorizontalDivider(
                    thickness = 0.5.dp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f)
                )
                Row(
                    Modifier.fillMaxWidth().height(60.dp)
                        .padding(bottom = 6.dp)
                ) {
                    tabs.forEachIndexed { i, t ->
                        val on = idx == i
                        val tint = if (on) V2.accent
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.40f)
                        Column(
                            Modifier.weight(1f).fillMaxHeight().tapable { idx = i },
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center
                        ) {
                            Icon(
                                painterResource(t.icon), contentDescription = t.title,
                                tint = tint, modifier = Modifier.size(24.dp)
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(t.title, fontSize = 10.5.sp, color = tint)
                        }
                    }
                }
            }
        }
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when (idx) {
                0 -> ChatTab()
                1 -> ContactsTab()
                2 -> DiscoverTab()
                else -> MeTab(onSignOut)
            }
        }
    }
}

@Composable
private fun Header(title: String, sub: String? = null) {
    Column(
        Modifier.padding(
            start = V2.gutter, end = V2.gutter, top = 14.dp, bottom = 6.dp
        )
    ) {
        Text(title, fontSize = V2.display, fontWeight = FontWeight.Bold)
        if (sub != null) {
            Spacer(Modifier.height(4.dp))
            Text(sub, fontSize = V2.sub,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.48f))
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        fontSize = V2.tiny, fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f),
        modifier = Modifier.padding(
            start = V2.gutter + 4.dp, top = V2.sectionGap, bottom = 10.dp
        )
    )
}

/** 一行：图标 + 标题/副标题 + 右箭头。点不开的会如实说「正在接入」。*/
@Composable
private fun RowItem(
    @DrawableRes icon: Int,
    title: String,
    sub: String? = null,
    tint: Color = V2.accent,
    trailing: String? = null,
    onClick: (() -> Unit)? = null
) {
    val ctx = LocalContext.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = V2.rowHeight)
            .tapable {
                if (onClick != null) onClick()
                else Toast.makeText(ctx, "「$title」正在接入安卓版", Toast.LENGTH_SHORT).show()
            }
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconBox(icon, tint)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = V2.body, fontWeight = FontWeight.Medium)
            if (sub != null) {
                Spacer(Modifier.height(3.dp))
                Text(sub, fontSize = V2.tiny,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f))
            }
        }
        if (trailing != null) {
            Text(trailing, fontSize = V2.sub,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f))
            Spacer(Modifier.width(6.dp))
        }
        Icon(
            painterResource(R.drawable.ic_row_chevron), null,
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.22f),
            modifier = Modifier.size(18.dp)
        )
    }
}

/** 一张卡里若干行，行间一条淡分割线。*/
@Composable
private fun CardGroup(content: @Composable ColumnScope.() -> Unit) {
    V2Card(Modifier.padding(horizontal = V2.gutter)) { content() }
}

@Composable
private fun RowDivider() {
    HorizontalDivider(
        Modifier.padding(start = 54.dp),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    )
}

// ------------------------------------------------------------------ 聊天

@Composable
private fun ChatTab() {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("聊天", "和你的 AI 伙伴说说话")

        SectionTitle("我的 AI 伙伴")
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                .padding(horizontal = V2.gutter),
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // 一个「添加」虚线圈：还没添加伙伴时，这是这一条唯一的入口
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.size(56.dp).clip(CircleShape)
                        .background(ink.copy(alpha = 0.04f))
                        .border(1.dp, ink.copy(alpha = 0.14f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(painterResource(R.drawable.ic_tab_plus), null,
                        tint = ink.copy(alpha = 0.45f), modifier = Modifier.size(22.dp))
                }
                Spacer(Modifier.height(8.dp))
                Text("添加", fontSize = V2.micro, color = ink.copy(alpha = 0.42f))
            }
        }

        SectionTitle("最近会话")
        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            Column(
                Modifier.fillMaxWidth().padding(vertical = 26.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                    Modifier.size(64.dp).clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(painterResource(R.drawable.ic_tab_chat), null,
                        tint = V2.accent.copy(alpha = 0.75f), modifier = Modifier.size(28.dp))
                }
                Spacer(Modifier.height(14.dp))
                Text("还没有会话", fontSize = V2.body, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(6.dp))
                Text("去通讯录挑一个 AI 伙伴，就能开始聊天",
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.45f))
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

// ------------------------------------------------------------------ 通讯录

@Composable
private fun ContactsTab() {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("通讯录", "人设 · 一起听 · 朋友")

        CardGroup {
            RowItem(R.drawable.ic_row_persona, "我的 AI 伙伴", "还没有添加", V2.accent)
            RowDivider()
            RowItem(R.drawable.ic_row_persona, "人设广场", "逛逛别人的角色",
                Color(0xFFE05185))
            RowDivider()
            RowItem(R.drawable.ic_row_listen, "一起听", "和朋友同步播放",
                Color(0xFF21A394))
            RowDivider()
            RowItem(R.drawable.ic_row_addfriend, "新的朋友", "好友申请、邀请",
                Color(0xFF6FA8E8))
            RowDivider()
            RowItem(R.drawable.ic_tab_contacts, "群聊", "大家在一起",
                Color(0xFFEB8C2E))
        }
        Spacer(Modifier.height(24.dp))
    }
}

// ------------------------------------------------------------------ 发现

@Composable
private fun DiscoverTab() {
    val ctx = LocalContext.current
    val ink = MaterialTheme.colorScheme.onSurface
    val entries = listOf(
        Triple("人设广场", R.drawable.ic_row_persona, Color(0xFFE05185)),
        Triple("表情包", R.drawable.ic_row_emoji, Color(0xFFEB8C2E)),
        Triple("一起听", R.drawable.ic_row_listen, Color(0xFF21A394)),
        Triple("创作者中心", R.drawable.ic_row_create, Color(0xFF9B8AF0)),
        Triple("模型状态", R.drawable.ic_row_status, Color(0xFF6FA8E8)),
        Triple("内置浏览器", R.drawable.ic_row_globe, Color(0xFF669E33))
    )
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("发现", "广场 · 表情 · 创作者")

        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            entries.chunked(3).forEachIndexed { rowIdx, row ->
                if (rowIdx > 0) Spacer(Modifier.height(22.dp))
                Row(Modifier.fillMaxWidth()) {
                    row.forEach { (title, icon, color) ->
                        Column(
                            Modifier.weight(1f).tapable {
                                Toast.makeText(
                                    ctx, "「$title」正在接入安卓版", Toast.LENGTH_SHORT
                                ).show()
                            },
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            IconBox(icon, color)
                            Spacer(Modifier.height(9.dp))
                            Text(title, fontSize = V2.micro, color = ink.copy(alpha = 0.75f))
                        }
                    }
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }

        SectionTitle("更多")
        CardGroup {
            RowItem(R.drawable.ic_row_diary, "日记", "今天记一笔", Color(0xFF6FA8E8))
            RowDivider()
            RowItem(R.drawable.ic_row_todo, "待办", "别忘事", Color(0xFF21A394))
            RowDivider()
            RowItem(R.drawable.ic_row_music, "音乐", "边聊边听", Color(0xFFE05185))
        }
        Spacer(Modifier.height(24.dp))
    }
}

// ------------------------------------------------------------------ 我

@Composable
private fun MeTab(onSignOut: () -> Unit) {
    var balance by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(Unit) {
        balance = withContext(Dispatchers.IO) { Api.balance() }
    }
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("我")

        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(60.dp).clip(RoundedCornerShape(21.dp))
                        .background(V2.accent.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        Api.email().take(1).uppercase().ifEmpty { "A" },
                        fontSize = 24.sp, color = V2.accent, fontWeight = FontWeight.Medium
                    )
                }
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(Api.email().ifEmpty { "未登录" }, fontSize = V2.body,
                        fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(4.dp))
                    Text("UID ${Api.uid().ifEmpty { "-" }}", fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f))
                }
            }
            Spacer(Modifier.height(20.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("积分余额", fontSize = V2.sub, color = ink.copy(alpha = 0.6f))
                // 积分千分位由共享 C++ 算，和 iOS 显示完全一致
                Text(NativeCore.formatPointsSafe(balance?.toLong()), fontSize = V2.title,
                    fontWeight = FontWeight.SemiBold, color = V2.accent)
            }
        }

        Spacer(Modifier.height(14.dp))
        CardGroup {
            RowItem(R.drawable.ic_row_persona, "账号与安全", "邮箱、密码、登录设备",
                V2.accent)
            RowDivider()
            RowItem(R.drawable.ic_row_status, "通知", "消息提醒", Color(0xFF6FA8E8))
            RowDivider()
            RowItem(R.drawable.ic_row_globe, "关于 Aevis", "版本与协议", Color(0xFF669E33))
        }

        Spacer(Modifier.height(14.dp))
        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            Row(
                Modifier.fillMaxWidth().tapable { Api.signOut(); onSignOut() }
                    .padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("退出登录", fontSize = V2.body, color = V2.alert)
                Icon(painterResource(R.drawable.ic_row_chevron), null,
                    tint = ink.copy(alpha = 0.22f), modifier = Modifier.size(18.dp))
            }
        }

        // 版本号常驻在底部 —— 用户 2026-11-13：「APK 的版本呢？」
        Spacer(Modifier.height(26.dp))
        Text(
            "Aevis Android ${BuildConfig.VERSION_NAME}（${BuildConfig.VERSION_CODE}）" +
                " · core ${runCatching { NativeCore.version() }.getOrDefault("—")}",
            fontSize = V2.micro,
            color = ink.copy(alpha = 0.32f),
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(Modifier.height(18.dp))
    }
}
