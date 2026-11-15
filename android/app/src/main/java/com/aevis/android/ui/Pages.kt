package com.aevis.android.ui

import android.Manifest
import android.content.pm.PackageManager
import android.annotation.SuppressLint
import android.os.Build
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.core.content.ContextCompat
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.window.Dialog
import androidx.compose.material3.TextButton
import kotlinx.coroutines.delay
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.aevis.android.BuildConfig
import com.aevis.android.R
import com.aevis.android.core.LiveUpdate
import com.aevis.android.core.NativeCore
import com.aevis.android.core.NeteaseAuth
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 二级页面（2026-11-14）。
 *
 * 用户那天把所有入口点了一遍，回来说：
 * 「商城正在接入安卓版，朋友圈打不开…浏览器打不开…你啥也不行」。
 * 之前这些全是 `Toast("正在接入安卓版")` —— **摆出来又点不动，比没有更糟**。
 * 这里把能真开的先做成真页面。
 */

// ------------------------------------------------------------------ 通用外壳

@Composable
private fun PageScaffold(
    title: String,
    onBack: () -> Unit,
    content: @Composable () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            // 🔴 2026-11-14 用户：「上面那个商城还是被…你没有安全区」——
            // 一级页（Shell）修过了，但**二级页走的是这个 PageScaffold**，漏了。
            // 商城 / 网易云 / 浏览器 / 通知 / 关于 全都会顶到状态栏下面。
            .statusBarsPadding()
    ) {
        // 顶栏：返回箭头 + 标题（iOS 二级页是这种左对齐的窄顶栏，不是大标题）
        Row(
            Modifier.fillMaxWidth()
                .padding(horizontal = V2.gutter, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(CircleShape)
                    .tapable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    painterResource(R.drawable.ic_row_chevron), null,
                    tint = ink.copy(alpha = 0.7f),
                    modifier = Modifier.size(18.dp).rotate(180f)
                )
            }
            Spacer(Modifier.width(6.dp))
            Text(tr(title), fontSize = V2.title, fontWeight = FontWeight.SemiBold)
        }
        content()
    }
}

// ------------------------------------------------------------------ 商城

/**
 * 商城：人设 + 表情包。
 *
 * 后端 `/v1/psquare/list` 是真人设广场（`persona_public`，已过审的才上）。
 * 之前「商城」是个紫色渐变卡片，点了弹「正在接入」。
 */
@Composable
fun MallScreen(onBack: () -> Unit, onOpenPersona: (String) -> Unit = {}) {
    var tab by remember { mutableIntStateOf(0) }
    var list by remember { mutableStateOf<List<Api.Persona>?>(null) }
    var err by remember { mutableStateOf("") }
    val ink = MaterialTheme.colorScheme.onSurface

    // 表情包：切到这个 tab 才拉，拉过一次就不重复打接口
    var packs by remember { mutableStateOf<List<Api.EmojiPack>?>(null) }

    LaunchedEffect(tab) {
        if (tab == 0) {
            list = null
            err = ""
            val r = withContext(Dispatchers.IO) { runCatching { Api.personas() } }
            r.onSuccess { list = it }
                .onFailure { err = it.message ?: "加载失败"; list = emptyList() }
        } else if (packs == null) {
            packs = withContext(Dispatchers.IO) {
                runCatching { Api.emojiPacks() }.getOrElse { emptyList() }
            }
        }
    }

    PageScaffold("商城", onBack) {
        // 分段：人设 / 表情包
        Row(
            Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
                .clip(squircle(13.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                .padding(4.dp)
        ) {
            listOf("人设", "表情包").forEachIndexed { i, name ->
                val on = tab == i
                Text(
                    name,
                    fontSize = V2.sub,
                    fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (on) ink else ink.copy(alpha = 0.5f),
                    modifier = Modifier
                        .clip(squircle(10.dp))
                        .background(
                            if (on) MaterialTheme.colorScheme.surface
                            else Color.Transparent
                        )
                        .tapable { tab = i }
                        .padding(horizontal = 22.dp, vertical = 7.dp)
                )
            }
        }

        Spacer(Modifier.height(10.dp))

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            if (tab == 0) {
                val items = list
                when {
                    items == null -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 60.dp),
                        contentAlignment = Alignment.Center
                    ) { Text(tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)) }

                    items.isEmpty() -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 60.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            err.ifEmpty { "广场上还没有人设" },
                            fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
                        )
                    }

                    else -> {
                        V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                            items.forEachIndexed { i, p ->
                                if (i > 0) RowDividerPublic()
                                PersonaCardRow(p) { onOpenPersona(p.id) }
                            }
                        }
                    }
                }
            } else {
                val ps = packs
                when {
                    ps == null -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 60.dp),
                        contentAlignment = Alignment.Center
                    ) { Text(tr("正在加载…"), fontSize = V2.tiny,
                            color = ink.copy(alpha = 0.45f)) }

                    ps.isEmpty() -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 60.dp),
                        contentAlignment = Alignment.Center
                    ) { Text(tr("暂时没有表情包"), fontSize = V2.tiny,
                            color = ink.copy(alpha = 0.45f)) }

                    else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                        ps.forEachIndexed { i, pk ->
                            if (i > 0) RowDividerPublic()
                            Row(
                                Modifier.fillMaxWidth()
                                    .padding(horizontal = V2.gutter, vertical = 11.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Avatar(pk.cover, pk.name, 48.dp)
                                Spacer(Modifier.width(13.dp))
                                Column(Modifier.weight(1f)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(pk.name, fontSize = V2.body,
                                            fontWeight = FontWeight.Medium, maxLines = 1)
                                        if (pk.official) {
                                            Spacer(Modifier.width(6.dp))
                                            Text(
                                                tr("官方"), fontSize = 9.5.sp, color = V2.accent,
                                                modifier = Modifier.clip(squircle(5.dp))
                                                    .background(V2.accent.copy(alpha = 0.13f))
                                                    .padding(horizontal = 5.dp, vertical = 1.5.dp)
                                            )
                                        }
                                    }
                                    if (pk.intro.isNotEmpty()) {
                                        Spacer(Modifier.height(2.dp))
                                        Text(pk.intro, fontSize = V2.tiny, maxLines = 2,
                                            color = ink.copy(alpha = 0.45f))
                                    }
                                    Spacer(Modifier.height(3.dp))
                                    Text("${pk.count} " + tr("张"), fontSize = V2.micro,
                                        color = ink.copy(alpha = 0.32f))
                                }
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

@Composable
private fun PersonaCardRow(p: Api.Persona, onClick: () -> Unit = {}) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Avatar(p.avatar, p.name, 48.dp)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.name, fontSize = V2.body, fontWeight = FontWeight.Medium, maxLines = 1)
                if (p.official) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "官方", fontSize = 9.5.sp, color = V2.accent,
                        modifier = Modifier.clip(squircle(5.dp))
                            .background(V2.accent.copy(alpha = 0.13f))
                            .padding(horizontal = 5.dp, vertical = 1.5.dp)
                    )
                }
            }
            if (p.tagline.isNotEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(p.tagline, fontSize = V2.tiny, maxLines = 2,
                    color = ink.copy(alpha = 0.45f))
            }
            // 2026-11-14 用户：「领养数删掉…其实并没有真正的人领养」→ 换成人设编号
            if (p.id.isNotEmpty()) {
                Spacer(Modifier.height(3.dp))
                Text("编号 ${p.id}", fontSize = V2.micro,
                    color = ink.copy(alpha = 0.32f), maxLines = 1)
            }
        }
    }
}

/** 分割线（`RowDivider` 是 private，跨文件用不了，这里给个同款）。*/
@Composable
private fun RowDividerPublic() {
    HorizontalDivider(
        Modifier.padding(start = 78.dp),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    )
}

// ------------------------------------------------------------------ 浏览器

/**
 * 内置浏览器（2026-11-14 第二版）。
 *
 * 用户：「浏览器你不应该跟那个一样吗？是输入网址的，默认用那个微软的搜索引擎」——
 * 第一版只是个全屏 WebView，没有地址栏，打开就是 aevis.cn，用户没法输网址。
 * 现在：顶部一条地址栏，默认首页是 Bing（cn.bing.com）；
 * 输入的东西像网址就直接去，不像就当关键词丢给 Bing 搜。
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun BrowserScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val HOME = "https://cn.bing.com"
    var addr by remember { mutableStateOf(HOME) }       // 地址栏里显示的文字
    var target by remember { mutableStateOf(HOME) }     // 真正要加载的地址
    var wv by remember { mutableStateOf<WebView?>(null) }
    var loading by remember { mutableStateOf(false) }

    fun go(raw: String) {
        val t = raw.trim()
        if (t.isEmpty()) return
        val looksUrl = t.startsWith("http://") || t.startsWith("https://") ||
            (t.contains(".") && !t.contains(" "))
        target = if (looksUrl) {
            if (t.startsWith("http")) t else "https://" + t
        } else {
            "https://cn.bing.com/search?q=" + java.net.URLEncoder.encode(t, "UTF-8")
        }
        addr = target
    }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 地址栏
        Row(
            Modifier.fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).tapable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    painterResource(R.drawable.ic_row_chevron), null,
                    tint = ink.copy(alpha = 0.7f),
                    modifier = Modifier.size(17.dp).rotate(180f)
                )
            }
            Spacer(Modifier.width(6.dp))
            Box(
                Modifier.weight(1f).clip(squircle(12.dp))
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.055f))
                    .padding(horizontal = 12.dp, vertical = 9.dp)
            ) {
                BasicTextField(
                    value = addr,
                    onValueChange = { addr = it },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = 14.sp, color = ink
                    ),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri,
                        imeAction = androidx.compose.ui.text.input.ImeAction.Go
                    ),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                        onGo = { go(addr) }
                    ),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                tr("前往"), fontSize = 14.sp, fontWeight = FontWeight.Medium,
                color = V2.accent,
                modifier = Modifier
                    .clip(squircle(12.dp))
                    .background(V2.accent.copy(alpha = 0.12f))
                    .tapable { go(addr) }
                    .padding(horizontal = 13.dp, vertical = 9.dp)
            )
        }

        if (loading) {
            androidx.compose.material3.LinearProgressIndicator(
                Modifier.fillMaxWidth().height(2.dp),
                color = V2.accent,
                trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
            )
        }

        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.useWideViewPort = true
                    settings.loadWithOverviewMode = true
                    settings.setSupportZoom(true)
                    settings.builtInZoomControls = true
                    settings.displayZoomControls = false
                    webViewClient = object : WebViewClient() {
                        override fun onPageStarted(v: WebView?, url: String?, fav: android.graphics.Bitmap?) {
                            loading = true
                            if (!url.isNullOrEmpty()) addr = url
                        }
                        override fun onPageFinished(v: WebView?, url: String?) {
                            loading = false
                        }
                    }
                    loadUrl(HOME)
                    wv = this
                }
            },
            update = { view ->
                // 只有地址真的变了才 load，否则每次重组都会重新加载页面
                if (view.url != target) view.loadUrl(target)
            }
        )
    }
}

// ------------------------------------------------------------------ 站内信

/** 站内信。`/v1/inbox/list`，用 `X-Account` 头。*/
@Composable
fun InboxScreen(onBack: () -> Unit) {
    var list by remember { mutableStateOf<List<Api.InboxItem>?>(null) }
    val ink = MaterialTheme.colorScheme.onSurface

    LaunchedEffect(Unit) {
        list = withContext(Dispatchers.IO) {
            runCatching { Api.inbox().first }.getOrElse { emptyList() }
        }
    }

    PageScaffold("通知", onBack) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            val items = list
            when {
                items == null -> Box(
                    Modifier.fillMaxWidth().padding(vertical = 60.dp),
                    contentAlignment = Alignment.Center
                ) { Text(tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)) }

                items.isEmpty() -> Box(
                    Modifier.fillMaxWidth().padding(vertical = 60.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(tr("没有新消息"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(5.dp))
                        Text(tr("有公告会出现在这里"), fontSize = V2.tiny,
                            color = ink.copy(alpha = 0.42f))
                    }
                }

                else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                    items.forEachIndexed { i, m ->
                        if (i > 0) RowDividerPublic()
                        Column(Modifier.fillMaxWidth().padding(V2.gutter)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (!m.read) {
                                    Box(
                                        Modifier.size(6.dp).clip(CircleShape)
                                            .background(V2.alert)
                                    )
                                    Spacer(Modifier.width(6.dp))
                                }
                                Text(
                                    m.title.ifEmpty { "公告" },
                                    fontSize = V2.body, fontWeight = FontWeight.Medium,
                                    maxLines = 1, modifier = Modifier.weight(1f, false)
                                )
                            }
                            if (m.body.isNotEmpty()) {
                                Spacer(Modifier.height(4.dp))
                                Text(m.body, fontSize = V2.tiny,
                                    color = ink.copy(alpha = 0.5f), maxLines = 4)
                            }
                            if (m.createdAt.isNotEmpty()) {
                                Spacer(Modifier.height(5.dp))
                                Text(m.createdAt, fontSize = V2.micro,
                                    color = ink.copy(alpha = 0.3f))
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

// ------------------------------------------------------------------ 关于

/**
 * 关于（2026-11-14 第二版）。
 *
 * 用户逐条点过：「关于里面这个路线是可以点击切换的」「还有核心版本账号」
 * 「还有一个检测更新」「关于里面的这个应用图标都没有切换到我们自己的那个」。
 * 第一版是个死页面：一个字母 A 当图标、线路是一串只读文字、没有任何操作。
 */
@Composable
fun AboutScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val scope = rememberCoroutineScope()
    var line by remember { mutableStateOf(Api.lineName()) }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf("") }

    PageScaffold("关于", onBack) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Column(
                Modifier.fillMaxWidth().padding(top = 26.dp, bottom = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // 自己的 logo（之前是个字母 A）
                Image(
                    painterResource(R.drawable.ic_brand_aevis),
                    contentDescription = "Aevis",
                    modifier = Modifier.size(72.dp)
                )
                Spacer(Modifier.height(10.dp))
                Text("Aevis", fontSize = V2.title, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text(
                    "版本 ${BuildConfig.VERSION_NAME}（${BuildConfig.VERSION_CODE}）",
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
                )
            }

            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                AboutRow("核心版本", runCatching { NativeCore.version() }.getOrDefault("—"))
                RowDividerPublic()
                AboutRow(
                    "接口线路", line,
                    onClick = { line = Api.switchLine() },
                    hint = "点一下切换"
                )
                RowDividerPublic()
                AboutRow("账号", Api.email().ifEmpty { "未登录" })
                RowDividerPublic()
                AboutRow(
                    "检测更新",
                    if (busy) "检查中…" else (msg.ifEmpty { "点一下检查" }),
                    onClick = {
                        if (!busy) {
                            busy = true
                            msg = ""
                            scope.launch {
                                val r = withContext(Dispatchers.IO) {
                                    runCatching { Api.latestRelease() }.getOrNull()
                                }
                                busy = false
                                if (r == null) {
                                    msg = "检查失败，稍后再试"
                                } else {
                                    val their = r[1].toIntOrNull() ?: 0
                                    msg = if (their > BuildConfig.VERSION_CODE) {
                                        "有新版本 " + r[0]
                                    } else {
                                        "已是最新"
                                    }
                                }
                            }
                        }
                    },
                    hint = "当前 build ${BuildConfig.VERSION_CODE}"
                )
            }

            Spacer(Modifier.height(16.dp))
            Text(
                tr("Aevis · 和你的 AI 伙伴"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.3f),
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(30.dp))
        }
    }
}

@Composable
private fun AboutRow(
    k: String,
    v: String,
    onClick: (() -> Unit)? = null,
    hint: String? = null
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth()
            .then(if (onClick != null) Modifier.tapable { onClick() } else Modifier)
            .padding(horizontal = V2.gutter, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(tr(k), fontSize = V2.body)
            if (hint != null) {
                Spacer(Modifier.height(2.dp))
                Text(hint, fontSize = V2.micro, color = ink.copy(alpha = 0.35f))
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(
            v, fontSize = V2.tiny,
            color = if (onClick != null) V2.accent else ink.copy(alpha = 0.45f),
            maxLines = 1, textAlign = TextAlign.End
        )
        if (onClick != null) {
            Spacer(Modifier.width(6.dp))
            Icon(
                painterResource(R.drawable.ic_row_chevron), null,
                tint = V2.accent.copy(alpha = 0.5f),
                modifier = Modifier.size(13.dp)
            )
        }
    }
}
// ------------------------------------------------------------------ 网易云

/**
 * 网易云音乐（2026-11-14）。
 *
 * 用户：「发现页把网易云接上」＋「播放页你也没做」。
 *
 * 搜索走网易明文接口（客户端直连），播放地址走我们后端 `/v1/music/url` 代取 ——
 * 客户端直连取地址会被风控（-110），后端带 `Cookie: os=ios` 才给。
 * 音频流本身是直连网易 CDN 的，不经过我们服务器。
 *
 * ⚠️ **还没有网易云账号登录**。iOS 那边走 weapi 那套（AES-CBC + RSA 加密），
 * 安卓要移植 `NeteaseCrypto`，这版没做 —— 所以「我喜欢的音乐 / 我的歌单」
 * 这些需要登录的页拿不到数据，界面上如实写清楚，不装作能用。
 */
@Composable
fun MusicScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var kw by remember { mutableStateOf("") }
    var list by remember { mutableStateOf<List<Api.Track>?>(null) }
    var loading by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }
    var current by remember { mutableStateOf<Api.Track?>(null) }
    var playing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var full by remember { mutableStateOf(false) }   // 全屏播放页

    val scope = rememberCoroutineScope()
    val player = remember { android.media.MediaPlayer() }
    val ctx = LocalContext.current
    val notifPerm = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { if (player.isPlaying) player.stop() }
            runCatching { player.release() }
            LiveUpdate.stop(ctx)
        }
    }

    /** 挂/更新状态栏那颗胶囊（Android 16 才有，低版本自动不发）。*/
    fun pushLive(t: Api.Track) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            runCatching { notifPerm.launch(Manifest.permission.POST_NOTIFICATIONS) }
            return
        }
        LiveUpdate.start(ctx, "正在播放", t.name, -1, R.drawable.ic_row_music)
    }

    fun play(t: Api.Track) {
        if (busy) return
        if (current?.id == t.id) {
            runCatching {
                if (player.isPlaying) {
                    player.pause(); playing = false
                    LiveUpdate.stop(ctx)
                } else {
                    player.start(); playing = true
                    pushLive(t)
                }
            }
            return
        }
        busy = true
        note = ""
        scope.launch {
            val url = withContext(Dispatchers.IO) {
                runCatching { Api.musicUrl(t.id) }.getOrNull()
            }
            if (url.isNullOrEmpty()) {
                note = "这首歌拿不到播放地址（可能没版权或要会员）"
                busy = false
                return@launch
            }
            runCatching {
                player.reset()
                player.setDataSource(url)
                player.setOnPreparedListener {
                    it.start()
                    playing = true
                    current = t
                    pushLive(t)
                }
                player.setOnCompletionListener { playing = false; LiveUpdate.stop(ctx) }
                player.setOnErrorListener { _, _, _ ->
                    note = "播放出错了，换一首试试"
                    playing = false
                    LiveUpdate.stop(ctx)
                    true
                }
                player.prepareAsync()
            }.onFailure { note = "播放器打不开：" + (it.message ?: "") }
            busy = false
        }
    }

    // ---------------- 全屏播放页 ----------------
    if (full) {
        val c = current
        if (c == null) {
            full = false
        } else {
            BackHandler { full = false }
            Column(
                Modifier.fillMaxSize()
                    .background(MaterialTheme.colorScheme.background)
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(horizontal = 26.dp)
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(34.dp).clip(CircleShape).tapable { full = false },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_row_chevron), null,
                            tint = ink.copy(alpha = 0.7f),
                            modifier = Modifier.size(18.dp).rotate(90f)
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                    Text(c.album.ifEmpty { tr("正在播放") }, fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f), maxLines = 1)
                }

                Spacer(Modifier.weight(0.6f))
                // 大封面
                Box(
                    Modifier.fillMaxWidth().aspectRatio(1f)
                        .clip(squircle(24.dp))
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)),
                    contentAlignment = Alignment.Center
                ) {
                    Avatar(c.cover, c.name, 200.dp)
                }
                Spacer(Modifier.height(28.dp))
                Text(c.name, fontSize = 21.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 2, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(6.dp))
                Text(c.artist.ifEmpty { "—" }, fontSize = V2.sub,
                    color = ink.copy(alpha = 0.45f), maxLines = 1,
                    textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())

                Spacer(Modifier.weight(0.5f))

                // 进度
                val pos = runCatching {
                    if (player.isPlaying || playing) player.currentPosition else 0
                }.getOrDefault(0)
                val dur = runCatching { player.duration }.getOrDefault(0)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(fmtMs(pos), fontSize = V2.micro, color = ink.copy(alpha = 0.4f))
                    Text(fmtMs(dur), fontSize = V2.micro, color = ink.copy(alpha = 0.4f))
                }
                Spacer(Modifier.height(6.dp))
                androidx.compose.material3.LinearProgressIndicator(
                    progress = { if (dur > 0) pos.toFloat() / dur else 0f },
                    modifier = Modifier.fillMaxWidth().height(3.dp),
                    color = V2.accent,
                    trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
                )

                Spacer(Modifier.height(26.dp))
                // 播放 / 暂停
                Box(
                    Modifier.align(Alignment.CenterHorizontally)
                        .size(64.dp).clip(CircleShape)
                        .background(V2.accent)
                        .tapable { play(c) },
                    contentAlignment = Alignment.Center
                ) {
                    Text(if (playing) "❚❚" else "▶", fontSize = 22.sp, color = Color.White)
                }
                Spacer(Modifier.height(40.dp))
            }
            return
        }
    }

    PageScaffold("网易云音乐", onBack) {
        Row(
            Modifier.padding(horizontal = V2.gutter, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.weight(1f).clip(squircle(12.dp))
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                BasicTextField(
                    value = kw,
                    onValueChange = { kw = it },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = 14.5.sp, color = ink
                    ),
                    decorationBox = { inner ->
                        if (kw.isEmpty()) {
                            Text(tr("歌名、歌手、或者一句歌词"),
                                fontSize = 14.5.sp, color = ink.copy(alpha = 0.35f))
                        }
                        inner()
                    },
                    modifier = Modifier.fillMaxWidth()
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                if (loading) tr("找…") else tr("搜"),
                fontSize = 14.sp, fontWeight = FontWeight.Medium,
                color = V2.accent,
                modifier = Modifier
                    .clip(squircle(12.dp))
                    .background(V2.accent.copy(alpha = 0.12f))
                    .tapable {
                        if (!loading && kw.isNotBlank()) {
                            loading = true
                            note = ""
                            scope.launch {
                                val r = withContext(Dispatchers.IO) { Api.searchMusic(kw) }
                                list = r
                                if (r.isEmpty()) note = "没搜到，换个词试试"
                                loading = false
                            }
                        }
                    }
                    .padding(horizontal = 15.dp, vertical = 10.dp)
            )
        }

        // 登录态
        var ncName by remember { mutableStateOf(NeteaseAuth.nickName(ctx)) }
        var ncLogged by remember { mutableStateOf(NeteaseAuth.loggedIn(ctx)) }
        var showNcLogin by remember { mutableStateOf(false) }

        if (showNcLogin) {
            NeteaseLoginDialog(
                onClose = { showNcLogin = false },
                onDone = {
                    showNcLogin = false
                    ncLogged = NeteaseAuth.loggedIn(ctx)
                    ncName = NeteaseAuth.nickName(ctx)
                }
            )
        }

        Row(
            Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
                .fillMaxWidth()
                .clip(squircle(12.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.04f))
                .tapable { if (!ncLogged) showNcLogin = true }
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                if (ncLogged) {
                    "已登录网易云" + (if (ncName.isNotEmpty()) "：$ncName" else "")
                } else {
                    "还没登录网易云 · 点这里登录（搜索和播放不需要登录）"
                },
                fontSize = V2.micro,
                color = if (ncLogged) V2.accent else ink.copy(alpha = 0.45f),
                modifier = Modifier.weight(1f)
            )
            if (!ncLogged) {
                Text(tr("登录"), fontSize = V2.micro, color = V2.accent)
            }
        }

        if (note.isNotEmpty()) {
            Text(
                note, fontSize = V2.tiny, color = V2.alert,
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
            )
        }

        Box(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                val items = list
                when {
                    items == null -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 50.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(tr("搜一首歌开始听"), fontSize = V2.tiny,
                            color = ink.copy(alpha = 0.4f))
                    }

                    items.isEmpty() -> Box(
                        Modifier.fillMaxWidth().padding(vertical = 50.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(tr("没有结果"), fontSize = V2.tiny, color = ink.copy(alpha = 0.4f))
                    }

                    else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                        items.forEachIndexed { i, t ->
                            if (i > 0) RowDividerPublic()
                            Row(
                                Modifier.fillMaxWidth().tapable { play(t) }
                                    .padding(horizontal = V2.gutter, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Avatar(t.cover, t.name, 42.dp)
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        t.name, fontSize = V2.body, maxLines = 1,
                                        fontWeight = if (current?.id == t.id)
                                            FontWeight.SemiBold else FontWeight.Normal,
                                        color = if (current?.id == t.id) V2.accent else ink
                                    )
                                    if (t.artist.isNotEmpty()) {
                                        Spacer(Modifier.height(2.dp))
                                        Text(t.artist, fontSize = V2.tiny, maxLines = 1,
                                            color = ink.copy(alpha = 0.45f))
                                    }
                                }
                            }
                        }
                    }
                }
                Spacer(Modifier.height(if (current != null) 78.dp else 24.dp))
            }

            // 迷你播放条 —— 点一下进全屏
            val c = current
            if (c != null) {
                Row(
                    Modifier.align(Alignment.BottomCenter)
                        .padding(horizontal = V2.gutter, vertical = 10.dp)
                        .fillMaxWidth()
                        .clip(squircle(18.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .border(
                            0.5.dp,
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                            squircle(18.dp)
                        )
                        .tapable { full = true }
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Avatar(c.cover, c.name, 34.dp)
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(c.name, fontSize = V2.sub, maxLines = 1,
                            fontWeight = FontWeight.Medium)
                        Text(
                            if (busy) tr("正在取地址…") else if (playing) tr("正在播放")
                            else tr("已暂停"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.42f)
                        )
                    }
                    Box(
                        Modifier.size(34.dp).clip(CircleShape)
                            .background(V2.accent.copy(alpha = 0.14f))
                            .tapable { play(c) },
                        contentAlignment = Alignment.Center
                    ) {
                        Text(if (playing) "❚❚" else "▶", fontSize = 13.sp, color = V2.accent)
                    }
                }
            }
        }
    }
}

/** 大图（方形铺满 + 加密缓存），跟 `Avatar` 共用同一套缓存键。*/
@Composable
private fun BigImage(url: String, name: String, modifier: Modifier) {
    val appCtx = LocalContext.current.applicationContext
    var bmp by remember(url) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(url) {
        if (url.isEmpty()) return@LaunchedEffect
        bmp = withContext(Dispatchers.IO) {
            val ck = "img:" + url
            val cached = com.aevis.android.core.SecureCache.getBytes(appCtx, ck)
            if (cached != null) {
                android.graphics.BitmapFactory.decodeByteArray(cached, 0, cached.size)
            } else {
                val b = runCatching { Api.fetchImage(url) }.getOrNull()
                if (b != null) {
                    runCatching {
                        val out = java.io.ByteArrayOutputStream()
                        b.compress(android.graphics.Bitmap.CompressFormat.JPEG, 88, out)
                        com.aevis.android.core.SecureCache.putBytes(appCtx, ck, out.toByteArray())
                    }
                }
                b
            }
        }
    }
    val f = bmp
    if (f != null) {
        Image(
            bitmap = f.asImageBitmap(), contentDescription = name,
            contentScale = ContentScale.Crop, modifier = modifier
        )
    } else {
        Box(modifier, contentAlignment = Alignment.Center) {
            Text(
                name.take(1), fontSize = 64.sp,
                color = V2.accent.copy(alpha = 0.5f)
            )
        }
    }
}

/** 毫秒 → m:ss */
private fun fmtMs(ms: Int): String {
    if (ms <= 0) return "0:00"
    val s = ms / 1000
    return "%d:%02d".format(s / 60, s % 60)
}
// ------------------------------------------------------------------ 人设详情

/**
 * 人设详情（2026-11-14）。
 *
 * 用户：「人设点进去应该是有个大图展示的…还能添加到联系人里面」。
 * 商城列表只能看名字和一句话，点进去什么都没有 —— 这页补上：
 * 大图 / 名字 / 编号 / 各项设定 / 一句话 / 性格，底部一颗「领养」。
 *
 * ⚠️ 领养关系目前只记在本地（后端 `/psquare/adopt` 只加计数，没有关系表）。
 */
@Composable
fun PersonaDetailScreen(pid: String, onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var p by remember { mutableStateOf<Api.Persona?>(null) }
    var busy by remember { mutableStateOf(false) }
    var adopted by remember { mutableStateOf(Api.isAdopted(pid)) }
    var note by remember { mutableStateOf("") }

    LaunchedEffect(pid) {
        p = withContext(Dispatchers.IO) {
            runCatching { Api.personas().firstOrNull { it.id == pid } }.getOrNull()
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 顶栏
        Row(
            Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).tapable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    painterResource(R.drawable.ic_row_chevron), null,
                    tint = ink.copy(alpha = 0.7f),
                    modifier = Modifier.size(18.dp).rotate(180f)
                )
            }
            Spacer(Modifier.width(6.dp))
            Text(tr("人设详情"), fontSize = V2.title, fontWeight = FontWeight.SemiBold)
        }

        val cur = p
        if (cur == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.4f))
            }
            return
        }

        Box(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                // 大图：优先 cover，没有就用头像放大
                // 大图：**方形铺满**（圆角），不是圆形 —— 圆形会把画像的头和背景裁掉一半
                Box(
                    Modifier.padding(horizontal = V2.gutter).fillMaxWidth()
                        .aspectRatio(0.78f)
                        .clip(squircle(24.dp))
                        .background(V2.accent.copy(alpha = 0.10f)),
                    contentAlignment = Alignment.Center
                ) {
                    BigImage(cur.avatar, cur.name, Modifier.fillMaxSize())
                }

                Spacer(Modifier.height(16.dp))
                Column(Modifier.padding(horizontal = V2.gutter)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(cur.name, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
                        if (cur.official) {
                            Spacer(Modifier.width(8.dp))
                            Text(
                                tr("官方"), fontSize = 10.sp, color = V2.accent,
                                modifier = Modifier.clip(squircle(6.dp))
                                    .background(V2.accent.copy(alpha = 0.13f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        tr("编号 %s", cur.id), fontSize = V2.micro,
                        color = ink.copy(alpha = 0.4f)
                    )
                    if (cur.tagline.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        Text(cur.tagline, fontSize = V2.body, color = ink.copy(alpha = 0.75f))
                    }
                }

                Spacer(Modifier.height(20.dp))
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    if (cur.relation.isNotEmpty()) {
                        InfoLine("关系", relationCn(cur.relation))
                        Spacer(Modifier.height(10.dp))
                    }
                    InfoLine("性格", cur.tagline.ifEmpty { "—" })
                }

                Spacer(Modifier.height(90.dp))
            }

            // 底部领养
            Row(
                Modifier.align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = V2.gutter, vertical = 14.dp)
                    .clip(squircle(16.dp))
                    .background(if (adopted) ink.copy(alpha = 0.06f) else V2.accent)
                    .tapable {
                        if (adopted || busy) return@tapable
                        busy = true
                        note = ""
                        scope.launch {
                            val ok = withContext(Dispatchers.IO) {
                                runCatching { Api.adopt(cur.id) }.getOrDefault(false)
                            }
                            busy = false
                            if (ok) {
                                Api.markAdopted(cur.id)
                                adopted = true
                                note = "已添加到通讯录"
                            } else {
                                note = "领养失败，稍后再试"
                            }
                        }
                    }
                    .padding(vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    when {
                        busy -> tr("处理中…")
                        adopted -> tr("已在通讯录")
                        else -> tr("领养 TA")
                    },
                    fontSize = 16.sp, fontWeight = FontWeight.Medium,
                    color = if (adopted) ink.copy(alpha = 0.45f) else Color.White
                )
            }

            if (note.isNotEmpty()) {
                Text(
                    note, fontSize = V2.tiny, color = V2.accent,
                    modifier = Modifier.align(Alignment.BottomCenter)
                        .padding(bottom = 78.dp)
                )
            }
        }
    }
}

@Composable
private fun InfoLine(k: String, v: String) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column {
        Text(tr(k), fontSize = V2.micro, color = ink.copy(alpha = 0.4f))
        Spacer(Modifier.height(3.dp))
        Text(v, fontSize = V2.body)
    }
}

/** 后端存的是英文 relation，界面上给中文。*/
private fun relationCn(r: String): String = when (r) {
    "lover" -> "恋人"
    "friend" -> "朋友"
    "family" -> "家人"
    else -> r
}
// ------------------------------------------------------------------ 账号

/**
 * 账号与安全（2026-11-14）。
 *
 * 用户：「点击不能去看的这个账号页之类的」—— 「我」页那一行以前点了没反应。
 * 这页放：身份（昵称/邮箱/UID/会员）、登录设备（能踢）、退出登录。
 */
@Composable
fun AccountScreen(onBack: () -> Unit, onSignOut: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val scope = rememberCoroutineScope()
    var me by remember { mutableStateOf<Api.MeInfo?>(Api.cachedMe()) }
    var devices by remember { mutableStateOf<List<Api.Device>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }

    fun load() {
        scope.launch {
            val d = withContext(Dispatchers.IO) {
                runCatching { Api.sessions() }.getOrElse { emptyList() }
            }
            devices = d
            me = withContext(Dispatchers.IO) {
                runCatching { Api.me() }.getOrNull()?.also { runCatching { Api.saveMe(it) } }
            } ?: me
        }
    }

    LaunchedEffect(Unit) { load() }
    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).tapable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    painterResource(R.drawable.ic_row_chevron), null,
                    tint = ink.copy(alpha = 0.7f),
                    modifier = Modifier.size(18.dp).rotate(180f)
                )
            }
            Spacer(Modifier.width(6.dp))
            Text(tr("账号与安全"), fontSize = V2.title, fontWeight = FontWeight.SemiBold)
        }

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // 名片
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.padding(horizontal = V2.gutter, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val name = me?.nickname?.takeIf { it.isNotBlank() }
                        ?: Api.email().substringBefore("@").ifEmpty { "A" }
                    Avatar(me?.avatar.orEmpty(), name, 56.dp)
                    Spacer(Modifier.width(13.dp))
                    Column(Modifier.weight(1f)) {
                        Text(name, fontSize = V2.title, fontWeight = FontWeight.SemiBold,
                            maxLines = 1)
                        Spacer(Modifier.height(3.dp))
                        Text(Api.email().ifEmpty { tr("未登录") },
                            fontSize = V2.tiny, color = ink.copy(alpha = 0.45f),
                            maxLines = 1)
                    }
                }
                RowDividerPublic()
                AboutRow("UID", Api.uid().ifEmpty { "—" })
                RowDividerPublic()
                AboutRow("会员", me?.membership?.ifEmpty { tr("普通用户") } ?: tr("普通用户"))
            }

            // 登录设备
            Spacer(Modifier.height(18.dp))
            Text(
                tr("登录设备"),
                fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(start = V2.gutter, bottom = 8.dp)
            )
            val ds = devices
            when {
                ds == null -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Text(tr("正在加载…"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.4f),
                        modifier = Modifier.padding(vertical = 14.dp))
                }

                ds.isEmpty() -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Text(tr("还没有登录记录"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.4f),
                        modifier = Modifier.padding(vertical = 14.dp))
                }

                else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                    ds.forEachIndexed { i, d ->
                        if (i > 0) RowDividerPublic()
                        Row(
                            Modifier.fillMaxWidth()
                                .padding(horizontal = V2.gutter, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        d.device.ifEmpty { d.ip.ifEmpty { "—" } },
                                        fontSize = V2.body, maxLines = 1,
                                        fontWeight = FontWeight.Medium
                                    )
                                    if (d.current) {
                                        Spacer(Modifier.width(6.dp))
                                        Text(
                                            tr("当前设备"), fontSize = 9.5.sp,
                                            color = V2.accent,
                                            modifier = Modifier.clip(squircle(5.dp))
                                                .background(V2.accent.copy(alpha = 0.13f))
                                                .padding(horizontal = 5.dp, vertical = 1.5.dp)
                                        )
                                    }
                                }
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    listOf(d.ip, d.createdAt).filter { it.isNotEmpty() }
                                        .joinToString(" · "),
                                    fontSize = V2.micro, color = ink.copy(alpha = 0.4f),
                                    maxLines = 1
                                )
                            }
                            if (!d.current) {
                                Text(
                                    tr("下线"), fontSize = V2.tiny, color = V2.alert,
                                    modifier = Modifier
                                        .clip(squircle(10.dp))
                                        .background(V2.alert.copy(alpha = 0.10f))
                                        .tapable {
                                            if (!busy) {
                                                busy = true
                                                scope.launch {
                                                    withContext(Dispatchers.IO) {
                                                        runCatching { Api.revokeSession(d.token) }
                                                    }
                                                    busy = false
                                                    load()
                                                }
                                            }
                                        }
                                        .padding(horizontal = 12.dp, vertical = 6.dp)
                                )
                            }
                        }
                    }
                }
            }

            if (note.isNotEmpty()) {
                Text(
                    note, fontSize = V2.tiny, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
                )
            }

            Spacer(Modifier.height(18.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().tapable { Api.signOut(); onSignOut() }
                        .padding(horizontal = V2.gutter, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(tr("退出登录"), fontSize = V2.body, color = V2.alert)
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}
// ------------------------------------------------------------------ 网易云登录

/**
 * 网易云扫码登录（2026-11-14）。
 *
 * 用户：「网易云的登录要做」。iOS 那边早就有了（扫码 → 拿 MUSIC_U → 存在钥匙串），
 * 安卓一直没有 —— 因为要移植 weapi 加密（AES-CBC 两层 + RSA）。
 *
 * 流程：`/weapi/login/qrcode/unikey` 拿 key → 把
 * `https://music.163.com/scan_qrcode?codekey=<key>` 画成二维码 → 用户用网易云 App 扫 →
 * 每 2 秒轮询 `/weapi/login/qrcode/client/login`，803 那次响应里带 `MUSIC_U`。
 */
@Composable
fun NeteaseLoginDialog(onClose: () -> Unit, onDone: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    var qr by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var status by remember { mutableStateOf("正在生成二维码…") }
    var round by remember { mutableIntStateOf(0) }

    LaunchedEffect(round) {
        qr = null
        status = "正在生成二维码…"
        val k = withContext(Dispatchers.IO) { runCatching { NeteaseAuth.qrKey() }.getOrNull() }
        if (k == null) {
            status = "拿不到二维码，稍后再试"
            return@LaunchedEffect
        }
        val bmp = withContext(Dispatchers.IO) { qrBitmap(k.url, 480) }
        if (bmp == null) {
            status = "二维码画不出来"
            return@LaunchedEffect
        }
        qr = bmp
        status = "打开网易云 App → 右上角扫一扫"

        // 90 × 2s = 3 分钟（网易的 unikey 就是这个寿命）
        repeat(90) {
            delay(2000)
            val (st, ck) = withContext(Dispatchers.IO) { NeteaseAuth.qrPoll(k.key) }
            when (st) {
                "ok" -> {
                    if (ck.contains("MUSIC_U=")) {
                        val acc = withContext(Dispatchers.IO) {
                            runCatching {
                                NeteaseAuth.saveLogin(ctx, ck, "", "")
                                NeteaseAuth.fetchAccount(ctx)
                            }.getOrNull()
                        }
                        if (acc != null) {
                            NeteaseAuth.saveLogin(ctx, ck, acc.first, acc.second)
                        }
                        status = "登录成功"
                        onDone()
                    } else {
                        status = "登录返回异常（没拿到凭证），再试一次"
                    }
                    return@LaunchedEffect
                }
                "scanned" -> status = "已扫码，请在手机上点确认"
                "expired" -> { status = "二维码过期了"; return@LaunchedEffect }
                "err" -> { status = "轮询失败，换个网络试试"; return@LaunchedEffect }
            }
        }
        status = "二维码过期了"
    }

    Dialog(onDismissRequest = onClose) {
        Column(
            Modifier.clip(squircle(24.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(horizontal = 22.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(tr("登录网易云"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            Text(
                status, fontSize = 12.5.sp, color = ink.copy(alpha = 0.5f),
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(16.dp))
            Box(
                Modifier.size(220.dp).clip(squircle(16.dp))
                    .background(ink.copy(alpha = 0.04f)),
                contentAlignment = Alignment.Center
            ) {
                val b = qr
                if (b != null) {
                    Image(
                        bitmap = b.asImageBitmap(), contentDescription = "网易云登录二维码",
                        modifier = Modifier.size(200.dp)
                    )
                } else {
                    Text(
                        tr("正在加载…"), fontSize = 13.sp,
                        color = ink.copy(alpha = 0.4f)
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = { round++ }) {
                    Text(tr("换一张"), fontSize = 14.sp, color = V2.accent)
                }
                TextButton(onClick = onClose) {
                    Text(tr("取消"), fontSize = 14.sp, color = ink.copy(alpha = 0.5f))
                }
            }
        }
    }
}

/** 把内容画成二维码 Bitmap。用 zxing 的 core（扫一扫那边已经在用同一个库）。*/
private fun qrBitmap(text: String, size: Int): android.graphics.Bitmap? = runCatching {
    val m = com.google.zxing.qrcode.QRCodeWriter()
        .encode(text, com.google.zxing.BarcodeFormat.QR_CODE, size, size)
    val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
    for (x in 0 until size) {
        for (y in 0 until size) {
            bmp.setPixel(
                x, y,
                if (m[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE
            )
        }
    }
    bmp
}.getOrNull()
