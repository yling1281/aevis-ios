package com.aevis.android.ui

import android.app.Activity
import android.content.Intent
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.BuildConfig
import com.aevis.android.R
import com.aevis.android.core.NativeCore
import com.aevis.android.core.I18n
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * iOS 那张「V2Card」：**连续圆角**、纯白、0.5dp 极淡描边、无阴影。
 *
 * 2026-11-14 用户：「该圆润的地方没圆润起来，该白的地方没白起来」——
 * 之前用的是 `RoundedCornerShape`（正圆弧）+ 没描边，卡片看着"平、方、灰"。
 * 现在换成 squircle（超椭圆），再补一层 8% 的描边把边"立"起来。
 */
@Composable
fun V2Card(
    modifier: Modifier = Modifier,
    pad: Dp = V2.cardPad,
    content: @Composable ColumnScope.() -> Unit
) {
    val shape = squircle(V2.cardRadius)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(MaterialTheme.colorScheme.surface)
            .border(0.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), shape)
            .padding(pad),
        content = content
    )
}

/** 图标方块：40 圆角 13，淡色底。*/
@Composable
fun IconBox(@DrawableRes icon: Int, tint: Color = V2.accent) {
    Box(
        Modifier.size(V2.iconBox)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.13f)),
        contentAlignment = Alignment.Center
    ) { Icon(painterResource(icon), null, tint = tint, modifier = Modifier.size(18.dp)) }
}


/**
 * 点击但**不要 Material 的水波纹**。
 *
 * 用户一直说「一看就是安卓味」—— 水波纹是最典型的那个味。iOS 上是整行按下变淡，
 * 这里用 `indication = null` 把涟漪去掉，按下态交给 `Modifier.alpha`（见 RowItem）。
 */
/// 从扫码内容里抠出登录票号。
/// 和 iOS（`QRScan.ticket`）、网页、小程序用的是**同一套规则**，
/// 四端扫同一张码必须都能认出来。
private fun parseScanTicket(raw: String): String {
    if (raw.isEmpty()) return ""
    val m = Regex("[?&]t=([0-9a-fA-F]{16,64})").find(raw) ?: return ""
    return m.groupValues.getOrNull(1) ?: ""
}

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

/** 图标改成 name —— 用的是我们自己在 `AevisIcons.kt` 里画的那套（照搬 iOS）。*/
private data class Tab(val id: String, val title: String)

@Composable
fun Shell(onSignOut: () -> Unit) {
    val tabs = listOf(
        Tab("chat", "聊天"),
        Tab("contacts", "通讯录"),
        Tab("discover", "发现"),
        Tab("me", "我")
    )
    var idx by remember { mutableIntStateOf(0) }
    // 二级页面（2026-11-14）：商城 / 浏览器 / 站内信 / 关于。
    // 之前这些东西全是 Toast，用户：「你啥也不行」。
    var page by remember { mutableStateOf<String?>(null) }

    // 2026-11-14 用户：「返回你加一个系统也可以，就是自带返回」——
    // ⚠️ 之前写成 `when(page){ ...; return }` + 前面一个 BackHandler：
    //    实测按返回键**直接退出 App**。原因是 early return 打断了 Compose 的
    //    副作用更新，那个 BackHandler 的 enabled 从 false→true 时没真正挂上。
    //    改成正常分支结构，BackHandler 放在二级页面这一支里面。
    val sub = page
    if (sub != null) {
        BackHandler { page = null }
        when {
            sub.startsWith("persona:") ->
                PersonaDetailScreen(pid = sub.removePrefix("persona:"),
                                    onBack = { page = null })
            sub == "mall" -> MallScreen(onBack = { page = null },
                                        onOpenPersona = { pid -> page = "persona:" + pid })
            sub == "browser" -> BrowserScreen(onBack = { page = null })
            sub == "inbox" -> InboxScreen(onBack = { page = null })
            sub == "about" -> AboutScreen(onBack = { page = null })
            sub == "music" -> MusicScreen(onBack = { page = null })
            sub == "account" -> AccountScreen(onBack = { page = null },
                                             onSignOut = onSignOut)
            sub == "permission" -> PermissionScreen(onBack = { page = null })
        }
        return
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        // 2026-11-14 用户：「屏幕上面它肯定有一个东西吧…你肯定是要搞一下呀」——
        // enableEdgeToEdge 之后内容会顶到状态栏底下，标题被时间和信号压住。
        // 这里把 Scaffold 自带的 inset 关掉（bottomBar 自己已经 navigationBarsPadding，
        // 不关会双倍），改由内容层显式 statusBarsPadding。
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            // iOS 的**悬浮胶囊 Dock**。
            // 2026-11-14 用户：「下面那个圆圈拉长一点」「下面那个 Dock 栏可以拉长一点」——
            // 通栏底栏 + 细分割线是最"安卓"的两个特征，所以改成：
            // 左右留 20dp、整体 66dp 高、33dp 圆角（纯胶囊）、选中项一块淡紫胶囊。
            Box(
                Modifier.fillMaxWidth()
                    .navigationBarsPadding()
                    // 2026-11-14 用户：「你这个按钮的…形状你可以往右来一点…有点朝外了，
                    // 你肯定不能贴着边呐」——20dp 在窄屏上看着贴边，收到 28dp，
                    // 选中胶囊离屏幕边缘就有一指宽，不再"顶出去"。
                    .padding(horizontal = 28.dp, vertical = 10.dp)
            ) {
                Row(
                    Modifier.fillMaxWidth().height(66.dp)
                        .clip(squircle(33.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .border(
                            0.5.dp,
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                            squircle(33.dp)
                        )
                        .padding(horizontal = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    tabs.forEachIndexed { i, t ->
                        val on = idx == i
                        val tint = if (on) V2.accent
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f)
                        Box(
                            Modifier.weight(1f).fillMaxHeight().tapable { idx = i },
                            contentAlignment = Alignment.Center
                        ) {
                            Row(
                                Modifier
                                    .clip(squircle(20.dp))
                                    .background(
                                        if (on) V2.accent.copy(alpha = 0.13f) else Color.Transparent
                                    )
                                    .padding(horizontal = 13.dp, vertical = 7.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                // 手画图标（照搬 iOS PaperIcons 的坐标）
                                when (t.id) {
                                    "chat" -> IcChat(tint, 22.dp)
                                    "contacts" -> IcPeople(tint, 22.dp)
                                    "discover" -> IcCompass(tint, 22.dp)
                                    else -> IcPerson(tint, 22.dp)
                                }
                                // 2026-11-14 用户：「有些超出去了」——
                                // 之前四个 tab 全都带文字，窄屏 + 大字体时整条会撑爆。
                                // iOS 的 PaperTabBar 也只有**选中项**带文字，未选中只剩图标。
                                if (on) {
                                    Spacer(Modifier.width(6.dp))
                                    Text(
                                        tr(t.title),
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = tint,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize().statusBarsPadding()) {
            when (idx) {
                0 -> ChatTab(onFindMore = { page = "mall" })
                1 -> ContactsTab(onFindMore = { page = "mall" })
                2 -> DiscoverTab(
                    onOpenMall = { page = "mall" },
                    onOpenBrowser = { page = "browser" },
                    onOpenMusic = { page = "music" }
                )
                else -> MeTab(
                    onSignOut = onSignOut,
                    onOpenInbox = { page = "inbox" },
                    onOpenAbout = { page = "about" },
                    onOpenAccount = { page = "account" },
                    onOpenPermission = { page = "permission" }
                )
            }
        }
    }
}

/**
 * 头像。有 URL 就真加载，没有/加载失败就用名字首字母 ——
 * 用户 2026-11-14：「这个账号的头像也不行」——之前永远是首字母，因为从来没拉过 avatar。
 */
@Composable
fun Avatar(url: String, name: String, size: Dp) {
    val appCtx = LocalContext.current.applicationContext
    var bmp by remember(url) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(url) {
        if (url.isEmpty()) { bmp = null; return@LaunchedEffect }
        bmp = withContext(Dispatchers.IO) {
            // 2026-11-14 用户：「你要缓存在本地…你不要每次都要拉取，要缓存在本地加密」
            // 先看加密缓存，没有再下载；下载到的转 JPEG 存回去。
            val ck = "img:" + url
            val cached = com.aevis.android.core.SecureCache.getBytes(appCtx, ck)
            if (cached != null) {
                android.graphics.BitmapFactory.decodeByteArray(cached, 0, cached.size)
            } else {
                val b = runCatching { Api.fetchImage(url) }
                    .onFailure { android.util.Log.e("AevisAvatar", "load fail: " + url, it) }
                    .getOrNull()
                if (b != null) {
                    runCatching {
                        val out = java.io.ByteArrayOutputStream()
                        b.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                        com.aevis.android.core.SecureCache.putBytes(appCtx, ck, out.toByteArray())
                    }
                }
                b
            }
        }
    }
    val f = bmp
    Box(
        Modifier.size(size).clip(CircleShape)
            .background(V2.accent.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center
    ) {
        if (f != null) {
            Image(
                bitmap = f.asImageBitmap(), contentDescription = name,
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(size).clip(CircleShape)
            )
        } else {
            Text(
                name.take(1).uppercase().ifEmpty { "A" },
                fontSize = (size.value * 0.40f).sp, color = V2.accent,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

/**
 * 页头 —— 对 iOS 的 `V2TopBar`。
 *
 * 2026-11-14 修：之前用 `V2.display`(28) + Bold 当页标题，而 iOS 是
 * `V2.title`(20) + semibold，光这一处就差 8pt，一进页面就"不是那个味"。
 * 副标题也从 14 收到 12（iOS 的 V2.tiny），透明度 0.42 对齐。
 */
@Composable
private fun Header(title: String, sub: String? = null) {
    Column(
        Modifier.padding(
            // 2026-11-14 用户第二次说「顶部还是没有安全区」——
            // statusBarsPadding 是生效的（标题没被状态栏压住），但 Header 自己只留了 6dp，
            // 视觉上就是"贴着状态栏"。iOS 那边顶栏在 NavigationStack 的安全区之下、
            // 再叠 6pt，安卓这边没有那层，得自己补上。
            start = V2.gutter, end = V2.gutter, top = 16.dp, bottom = 10.dp
        )
    ) {
        Text(title, fontSize = V2.title, fontWeight = FontWeight.SemiBold)
        if (sub != null) {
            Spacer(Modifier.height(2.dp))
            Text(sub, fontSize = V2.tiny,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f))
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        tr(text),
        fontSize = V2.sub, fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        modifier = Modifier.padding(
            start = V2.gutter, top = V2.sectionGap, bottom = 8.dp
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
            .padding(vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconBox(icon, tint)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Text(tr(title), fontSize = V2.body, fontWeight = FontWeight.Medium)
            if (sub != null) {
                Spacer(Modifier.height(2.dp))
                Text(tr(sub), fontSize = V2.tiny,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f))
            }
        }
        if (trailing != null) {
            Text(trailing, fontSize = V2.tiny,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.35f))
            Spacer(Modifier.width(6.dp))
        }
        Icon(
            painterResource(R.drawable.ic_row_chevron), null,
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.22f),
            modifier = Modifier.size(14.dp)
        )
    }
}

/** 一张卡里若干行，行间一条淡分割线。*/
@Composable
private fun CardGroup(content: @Composable ColumnScope.() -> Unit) {
    V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) { content() }
}

@Composable
private fun RowDivider() {
    HorizontalDivider(
        Modifier.padding(start = 66.dp),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    )
}

// ------------------------------------------------------------------ 聊天

@Composable
private fun ChatTab(onFindMore: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("聊天", "点一个人就进对话")

        // 2026-11-14 用户：「添加 AI 伙伴不用，聊天里面其实就是一个会话呀」——
        // 原来顶上有一排横滑的「我的 AI 伙伴 + 添加虚线圈」，那是通讯录的事。
        // 聊天页现在就一件事：会话列表。
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
                Text(tr("还没有会话"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(6.dp))
                Text(tr("去通讯录挑一个 AI 伙伴，就能开始聊天"),
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.45f))
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

// ------------------------------------------------------------------ 通讯录

/**
 * 通讯录 —— **只放联系人，别的都不放**。
 *
 * 2026-11-14 用户：「通讯录这里新的朋友一起听，一起听不要，新的朋友不要，
 * 通讯录就只是看通讯录的」。
 * 之前这页是 5 行菜单（AI 伙伴 / 人设广场 / 一起听 / 新的朋友 / 群聊），
 * 点进去 4 个都是弹提示 —— 通讯录本来就不该是菜单页。
 *
 * 现在：拉 `/v1/psquare/mine` 显示真正添加过的伙伴，没有就一个空态。
 */
@Composable
private fun ContactsTab(onFindMore: () -> Unit) {
    var list by remember { mutableStateOf<List<Api.Persona>?>(null) }
    val ink = MaterialTheme.colorScheme.onSurface

    LaunchedEffect(Unit) {
        list = withContext(Dispatchers.IO) {
            runCatching { Api.personas(mine = true) }.getOrElse { emptyList() }
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("通讯录", "你的 AI 伙伴")

        val items = list
        when {
            items == null -> {
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Text(tr("正在加载…"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f),
                        modifier = Modifier.padding(vertical = 18.dp))
                }
            }

            items.isEmpty() -> {
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Column(
                        Modifier.fillMaxWidth().padding(vertical = 26.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Box(
                            Modifier.size(56.dp).clip(CircleShape)
                                .background(V2.accent.copy(alpha = 0.10f)),
                            contentAlignment = Alignment.Center
                        ) { IcPeople(V2.accent, 24.dp) }
                        Spacer(Modifier.height(12.dp))
                        Text(tr("还没有 AI 伙伴"), fontSize = V2.body,
                            fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(5.dp))
                        Text(tr("去广场挑一个，领养后就在这儿"),
                            fontSize = V2.tiny, color = ink.copy(alpha = 0.45f))
                        Spacer(Modifier.height(14.dp))
                        Text(
                            "去人设广场",
                            fontSize = V2.sub, fontWeight = FontWeight.Medium,
                            color = V2.accent,
                            modifier = Modifier
                                .clip(squircle(14.dp))
                                .background(V2.accent.copy(alpha = 0.12f))
                                .tapable { onFindMore() }
                                .padding(horizontal = 18.dp, vertical = 9.dp)
                        )
                    }
                }
            }

            else -> {
                CardGroup {
                    items.forEachIndexed { i, p ->
                        if (i > 0) RowDivider()
                        PersonaRow(p) { }
                    }
                }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** 通讯录里的一行：头像 + 名字 + 一句话。 */
@Composable
private fun PersonaRow(p: Api.Persona, onClick: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Avatar(p.avatar, p.name, 44.dp)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.name, fontSize = V2.body, fontWeight = FontWeight.Medium)
                if (p.official) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "官方",
                        fontSize = 9.5.sp, color = V2.accent,
                        modifier = Modifier
                            .clip(squircle(5.dp))
                            .background(V2.accent.copy(alpha = 0.13f))
                            .padding(horizontal = 5.dp, vertical = 1.5.dp)
                    )
                }
            }
            if (p.tagline.isNotEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(p.tagline, fontSize = V2.tiny, maxLines = 1,
                    color = ink.copy(alpha = 0.45f))
            }
        }
    }
}

// ------------------------------------------------------------------ 发现

/**
 * 发现。
 *
 * 2026-11-14 用户逐条点过：「商城正在接入安卓版，朋友圈打不开，情侣空间打不开，
 * 日记什么…浏览器打不开，实时通话也打不开」——**点哪儿都是弹提示**，这是最招骂的形态。
 *
 * 处置原则：**能真开的才留**。
 * - 商城 → 真人设/表情列表（`/v1/psquare/list`、`/v1/emoji/list`）
 * - 浏览器 → 真 WebView
 * - 网易云音乐 / 苹果音乐 → 用户点名「可以删掉」
 * - 朋友圈 / 情侣空间 / 日记 / 一起做的事 / 实时通话 → iOS 那边是纯本地功能，
 *   安卓没有对应实现，**先不摆出来**，做好再放回来。
 */
@Composable
private fun DiscoverTab(
    onOpenMall: () -> Unit,
    onOpenBrowser: () -> Unit,
    onOpenMusic: () -> Unit
) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("发现", "商城 · 网易云 · 浏览器")

        // 商城入口（对 iOS 的 ShopEntryCard）
        Row(
            Modifier.padding(horizontal = V2.gutter).fillMaxWidth()
                .clip(squircle(V2.cardRadius))
                .background(MaterialTheme.colorScheme.surface)
                .border(
                    0.5.dp,
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                    squircle(V2.cardRadius)
                )
                .tapable { onOpenMall() }
                .padding(horizontal = V2.gutter, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(46.dp).clip(squircle(13.dp))
                    .background(V2.accent.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center
            ) { IcBag(V2.accent, 19.dp) }
            Spacer(Modifier.width(13.dp))
            Column(Modifier.weight(1f)) {
                Text(tr("商城"), fontSize = V2.body, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text(
                    "人设 · 表情包",
                    fontSize = V2.tiny,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f)
                )
            }
            Icon(
                painterResource(R.drawable.ic_row_chevron), null,
                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.28f),
                modifier = Modifier.size(14.dp)
            )
        }

        // 2026-11-14 用户：「发现页把网易云接上」（前一轮他说苹果音乐可以删，
        // 网易云要留）——这一条现在是真能搜、真能播。
        SectionTitle("听点东西")
        CardGroup {
            RowItem(R.drawable.ic_row_music, "网易云音乐", "搜歌、播放",
                Color(0xFFE05185),
                onClick = { onOpenMusic() })
        }

        SectionTitle("其它")
        CardGroup {
            RowItem(R.drawable.ic_row_globe, "浏览器", "打开网页", V2.accent,
                onClick = { onOpenBrowser() })
        }

        Spacer(Modifier.height(28.dp))
    }
}

// ------------------------------------------------------------------ 我

@Composable
private fun MeTab(
    onSignOut: () -> Unit,
    onOpenInbox: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenAccount: () -> Unit,
    onOpenPermission: () -> Unit
) {
    var balance by remember { mutableStateOf<Int?>(null) }
    // 先上本地缓存（头像/名字立刻有），再后台刷新
    var me by remember { mutableStateOf<Api.MeInfo?>(Api.cachedMe()) }
    var unread by remember { mutableIntStateOf(0) }
    val ctx = LocalContext.current
    // 原生扫一扫（2026-11-13）：扫电脑上的登录码，回来给网页授权。
    // 用系统 Camera + zxing 解码，不依赖 CameraX / ML Kit。
    val scanLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { res ->
        if (res.resultCode == Activity.RESULT_OK) {
            val raw = res.data?.getStringExtra("code").orEmpty()
            val ticket = parseScanTicket(raw)
            if (ticket.isEmpty()) {
                Toast.makeText(ctx, tr("这不是 Aevis 的登录码"), Toast.LENGTH_LONG).show()
            } else {
                (ctx as? com.aevis.android.MainActivity)?.handleScanTicket(ticket)
            }
        }
    }
    LaunchedEffect(Unit) {
        balance = withContext(Dispatchers.IO) { Api.balance() }
        // 2026-11-14：昵称/头像一直是首字母，因为从来没调过 /v1/me。
        me = withContext(Dispatchers.IO) {
            runCatching { Api.me() }.getOrNull()?.also { runCatching { Api.saveMe(it) } }
        }
        unread = withContext(Dispatchers.IO) {
            runCatching { Api.inbox().second }.getOrDefault(0)
        }
    }
    val ink = MaterialTheme.colorScheme.onSurface
    val displayName = me?.nickname?.takeIf { it.isNotBlank() }
        ?: Api.email().substringBefore("@").ifEmpty { "未登录" }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("我")

        V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
            Row(
                Modifier.padding(horizontal = V2.gutter, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Avatar(me?.avatar.orEmpty(), displayName, 60.dp)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(displayName, fontSize = V2.title,
                        fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        Api.email().ifEmpty { "未登录" },
                        fontSize = V2.tiny, maxLines = 1,
                        color = ink.copy(alpha = 0.45f)
                    )
                }
            }
        }

        SectionTitle("账号")
        CardGroup {
            RowItem(R.drawable.ic_login_qr, "扫一扫", "扫电脑上的登录码，给网页授权",
                V2.accent,
                onClick = {
                    scanLauncher.launch(Intent(ctx, CameraScanActivity::class.java))
                })
            RowDivider()
            RowItem(
                R.drawable.ic_row_status, "积分", "当前余额", V2.accent,
                trailing = NativeCore.formatPointsSafe(balance?.toLong())
            )
            RowDivider()
            RowItem(R.drawable.ic_row_status, "通知",
                if (unread > 0) "$unread 条未读" else "没有新消息",
                Color(0xFF6FA8E8),
                trailing = if (unread > 0) "$unread" else null,
                onClick = { onOpenInbox() })
            RowDivider()
            // 多语言（2026-11-14）：点一下在中文 / English 之间切，选完会记住
            RowItem(R.drawable.ic_row_globe, "语言", I18n.label(), Color(0xFF8B7BD8),
                onClick = { I18n.setLang(ctx, if (I18n.lang == "zh") "en" else "zh") })
            RowDivider()
            RowItem(R.drawable.ic_row_persona, "账号与安全", "邮箱、设备、会员",
                Color(0xFF6FA8E8),
                onClick = { onOpenAccount() })
            RowDivider()
            RowItem(R.drawable.ic_row_bell, "权限", "通知、相机、麦克风、位置等",
                Color(0xFFE09B4A),
                onClick = { onOpenPermission() })
            RowDivider()
            RowItem(R.drawable.ic_row_persona, "关于 Aevis", "版本与协议", Color(0xFF669E33),
                onClick = { onOpenAbout() })
        }

        Spacer(Modifier.height(14.dp))
        V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
            Row(
                Modifier.fillMaxWidth().tapable { Api.signOut(); onSignOut() }
                    .padding(horizontal = V2.gutter, vertical = 16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("退出登录"), fontSize = V2.body, color = V2.alert)
            }
        }

        // 版本号常驻在底部 —— 用户 2026-11-13：「APK 的版本呢？」
        Spacer(Modifier.height(26.dp))
        Text(
            "Aevis Android ${BuildConfig.VERSION_NAME}（${BuildConfig.VERSION_CODE}）" +
                " · core ${runCatching { NativeCore.version() }.getOrElse { "—" }}",
            fontSize = V2.micro,
            color = ink.copy(alpha = 0.32f),
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(Modifier.height(18.dp))
    }
}
