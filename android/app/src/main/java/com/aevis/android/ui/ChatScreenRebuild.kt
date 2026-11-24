package com.aevis.android.ui

import com.aevis.android.R
import androidx.compose.ui.res.painterResource
import androidx.compose.material3.Icon
import android.graphics.BitmapFactory
import android.speech.tts.TextToSpeech
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.BackgroundStore
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.LocalPersonaStore
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 聊天页（第 4 版，按用户逐条 bug 修）。
 * 默认贴底 / 顶栏名字 / 双头头像 / 单行输入 + imePadding / 面板动效 /
 * 一条条发（标点兜底）/ 麦克风=本地 TTS / 日记与设置分开入口。
 */

internal fun chatAnnotated(
    text: String, normal: Color, dim: Color, visibleLen: Int = -1
): AnnotatedString {
    val limit = if (visibleLen >= 0) minOf(visibleLen, text.length) else text.length
    return buildAnnotatedString {
        var depth = 0
        for (i in 0 until limit) {
            val c = text[i]
            when (c) {
                '（', '(', '【', '[' -> { depth++; withStyle(SpanStyle(color = dim)) { append(c) } }
                '）', ')', '】', ']' -> {
                    withStyle(SpanStyle(color = dim)) { append(c) }
                    if (depth > 0) depth--
                }
                else -> {
                    if (depth > 0) withStyle(SpanStyle(color = dim)) { append(c) }
                    else withStyle(SpanStyle(color = normal)) { append(c) }
                }
            }
        }
    }
}

internal fun loadMemes(ctx: android.content.Context): List<String> = emptyList()
internal fun appendMemes(list: List<String>): String = ""
internal fun statusOf(pid: Long, kind: Int): String = ""

private val BubbleWhite = Color(0xF2FFFFFF)
private val MineBlue = Color(0xFFD8E2FF)
private val InkDark = Color(0xFF1B1D2A)
private val InkDim = Color(0xFF6B7189)
private val AccentBlue = Color(0xFF4A6CF7)

@Composable
fun ChatScreen(
    pid: String,
    onBack: () -> Unit,
    onOpenRoleSet: (String) -> Unit = {},
    onOpenPersona: (String) -> Unit = {},
    onOpenLook: (String) -> Unit = {},
    onOpenDiary: (String) -> Unit = {},
    onOpenModels: (String) -> Unit = {}
) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current

    val persona = remember(pid) { runCatching { LocalPersonaStore.find(pid) }.getOrNull() }
    val charName = persona?.name ?: ""
    val charAvatar = persona?.avatar ?: ""

    var msgs by remember(pid) { mutableStateOf<List<Api.Msg>>(emptyList()) }
    var input by remember(pid) { mutableStateOf("") }
    var sending by remember(pid) { mutableStateOf(false) }
    var err by remember(pid) { mutableStateOf("") }
    var plusOpen by remember(pid) { mutableStateOf(false) }
    var panel by remember(pid) { mutableStateOf(0) }
    var uploading by remember(pid) { mutableStateOf(false) }
    var loaded by remember(pid) { mutableStateOf(false) }

    var ttsReady by remember { mutableStateOf(false) }
    val tts = remember {
        runCatching { TextToSpeech(ctx) { st -> ttsReady = st == TextToSpeech.SUCCESS } }.getOrNull()
    }
    DisposableEffect(Unit) {
        onDispose { runCatching { tts?.stop(); tts?.shutdown() } }
    }

    val avatarBmp = remember(charAvatar) {
        runCatching {
            if (charAvatar.isNotBlank() && !charAvatar.startsWith("http"))
                BitmapFactory.decodeFile(File(charAvatar).absolutePath) else null
        }.getOrNull()
    }

    LaunchedEffect(pid) {
        msgs = withContext(Dispatchers.IO) { runCatching { Api.loadConv(pid) }.getOrDefault(emptyList()) }
        loaded = true
    }

    val listState = rememberLazyListState()
    // 188：分页渲染 —— 数据层仍是全量（loadConv 不变），只控制"画多少条"。
    // 3648 条一次性渲染会明显卡顿，且滚动位置容易跳。
    var shown by remember(pid) { mutableIntStateOf(80) }
    val render = remember(msgs, shown) {
        if (msgs.size <= shown) msgs else msgs.takeLast(shown)
    }
    // 189：滚到最顶附近自动加载（按钮保留兜底）。防抖：用 lastAuto 记录上次触发时的 shown。
    var lastAuto by remember(pid) { mutableIntStateOf(-1) }
    LaunchedEffect(listState, msgs.size, shown) {
        snapshotFlow { listState.firstVisibleItemIndex }
            .collect { idx ->
                if (idx <= 2 && msgs.size > shown && lastAuto != shown) {
                    lastAuto = shown
                    shown = minOf(shown + 200, msgs.size)
                }
            }
    }

    LaunchedEffect(loaded, msgs.size) {
        // 189 修复：列表只渲染 render（最近 shown 条），不带"加载更早"横幅时最后一项索引是 render.lastIndex。
        // 之前用 msgs.lastIndex（全量索引）会越界 → 点进长会话直接闪退。
        if (loaded && render.isNotEmpty()) {
            val extra = if (msgs.size > shown) 1 else 0
            val target = (render.size - 1 + extra).coerceAtLeast(0)
            runCatching { listState.scrollToItem(target) }
        }
    }

    fun pushOut(text: String) {
        val after = msgs + Api.Msg("assistant", text)
        msgs = after
        Api.saveConv(pid, after)
    }

    val pickImage = rememberLauncherForActivityResult(
        ActivityResultContracts.GetContent()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        uploading = true
        scope.launch {
            val path = withContext(Dispatchers.IO) {
                runCatching { Api.uploadImage(ctx, uri) }.getOrNull()
            }
            uploading = false
            if (path.isNullOrBlank()) err = "图片上传失败"
            else {
                val after = msgs + Api.Msg("user", "[图片]")
                msgs = after
                Api.saveConv(pid, after)
                plusOpen = false
            }
        }
    }

    fun speakLast() {
        val last = msgs.lastOrNull { it.role != "user" }?.content
        if (last.isNullOrBlank()) { err = "还没有可以朗读的消息"; return }
        if (!ttsReady) { err = "语音引擎没就绪"; return }
        runCatching {
            tts?.language = java.util.Locale.CHINA
            tts?.speak(last, TextToSpeech.QUEUE_FLUSH, null, "aevis")
        }
    }

    fun send() {
        val text = input.trim()
        if (text.isEmpty() || sending) return
        input = ""
        err = ""
        plusOpen = false
        focus.clearFocus()
        val withUser = msgs + Api.Msg("user", text)
        msgs = withUser
        Api.saveConv(pid, withUser)
        sending = true
        scope.launch {
            val isOs = ChatPrefs.chatMode == 1
            val sys = buildString {
                if (charName.isNotBlank()) appendLine("你叫$charName。")
                val pText = persona?.persona ?: ""
                if (pText.isNotBlank()) appendLine("你的人设：" + pText.take(2000))
                if (isOs) {
                    appendLine("【内心 OS 模式】这一轮只写一段内心独白，200-600 字；可以用括号写动作神态；不分条、不加小标题。")
                } else {
                    appendLine("【微信聊天模式】每条不超过 15 字；一次发 3-5 条，情绪起来 6-8 条；每条之间用换行分开；不要用括号写动作。")
                }
                appendLine("【状态标记】回复最后单独一行输出 [[状态]]两到六个字，用户看不到。")
            }
            val reply = withContext(Dispatchers.IO) {
                Api.chat("deepseek-flash", withUser.takeLast(20), sys)
            }
            if (reply.isNullOrBlank()) {
                err = Api.lastChatError.ifBlank { "发送失败" }
                sending = false
                return@launch
            }
            val clean = reply.replace(Regex("\\[\\[状态\\]\\].*"), "").trim()
            val parts = if (isOs) listOf(clean) else {
                val byLine = splitReply(clean, "。！？～")
                if (byLine.size <= 1 && clean.length > 24) {
                    val cut = splitByPunct(clean, "。！？…").map { it.trim() }.filter { it.isNotEmpty() }
                    if (cut.size >= 2) cut.take(4) else byLine
                } else byLine
            }
            parts.forEachIndexed { i, part ->
                if (i > 0) delay(if (part.length > 40) 900L else 620L)
                pushOut(part)
            }
            sending = false
        }
    }

    Box(Modifier.fillMaxSize()) {
        BackgroundStore.renderBg(
            ctx, ChatPrefs.bgKind, ChatPrefs.bgPreset,
            ChatPrefs.bgBlur, ChatPrefs.bgOpacity, ChatPrefs.bgVersion
        )

        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(40.dp).clip(RoundedCornerShape(50)).tapable { onBack() },
                    contentAlignment = Alignment.Center
                ) { Text("‹", fontSize = 27.sp, color = InkDark) }

                Column(Modifier.weight(1f)) {
                    Text(
                        charName.ifBlank { "聊天" },
                        fontSize = 17.sp, fontWeight = FontWeight.Bold, color = InkDark, maxLines = 1
                    )
                    Text(
                        // 177：真·显示上下文条数
                        if (sending) "正在输入…"
                        else "在线 · 上下文 ${com.aevis.android.core.ChatPrefs.ctxWindow} 条",
                        fontSize = 11.sp, color = if (sending) AccentBlue else InkDim, maxLines = 1
                    )
                }

                // 180：书=角色设定、日记=笔记本，语义要分开 → 日记用 ic_diary（工程里本来就有）
                CircleIcon(R.drawable.ic_diary) { onOpenDiary(pid) }
                Spacer(Modifier.width(6.dp))
                CircleIcon(R.drawable.ic_menu) { onOpenRoleSet(pid) }
            }

            if (err.isNotBlank()) {
                Text(
                    err, fontSize = 12.sp, color = Color(0xFFD9534F),
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 2.dp)
                )
            }

            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp)
            ) {
                if (msgs.size > shown) {
                    item(key = "loadMore") {
                        // 189：顶部**横幅**（浅底条），不再做成普通文字行 ——
                        // 用户会误以为消息被删了，必须一眼看出"共 N 条，只是未展开"。
                        Row(
                            Modifier.fillMaxWidth()
                                .background(InkDim.copy(alpha = 0.07f))
                                .tapable {
                                    val added = minOf(200, msgs.size - shown)
                                    val keepIdx = listState.firstVisibleItemIndex
                                    val keepOff = listState.firstVisibleItemScrollOffset
                                    shown += added
                                    kotlinx.coroutines.MainScope().launch {
                                        runCatching {
                                            listState.scrollToItem(keepIdx + added + 1, keepOff)
                                        }
                                    }
                                }
                                .padding(horizontal = 12.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                "已显示最近 ${shown} 条 / 共 ${msgs.size} 条",
                                fontSize = 11.5.sp, color = InkDim
                            )
                            Spacer(Modifier.weight(1f))
                            Text(
                                "加载更早",
                                fontSize = 11.5.sp, color = AccentBlue
                            )
                        }
                    }
                }
                itemsIndexed(render) { i, m ->
                    val mine = m.role == "user"
                    if (i > 0 && i % 14 == 0) {
                        Text(
                            "· · ·", fontSize = 11.sp, color = InkDim.copy(alpha = 0.55f),
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            textAlign = TextAlign.Center
                        )
                    }
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 5.dp),
                        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
                        verticalAlignment = Alignment.Top
                    ) {
                        if (!mine) {
                            Avatar(avatarBmp, charName)
                            Spacer(Modifier.width(8.dp))
                        }
                        Box(
                            Modifier.widthIn(max = 258.dp)
                                .clip(RoundedCornerShape(18.dp))
                                .background(if (mine) MineBlue else BubbleWhite)
                                .padding(horizontal = 13.dp, vertical = 10.dp)
                        ) {
                            Text(
                                text = chatAnnotated(m.content, InkDark, InkDim),
                                fontSize = 15.sp, lineHeight = 23.sp
                            )
                        }
                        if (mine) {
                            Spacer(Modifier.width(8.dp))
                            // 177：写死 null 就是"换了头像聊天页不变"的真因
                            MeBubbleAvatar()
                        }
                    }
                }
            }

            Row(
                Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.weight(1f).height(42.dp)
                        .clip(RoundedCornerShape(21.dp))
                        .background(BubbleWhite)
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.CenterStart
                ) {
                    if (input.isEmpty() && !plusOpen) {
                        Text("输入消息", fontSize = 14.sp, color = InkDim.copy(alpha = 0.65f))
                    }
                    BasicTextField(
                        value = input,
                        onValueChange = { if (!plusOpen) input = it },
                        readOnly = plusOpen,
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp, color = InkDark),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                Spacer(Modifier.width(8.dp))

                if (input.isNotBlank() && !plusOpen) {
                    SendKey(sending) { send() }
                } else {
                    CircleIcon(R.drawable.ic_volume) { speakLast() }
                }
                Spacer(Modifier.width(8.dp))

                val rot by animateFloatAsState(
                    targetValue = if (plusOpen) 45f else 0f,
                    animationSpec = spring(dampingRatio = 0.55f),
                    label = "plus"
                )
                Box(
                    Modifier.size(42.dp)
                        .clip(RoundedCornerShape(50))
                        .background(if (plusOpen) MineBlue else BubbleWhite)
                        .tapable {
                            plusOpen = !plusOpen
                            if (plusOpen) focus.clearFocus()
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        "＋", fontSize = 20.sp, color = InkDark,
                        modifier = Modifier.graphicsLayer { rotationZ = rot }
                    )
                }
            }

            AnimatedVisibility(
                visible = plusOpen,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically()
            ) {
                Column(
                    Modifier.fillMaxWidth()
                        .background(Color(0xF7F7F9FF))
                        .padding(horizontal = 16.dp, vertical = 14.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (panel == 0) "功能" else "表情包",
                            fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = InkDim
                        )
                        Spacer(Modifier.weight(1f))
                        if (panel == 1) {
                            Text(
                                "返回", fontSize = 12.sp, color = AccentBlue,
                                modifier = Modifier.tapable { panel = 0 }
                            )
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    if (panel == 0) {
                        Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                            PanelItem("相册", uploading) { pickImage.launch("image/*") }
                            PanelItem("拍照", false) { pickImage.launch("image/*") }
                            PanelItem("表情", false) { panel = 1 }
                            PanelItem("背景", false) { onOpenLook(pid) }
                        }
                    } else {
                        val emojis = listOf(
                            "🥺", "😭", "🥰", "😤", "😴", "🙈",
                            "💔", "✨", "🐱", "🍚", "🌙", "❤️",
                            "😳", "🤍", "🎀", "📎"
                        )
                        Column {
                            emojis.chunked(4).forEach { rowItems ->
                                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    rowItems.forEach { e ->
                                        Box(
                                            Modifier.height(64.dp).weight(1f)
                                                .clip(RoundedCornerShape(14.dp))
                                                .background(Color.White)
                                                .tapable {
                                                    input = input + e
                                                    plusOpen = false
                                                },
                                            contentAlignment = Alignment.Center
                                        ) { Text(e, fontSize = 26.sp) }
                                    }
                                }
                                Spacer(Modifier.height(10.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Avatar(bmp: android.graphics.Bitmap?, name: String) {
    Box(
        Modifier.size(32.dp).clip(RoundedCornerShape(50)).background(Color(0xE6FFFFFF)),
        contentAlignment = Alignment.Center
    ) {
        if (bmp != null) {
            Image(
                bitmap = bmp.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(50))
            )
        } else {
            Text(
                name.take(1).ifBlank { "?" },
                fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = InkDark
            )
        }
    }
}

@Composable
private fun SendKey(sending: Boolean, onClick: () -> Unit) {
    val scale by animateFloatAsState(
        targetValue = if (sending) 0.92f else 1f,
        animationSpec = spring(dampingRatio = 0.45f),
        label = "send"
    )
    Box(
        Modifier.size(42.dp)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(RoundedCornerShape(50))
            .background(AccentBlue)
            .tapable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        if (sending) {
            Text("·", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = Color.White)
        } else {
            Icon(
                painterResource(R.drawable.ic_send), contentDescription = "发送",
                tint = Color.White, modifier = Modifier.size(18.dp)
            )
        }
    }
}

/** 177：矢量图标版（emoji 换成 drawable）。*/
@Composable
private fun CircleIcon(@androidx.annotation.DrawableRes icon: Int, onClick: () -> Unit) {
    Box(
        Modifier.size(38.dp).clip(RoundedCornerShape(50))
            .background(Color(0xE6FFFFFF))
            .tapable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            painterResource(icon), contentDescription = null,
            tint = InkDark, modifier = Modifier.size(18.dp)
        )
    }
}

@Composable
private fun CircleIcon(symbol: String, onClick: () -> Unit) {
    Box(
        Modifier.size(38.dp).clip(RoundedCornerShape(50))
            .background(Color(0xE6FFFFFF))
            .tapable { onClick() },
        contentAlignment = Alignment.Center
    ) { Text(symbol, fontSize = 14.sp, color = InkDark) }
}

@Composable
private fun PanelItem(label: String, busy: Boolean, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.size(56.dp).clip(RoundedCornerShape(16.dp))
                .background(Color.White)
                .tapable { if (!busy) onClick() },
            contentAlignment = Alignment.Center
        ) {
            Text(if (busy) "…" else label.take(1), fontSize = 17.sp, color = InkDark)
        }
        Spacer(Modifier.height(6.dp))
        Text(label, fontSize = 11.5.sp, color = InkDim)
    }
}

/**
 * 我方气泡头像（2026-11-17，177）：读本地 `AvatarStore.file("me")`，
 * 128 采样解码；「我」页换头像后这里立即跟着变。
 */
@Composable
private fun MeBubbleAvatar() {
    val f = com.aevis.android.core.AvatarStore.file("me")
    val bmp = remember(f.length()) {
        if (f.exists() && f.length() > 64)
            com.aevis.android.data.decodeSampledFile(f.absolutePath, 128, 128)
        else null
    }
    Avatar(bmp, "我")
}
