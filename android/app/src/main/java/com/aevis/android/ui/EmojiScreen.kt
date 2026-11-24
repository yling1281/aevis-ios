package com.aevis.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.SecureCache
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 表情包浏览页（2026-11-16）。
 *
 * 用户：「表情包能看、能发」。这页只负责**看** —— 真正发送在聊天页的面板里
 * （[EmojiSheet]）。分两个地方是因为：浏览时你可能想慢慢挑，
 * 聊天时你只想快速甩一张过去，两套交互混在一起谁都不顺手。
 *
 * 数据源 `/v1/emoji/list` 每行自带 `items`（这一套里所有图的相对路径），
 * 所以一套表情的所有内容一次请求就全拿到了，点开不用再等。
 */
@Composable
fun EmojiScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var packs by remember { mutableStateOf<List<Api.EmojiPack>?>(null) }
    // 点某个表情 → 大图预览（这页只浏览，不发送）
    var preview by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        packs = withContext(Dispatchers.IO) {
            runCatching { Api.emojiPacks() }.getOrElse { emptyList() }
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "表情包", onBack = onBack)

        when (val ps = packs) {
            null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    tr("正在加载…"), fontSize = V2.tiny,
                    color = ink.copy(alpha = 0.4f)
                )
            }

            else -> if (ps.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        tr("还没有表情包"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f)
                    )
                }
            } else {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                    EmojiGallery(ps, onTap = { preview = it })
                    Spacer(Modifier.height(28.dp))
                }
            }
        }
    }

    // 大图预览：只看看，不给"发送"按钮（发送在聊天页）
    val pv = preview
    if (pv != null) {
        EmojiPreviewSheet(url = pv, onDismiss = { preview = null })
    }
}

/**
 * 一整套表情包的画廊（2026-11-16 抽出来：表情包页、广场的「表情包」段共用）。
 *
 * 以前广场里表情包是"一行一个包 + 49dp 封面"，点不进也看不到内容 ——
 * 用户要的是**能看**，所以改成每个包一个标题 + 四列网格。
 */
@Composable
internal fun EmojiGallery(packs: List<Api.EmojiPack>, onTap: (String) -> Unit = {}) {
    Column(Modifier.fillMaxWidth()) {
        packs.forEach { pack -> EmojiPackSection(pack, onTap) }
    }
}

/** 一套表情：标题行 + 4 列网格。*/
@Composable
private fun EmojiPackSection(pack: Api.EmojiPack, onTap: (String) -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    // 名字为空就用 intro 前 12 个字 —— 后端有些包只有简介
    val title = pack.name.ifBlank { pack.intro.take(12) }.ifBlank { tr("表情包") }
    Row(
        Modifier.fillMaxWidth()
            .padding(start = V2.gutter, end = V2.gutter, top = 14.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            title, fontSize = V2.body, fontWeight = FontWeight.Medium, maxLines = 1,
            modifier = Modifier.weight(1f, fill = false)
        )
        Spacer(Modifier.width(6.dp))
        Text(
            tr("%d 个", pack.items.size), fontSize = V2.micro,
            color = ink.copy(alpha = 0.4f)
        )
    }
    if (pack.intro.isNotBlank() && pack.name.isNotBlank()) {
        Text(
            pack.intro, fontSize = V2.micro, color = ink.copy(alpha = 0.38f), maxLines = 2,
            modifier = Modifier.padding(horizontal = V2.gutter).padding(bottom = 6.dp)
        )
    }
    EmojiGrid(pack.items, onTap, Modifier.padding(horizontal = V2.gutter))
}

/**
 * 4 列网格。
 *
 * 为什么不用 `LazyVerticalGrid`：这个页面外层已经是 `verticalScroll`，
 * 两个竖向滚动套在一起会让手势打架（而且每套表情最多几十个格子，不是长列表）。
 * 用 `chunked(4)` + 等宽 Row 足够，还省一个 Lazy 作用域的心智负担。
 */
@Composable
internal fun EmojiGrid(
    urls: List<String>,
    onTap: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier.fillMaxWidth()) {
        urls.chunked(4).forEach { row ->
            Row(
                Modifier.fillMaxWidth().padding(bottom = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                row.forEach { u ->
                    EmojiImage(
                        url = u,
                        modifier = Modifier.weight(1f).aspectRatio(1f),
                        onClick = { onTap(u) }
                    )
                }
                // 最后一行不满 4 个时补空位，否则格子会被拉宽（看着大小不一）
                repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

/**
 * 一张表情图（浏览页和聊天面板共用）。
 *
 * 加载逻辑跟 `Avatar()` 对齐：本地文件读盘、其余走 `Api.fetchImage`
 * （**用 `isLocalFile` 判断，别自己写 `startsWith("/")`** —— 服务端相对路径
 * `/v1/media/…` 也以 / 开头，踩过一次，全站图片都变成首字母）。
 * 缓存键跟头像共用 `img:` 前缀，一张图在两处出现只下一次。
 */
@Composable
internal fun EmojiImage(
    url: String,
    modifier: Modifier = Modifier,
    radius: Dp = 12.dp,
    scale: ContentScale = ContentScale.Crop,
    placeholderBg: Boolean = true,
    failText: String = "",
    onClick: (() -> Unit)? = null
) {
    val appCtx = LocalContext.current.applicationContext
    var bmp by remember(url) { mutableStateOf<Bitmap?>(null) }
    var done by remember(url) { mutableStateOf(false) }

    LaunchedEffect(url) {
        if (url.isEmpty()) { bmp = null; done = true; return@LaunchedEffect }
        bmp = withContext(Dispatchers.IO) {
            if (isLocalFile(url)) {
                com.aevis.android.data.decodeSampledFile(localImagePath(url), 128, 128)
            } else {
                val ck = "img:" + url
                val cached = SecureCache.getBytes(appCtx, ck)
                if (cached != null) {
                    BitmapFactory.decodeByteArray(cached, 0, cached.size)
                } else {
                    val b = runCatching { Api.fetchImage(url) }.getOrNull()
                    if (b != null) {
                        runCatching {
                            val out = java.io.ByteArrayOutputStream()
                            b.compress(Bitmap.CompressFormat.JPEG, 85, out)
                            SecureCache.putBytes(appCtx, ck, out.toByteArray())
                        }
                    }
                    b
                }
            }
        }
        done = true
    }

    val bg = if (placeholderBg) V2.accent.copy(alpha = 0.10f) else Color.Transparent
    val base = if (onClick != null) {
        modifier.clip(squircle(radius)).background(bg).tapable { onClick() }
    } else {
        modifier.clip(squircle(radius)).background(bg)
    }
    Box(base, contentAlignment = Alignment.Center) {
        val f = bmp
        if (f != null) {
            Image(
                bitmap = f.asImageBitmap(), contentDescription = null,
                contentScale = scale, modifier = Modifier.fillMaxSize()
            )
        } else if (done) {
            // 加载完了还是没有 —— 如实说，别一直转圈让人等
            Text(
                failText.ifEmpty { "…" }, fontSize = 11.sp,
                color = V2.accent.copy(alpha = 0.55f)
            )
        } else {
            Text("…", fontSize = 14.sp, color = V2.accent.copy(alpha = 0.45f))
        }
    }
}

/** 大图预览（表情包页 / 广场共用）。*/
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EmojiPreviewSheet(url: String, onDismiss: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surface,
        scrimColor = Color.Black.copy(alpha = 0.32f)
    ) {
        Column(
            Modifier.fillMaxWidth()
                .padding(horizontal = V2.gutter)
                .navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            EmojiImage(
                url = url,
                modifier = Modifier.size(220.dp),
                radius = 16.dp,
                scale = ContentScale.Fit,
                failText = tr("图片加载失败")
            )
            Spacer(Modifier.height(12.dp))
            Text(
                tr("在聊天页点输入框左边的表情按钮就能发出去"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
            )
            Spacer(Modifier.height(18.dp))
        }
    }
}

/**
 * 聊天页的表情面板（[ChatScreen] 和 [GroupChatScreen] 共用，**不要复制第二份**）。
 *
 * 顶部一排包名横向可滑，下面是当前包的四列网格；点一个就回调 `onPick(url)`，
 * 由聊天页负责"变成一条图片消息"。面板自己不碰会话状态。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EmojiSheet(onPick: (String) -> Unit, onDismiss: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var packs by remember { mutableStateOf<List<Api.EmojiPack>?>(null) }
    var sel by remember { mutableIntStateOf(0) }

    LaunchedEffect(Unit) {
        packs = withContext(Dispatchers.IO) {
            runCatching { Api.emojiPacks() }.getOrElse { emptyList() }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surface,
        scrimColor = Color.Black.copy(alpha = 0.32f)
    ) {
        Column(
            Modifier.fillMaxWidth()
                .padding(horizontal = V2.gutter)
                .navigationBarsPadding()
        ) {
            Text(tr("表情包"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            val ps = packs
            if (ps == null) {
                Box(
                    Modifier.fillMaxWidth().height(120.dp),
                    contentAlignment = Alignment.Center
                ) { Text(tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.4f)) }
            } else if (ps.isEmpty()) {
                Box(
                    Modifier.fillMaxWidth().height(120.dp),
                    contentAlignment = Alignment.Center
                ) { Text(tr("还没有表情包"), fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)) }
            } else {
                val cur = ps.getOrNull(sel) ?: ps.first()
                // 包名切换：横向可滑，选中的用主色药丸
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(bottom = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    ps.forEachIndexed { i, p ->
                        val on = p.id == cur.id
                        val label = p.name.ifBlank { p.intro.take(8) }.ifBlank { tr("表情") }
                        Text(
                            label, fontSize = V2.tiny,
                            fontWeight = if (on) FontWeight.Medium else FontWeight.Normal,
                            color = if (on) V2.accent else ink.copy(alpha = 0.55f),
                            maxLines = 1,
                            modifier = Modifier
                                .clip(squircle(10.dp))
                                .background(
                                    if (on) V2.accent.copy(alpha = 0.12f)
                                    else ink.copy(alpha = 0.04f)
                                )
                                .tapable { sel = i }
                                .padding(horizontal = 11.dp, vertical = 7.dp)
                        )
                    }
                }

                // 面板高度封顶 + 内部可滚：一套几百张时不会把整个屏幕顶满
                Column(
                    Modifier.fillMaxWidth().heightIn(max = 330.dp)
                        .verticalScroll(rememberScrollState())
                ) {
                    // 注意用命名参数：`EmojiGrid` 的最后一个参数是 modifier，
                    // 直接写尾随 lambda 会被当成 modifier 传进去（编译不过）
                    EmojiGrid(cur.items, onTap = { u -> onPick(u) })
                }
            }
            Spacer(Modifier.height(14.dp))
        }
    }
}
