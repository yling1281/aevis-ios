package com.aevis.android.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.aevis.android.R
import com.aevis.android.core.BackgroundStore
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.LocalPersonaStore
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/**
 * 聊天页（2026-11-29 第 5 版：按 iOS `ChatView.swift` 重做）。
 *
 * 这一版不是调色，是整页重做：
 * - 顶部栏：iOS inline 样式（返回 / 三点在左，标题居中，状态小字）。
 * - 消息：连续圆角玻璃气泡、双方头像按设置显示、字体/括号变浅按角色设置生效。
 * - 滚动：只有贴底时才跟随新消息，翻历史时不拽回；保留"加载更早"横幅。
 * - 底部：悬浮胶囊输入栏（22 连续圆角、白 0.72）、猫咪标记、麦克风=语音输入、
 *   加号=表情包半窗；不再是贴边的工具栏。
 * - 菜单：三点改成半窗，跟 iOS `ConvMenuSheet` 一致。
 *
 * 发送链路（Api.chat / 拆条 / 人设 system prompt）保持不动，只换皮和交互壳。
 */

internal fun chatAnnotated(
    text: String,
    normal: Color,
    dim: Color,
    visibleLen: Int = -1,
    dimEnabled: Boolean = true
): AnnotatedString {
    val limit = if (visibleLen >= 0) minOf(visibleLen, text.length) else text.length
    return buildAnnotatedString {
        var depth = 0
        for (i in 0 until limit) {
            val c = text[i]
            when (c) {
                '（', '(', '【', '[' -> {
                    depth++
                    withStyle(SpanStyle(color = if (dimEnabled) dim else normal)) { append(c) }
                }
                '）', ')', '】', ']' -> {
                    withStyle(SpanStyle(color = if (dimEnabled) dim else normal)) { append(c) }
                    if (depth > 0) depth--
                }
                else -> {
                    val useDim = dimEnabled && depth > 0
                    withStyle(SpanStyle(color = if (useDim) dim else normal)) { append(c) }
                }
            }
        }
    }
}

internal fun loadMemes(ctx: android.content.Context): List<String> = emptyList()
internal fun appendMemes(list: List<String>): String = ""
internal fun statusOf(pid: Long, kind: Int): String = ""

@OptIn(ExperimentalMaterial3Api::class)
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
    val charName = persona?.name.orEmpty()
    val charAvatar = persona?.avatar.orEmpty()

    var msgs by remember(pid) { mutableStateOf<List<Api.Msg>>(emptyList()) }
    var input by remember(pid) { mutableStateOf("") }
    var sending by remember(pid) { mutableStateOf(false) }
    var err by remember(pid) { mutableStateOf("") }
    var loaded by remember(pid) { mutableStateOf(false) }
    var scrollTick by remember(pid) { mutableIntStateOf(0) }
    var moreOpen by remember(pid) { mutableStateOf(false) }
    var stickerOpen by remember(pid) { mutableStateOf(false) }
    var packs by remember(pid) { mutableStateOf<List<Api.EmojiPack>>(emptyList()) }
    var speechHint by remember(pid) { mutableStateOf("") }
    var listening by remember(pid) { mutableStateOf(false) }

    // 角色级外观设置：uiVersion 变了就重组，设置页改完返回立刻生效。
    val uiVer = ChatPrefs.uiVersion
    val fontSp = remember(pid, uiVer) { ChatPrefs.msgFontSpOf(pid) }
    val lineSp = remember(pid, uiVer) { ChatPrefs.msgLineSpOf(pid) }
    val annotDim = remember(pid, uiVer) { ChatPrefs.annotDimOf(pid) }
    val avatarMode = remember(pid, uiVer) { ChatPrefs.avatarModeOf(pid) }
    val enterSend = remember(pid, uiVer) { ChatPrefs.enterSendOf(pid) }
    val showStatus = remember(pid, uiVer) { ChatPrefs.showReplyStatusOf(pid) }
    val bubbleStyle = ChatPrefs.bubbleStyle.coerceIn(0, 2)
    val avatarSize = ChatPrefs.avatarSize.dp.coerceIn(28.dp, 48.dp)
    val bubbleGap = ChatPrefs.gap.dp
    val widthPct = ChatPrefs.bubbleWidthPct / 100f

    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    val ink = if (dark) Color(0xFFF2F1EC) else Color(0xFF1C2231)
    val dimInk = ink.copy(alpha = 0.55f)
    val accent = if (dark) V2.accentDark else V2.accent
    val glassFill = if (dark) Color(0xFF232630).copy(alpha = 0.72f) else Color.White.copy(alpha = 0.72f)
    val veil = if (dark) Color.Black.copy(alpha = 0.28f) else Color.White.copy(alpha = 0.32f)

    // 气泡：iOS 浅色双方都是白玻璃；深色才分深靛蓝 / 深灰。用户自定义色优先。
    fun bubbleFill(mine: Boolean): Color {
        val custom = if (mine) ChatPrefs.mineBubble else ChatPrefs.aiBubble
        if (mine && custom != 0xFF9B8AF0.toInt()) return Color(custom)
        if (!mine && custom != 0) return Color(custom)
        return when {
            mine && dark -> Color(0xFF2E3A57).copy(alpha = 0.68f)
            mine -> Color.White.copy(alpha = 0.70f)
            dark -> Color(0xFF232630).copy(alpha = 0.62f)
            else -> Color.White.copy(alpha = 0.70f)
        }
    }
    val bubbleText = if (dark) Color(0xFFF2F1EC) else Color(0xFF1C2231)

    // 语音输入（Android 侧对标 iOS SpeechInput：结果写进输入框，不自动发送）。
    val speech = remember {
        AndroidSpeech(ctx, onText = { input = it }, onState = { active, hint ->
            listening = active
            speechHint = hint
        })
    }
    val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) speech.start(input) else speechHint = "未授权麦克风，无法语音输入"
    }
    DisposableEffect(Unit) { onDispose { speech.destroy() } }

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
    // 分页渲染：数据层仍全量，只控制画多少条（长会话不卡）。
    var shown by remember(pid) { mutableIntStateOf(80) }
    val render = remember(msgs, shown) {
        if (msgs.size <= shown) msgs else msgs.takeLast(shown)
    }
    var lastAuto by remember(pid) { mutableIntStateOf(-1) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex }.collect { idx ->
            if (idx <= 2 && msgs.size > shown && lastAuto != shown) {
                lastAuto = shown
                shown = minOf(shown + 200, msgs.size)
            }
        }
    }

    // 微信式贴底跟随：用户上翻看历史时不拽回底部。
    // 2026-11-29 修复"默认不在最底下"：空列表/首次布局时 layoutInfo 的
    // lastOrNull() 为 null、totalItemsCount 为 0，会被误判成"不在底"→ stickBottom=false，
    // 后面消息加载完就不跟了。改成：列表还没内容时不改状态，保持初始 true。
    var stickBottom by remember(pid) { mutableStateOf(true) }
    var didInitialScroll by remember(pid) { mutableStateOf(false) }
    LaunchedEffect(listState) {
        snapshotFlow {
            val li = listState.layoutInfo
            if (li.totalItemsCount == 0 || li.visibleItemsInfo.isEmpty()) true
            else li.visibleItemsInfo.lastOrNull()?.index == li.totalItemsCount - 1
        }.collect { stickBottom = it }
    }
    LaunchedEffect(loaded, render.size, scrollTick, stickBottom) {
        if (loaded && render.isNotEmpty() && stickBottom) {
            val extra = if (msgs.size > shown) 1 else 0
            val target = (render.size - 1 + extra).coerceAtLeast(0)
            // 首次进入瞬间贴底（不让用户在眼前滚一长段）；之后新消息柔滑跟上。
            if (!didInitialScroll) {
                runCatching { listState.scrollToItem(target) }
                didInitialScroll = true
            } else {
                runCatching { listState.animateScrollToItem(target) }
            }
        }
    }

    fun pushOut(text: String) {
        val after = msgs + Api.Msg("assistant", text)
        msgs = after
        Api.saveConv(pid, after)
        scrollTick++
    }

    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val path = withContext(Dispatchers.IO) { runCatching { Api.uploadImage(ctx, uri) }.getOrNull() }
            if (path.isNullOrBlank()) {
                err = "图片上传失败"
            } else {
                val after = msgs + Api.Msg("user", "[图片]", img = path)
                msgs = after
                Api.saveConv(pid, after)
                stickBottom = true
                scrollTick++
            }
        }
    }

    fun sendText(raw: String) {
        val text = raw.trim()
        if (text.isEmpty() || sending) return
        input = ""
        err = ""
        focus.clearFocus()
        stickBottom = true
        val withUser = msgs + Api.Msg("user", text)
        msgs = withUser
        Api.saveConv(pid, withUser)
        scrollTick++
        sending = true
        scope.launch {
            val isOs = ChatPrefs.chatMode == 1
            val sys = buildString {
                if (charName.isNotBlank()) appendLine("你叫$charName。")
                val pText = persona?.persona.orEmpty()
                if (pText.isNotBlank()) appendLine("你的人设：" + pText.take(2000))
                if (isOs) {
                    appendLine("【内心 OS 模式】这一轮只写一段内心独白，200-600 字；可以用括号写动作神态；不分条、不加小标题。")
                } else {
                    appendLine("【微信聊天模式】每条不超过 15 字；一次发 3-5 条，情绪起来 6-8 条；每条之间用换行分开；不要用括号写动作。")
                }
                appendLine("【状态标记】回复最后单独一行输出 [[状态]]两到六个字，用户看不到。")
            }
            val reply = withContext(Dispatchers.IO) { Api.chat("deepseek-flash", withUser.takeLast(20), sys) }
            if (reply.isNullOrBlank()) {
                err = Api.lastChatError.ifBlank { "发送失败，可点右侧重发" }
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

    fun send() { sendText(input.trim()) }

    fun resend() {
        val idx = msgs.indexOfLast { it.role == "user" }
        if (idx < 0) return
        val text = msgs[idx].content
        msgs = msgs.take(idx)
        Api.saveConv(pid, msgs)
        sendText(text)
    }

    fun sendSticker(url: String) {
        val after = msgs + Api.Msg("user", "[表情]", img = url)
        msgs = after
        Api.saveConv(pid, after)
        stickBottom = true
        scrollTick++
    }

    LaunchedEffect(stickerOpen) {
        if (stickerOpen && packs.isEmpty()) {
            packs = withContext(Dispatchers.IO) { runCatching { Api.emojiPacks() }.getOrDefault(emptyList()) }
        }
    }

    val screenW = LocalConfiguration.current.screenWidthDp.dp
    val maxBubble = (screenW * widthPct - avatarSize - bubbleGap - 16.dp).coerceAtLeast(160.dp)
    val bubbleShape = when (bubbleStyle) {
        1 -> RoundedCornerShape(8.dp)
        2 -> RoundedCornerShape(3.dp)
        else -> squircle(V2.bubbleRadius)
    }

    Box(Modifier.fillMaxSize()) {
        BackgroundStore.renderBg(
            ctx, ChatPrefs.bgKind, ChatPrefs.bgPreset,
            ChatPrefs.bgBlur, ChatPrefs.bgDim, ChatPrefs.bgVersion
        )
        // iOS veilChat：轻白膜/黑膜压住花哨背景，文字靠气泡承载。
        Box(Modifier.fillMaxSize().background(veil))

        Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            // ── 顶部栏（2026-11-29：三点 + 日记一并挪到右上角） ─────────────
            // 左边只留返回；标题居中；日记 + 三点并排在右，跟 iOS 右上角口径一致。
            Box(Modifier.fillMaxWidth().height(56.dp)) {
                Box(Modifier.align(Alignment.CenterStart).padding(start = 8.dp)) {
                    CircleIcon(R.drawable.ic_chevron, accent, rotate = 180f, onClick = onBack)
                }
                Column(
                    Modifier.align(Alignment.Center).padding(horizontal = 100.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        charName.ifBlank { "聊天" }, fontSize = V2.title,
                        fontWeight = FontWeight.SemiBold, color = ink, maxLines = 1
                    )
                    if (showStatus) {
                        Text(
                            if (sending) "正在输入…" else "在线 · 上下文 ${ChatPrefs.ctxWindow} 条",
                            fontSize = V2.micro, color = if (sending) accent else dimInk, maxLines = 1
                        )
                    }
                }
                Row(
                    Modifier.align(Alignment.CenterEnd).padding(end = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    CircleIcon(R.drawable.ic_diary, accent) { onOpenDiary(pid) }
                    Spacer(Modifier.width(4.dp))
                    CircleIcon(R.drawable.ic_menu, accent) { moreOpen = true }
                }
            }

            AnimatedVisibility(
                visible = err.isNotBlank(),
                enter = fadeIn(tween(180)) + expandVertically(animationSpec = tween(200, easing = FastOutSlowInEasing)),
                exit = fadeOut(tween(140)) + shrinkVertically(animationSpec = tween(160, easing = FastOutSlowInEasing))
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(err, fontSize = V2.tiny, color = V2.alert, modifier = Modifier.weight(1f))
                    Text(
                        "重发", fontSize = V2.tiny, color = accent,
                        modifier = Modifier.tapable { resend() }
                    )
                }
            }

            // ── 消息列表 ──────────────────────────────────────────────────
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                if (msgs.size > shown) {
                    item(key = "loadMore") {
                        Row(
                            Modifier.fillMaxWidth().clip(squircle(14.dp))
                                .background(glassFill)
                                .tapable {
                                    val added = minOf(200, msgs.size - shown)
                                    val keepIdx = listState.firstVisibleItemIndex
                                    val keepOff = listState.firstVisibleItemScrollOffset
                                    shown += added
                                    stickBottom = false
                                    scope.launch {
                                        runCatching { listState.scrollToItem(keepIdx + added + 1, keepOff) }
                                    }
                                }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("已显示最近 $shown 条 / 共 ${msgs.size} 条", fontSize = V2.tiny, color = dimInk)
                            Spacer(Modifier.weight(1f))
                            Text("加载更早", fontSize = V2.tiny, color = accent)
                        }
                    }
                }
                itemsIndexed(render) { _, m ->
                    val mine = m.role == "user"
                    val showAvatar = when {
                        mine -> avatarMode == 0
                        else -> avatarMode != 2
                    }
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
                        verticalAlignment = Alignment.Top
                    ) {
                        if (!mine && showAvatar) {
                            Avatar(avatarBmp, charName, avatarSize)
                            Spacer(Modifier.width(bubbleGap))
                        }
                        if (mine) Spacer(Modifier.weight(1f, fill = false).widthIn(min = 24.dp))
                        Box(
                            Modifier.widthIn(max = maxBubble)
                                .clip(bubbleShape)
                                .background(bubbleFill(mine))
                                .padding(horizontal = 12.dp, vertical = 9.dp)
                        ) {
                            if (m.img.isNotBlank()) {
                                EmojiImage(
                                    url = m.img,
                                    modifier = Modifier.size(120.dp),
                                    radius = V2.bubbleRadius
                                )
                            } else {
                                Text(
                                    text = chatAnnotated(m.content, bubbleText, dimInk, dimEnabled = annotDim),
                                    fontSize = fontSp.sp, lineHeight = lineSp.sp
                                )
                            }
                        }
                        if (mine) {
                            Spacer(Modifier.width(bubbleGap))
                            if (showAvatar) MeBubbleAvatar(avatarSize)
                        } else {
                            Spacer(Modifier.weight(1f, fill = false).widthIn(min = 24.dp))
                        }
                    }
                }
                if (sending) {
                    item(key = "typing") {
                        Text(
                            "正在输入…", fontSize = V2.tiny, color = dimInk,
                            modifier = Modifier.padding(start = 14.dp)
                        )
                    }
                }
            }

            // ── 底部悬浮输入栏 ────────────────────────────────────────────
            AnimatedVisibility(
                visible = speechHint.isNotBlank(),
                enter = fadeIn(tween(180)) + expandVertically(animationSpec = tween(200, easing = FastOutSlowInEasing)),
                exit = fadeOut(tween(140)) + shrinkVertically(animationSpec = tween(160, easing = FastOutSlowInEasing))
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 3.dp)
                        .clip(squircle(12.dp)).background(glassFill)
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        speechHint, fontSize = V2.tiny,
                        color = if (listening) accent else V2.alert,
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            Column(
                Modifier.fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp)
                    .navigationBarsPadding()
            ) {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 48.dp)
                        .clip(squircle(22.dp)).background(glassFill)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        Modifier.size(26.dp), contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_cat_line), contentDescription = null,
                            tint = accent, modifier = Modifier.size(22.dp)
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Box(Modifier.weight(1f).heightIn(min = 30.dp), contentAlignment = Alignment.CenterStart) {
                        if (input.isEmpty()) {
                            Text(if (listening) "正在听你说…" else "发消息", fontSize = V2.body, color = dimInk.copy(alpha = 0.7f))
                        }
                        BasicTextField(
                            value = input,
                            onValueChange = { input = it },
                            enabled = !listening,
                            singleLine = enterSend,
                            maxLines = if (enterSend) 1 else 4,
                            textStyle = TextStyle(fontSize = V2.body, color = ink),
                            keyboardActions = KeyboardActions(onDone = { if (enterSend) send() }),
                            keyboardOptions = KeyboardOptions(
                                imeAction = if (enterSend) ImeAction.Done else ImeAction.Default
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                    if (input.trim().isNotBlank()) {
                        InputCircle(accent) { send() }
                    } else {
                        InputIcon(R.drawable.ic_row_mic, accent) {
                            if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO)
                                == PackageManager.PERMISSION_GRANTED
                            ) speech.start(input) else micPermission.launch(Manifest.permission.RECORD_AUDIO)
                        }
                        Spacer(Modifier.width(4.dp))
                        PlusKey(accent) { stickerOpen = true }
                    }
                }
            }
        }
    }

    // ── 三点半窗（iOS ConvMenuSheet） ─────────────────────────────────────
    if (moreOpen) {
        ModalBottomSheet(
            onDismissRequest = { moreOpen = false },
            containerColor = frostedSheetColor()
        ) {
            Column(Modifier.fillMaxWidth().padding(bottom = 18.dp)) {
                Text(
                    charName.ifBlank { "聊天" }, fontSize = V2.title,
                    fontWeight = FontWeight.SemiBold, color = ink,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 10.dp)
                )
                ChatMenuRow("角色设置") { moreOpen = false; onOpenRoleSet(pid) }
                ChatMenuRow("编辑人设") { moreOpen = false; onOpenPersona(pid) }
                ChatMenuRow("模型设置") { moreOpen = false; onOpenModels(pid) }
                ChatMenuRow("聊天外观") { moreOpen = false; onOpenLook(pid) }
                ChatMenuRow("聊天日记") { moreOpen = false; onOpenDiary(pid) }
                ChatMenuRow("清空本会话", enabled = msgs.isNotEmpty(), danger = true) {
                    moreOpen = false
                    msgs = emptyList()
                    runCatching { Api.saveConv(pid, emptyList()) }
                }
                ChatMenuRow("取消") { moreOpen = false }
            }
        }
    }

    // ── 表情包半窗（iOS stickerSheet） ────────────────────────────────────
    if (stickerOpen) {
        ModalBottomSheet(
            onDismissRequest = { stickerOpen = false },
            containerColor = frostedSheetColor()
        ) {
            Column(Modifier.fillMaxWidth().fillMaxHeight(0.78f)) {
                Row(Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 8.dp)) {
                    Text("表情包", fontSize = V2.title, fontWeight = FontWeight.SemiBold, color = ink)
                    Spacer(Modifier.weight(1f))
                    Text("完成", fontSize = V2.body, color = accent, modifier = Modifier.tapable { stickerOpen = false })
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    SheetAction("相册") { stickerOpen = false; pickImage.launch("image/*") }
                    SheetAction("背景") { stickerOpen = false; onOpenLook(pid) }
                    SheetAction("外观") { stickerOpen = false; onOpenLook(pid) }
                }
                Box(Modifier.weight(1f)) {
                    if (packs.isEmpty()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Text("还没有下载的表情包", fontSize = V2.body, color = dimInk)
                        }
                    } else {
                        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                            EmojiGallery(packs) { url ->
                                sendSticker(url)
                                stickerOpen = false
                            }
                        }
                    }
                }
            }
        }
    }
}

/** iOS 头像：白环 + 深墨靛蓝渐变占位 + 首字；有本地图直接用图。 */
@Composable
private fun Avatar(bmp: android.graphics.Bitmap?, name: String, size: Dp) {
    Box(
        Modifier.size(size + 2.dp).clip(CircleShape)
            .background(Color.White.copy(alpha = 0.85f))
            .border(1.dp, Color.White.copy(alpha = 0.85f), CircleShape)
            .padding(1.dp),
        contentAlignment = Alignment.Center
    ) {
        Box(
            Modifier.fillMaxSize().clip(CircleShape)
                .background(Brush.linearGradient(listOf(V2.accentLift, V2.accentDeep))),
            contentAlignment = Alignment.Center
        ) {
            if (bmp != null) {
                Image(
                    bitmap = bmp.asImageBitmap(), contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().clip(CircleShape)
                )
            } else {
                Text(
                    name.take(1).ifBlank { "?" }, fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold, color = Color.White
                )
            }
        }
    }
}

@Composable
private fun MeBubbleAvatar(size: Dp) {
    val f = com.aevis.android.core.AvatarStore.file("me")
    val bmp = remember(f.length()) {
        if (f.exists() && f.length() > 64)
            com.aevis.android.data.decodeSampledFile(f.absolutePath, 128, 128) else null
    }
    Avatar(bmp, "我", size)
}

@Composable
private fun CircleIcon(
    @androidx.annotation.DrawableRes icon: Int,
    tint: Color,
    rotate: Float = 0f,
    onClick: () -> Unit
) {
    Box(
        Modifier.size(36.dp).clip(CircleShape)
            .background(Color.White.copy(alpha = 0.62f))
            .tapable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            painterResource(icon), contentDescription = null, tint = tint,
            modifier = Modifier.size(19.dp).graphicsLayer { rotationZ = rotate }
        )
    }
}

@Composable
private fun InputIcon(@androidx.annotation.DrawableRes icon: Int, tint: Color, onClick: () -> Unit) {
    Box(Modifier.size(34.dp).tapable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun InputCircle(tint: Color, onClick: () -> Unit) {
    val scale by animateFloatAsState(targetValue = 1f, animationSpec = spring(), label = "sendScale")
    Box(
        Modifier.size(30.dp).graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(CircleShape).background(tint).tapable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            painterResource(R.drawable.ic_send), contentDescription = "发送",
            tint = Color.White, modifier = Modifier.size(16.dp)
        )
    }
}

@Composable
private fun PlusKey(tint: Color, onClick: () -> Unit) {
    val rot by animateFloatAsState(targetValue = 0f, animationSpec = spring(), label = "plus")
    Box(
        Modifier.size(30.dp).clip(CircleShape).background(tint).tapable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            "＋", fontSize = 18.sp, color = Color.White,
            modifier = Modifier.graphicsLayer { rotationZ = rot }
        )
    }
}

@Composable
private fun SheetAction(label: String, onClick: () -> Unit) {
    Column(
        Modifier.clip(squircle(14.dp)).background(Color.White.copy(alpha = 0.65f))
            .tapable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(label, fontSize = V2.tiny, color = V2.accent)
    }
}

@Composable
private fun ChatMenuRow(
    text: String,
    enabled: Boolean = true,
    danger: Boolean = false,
    onClick: () -> Unit
) {
    Box(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).tapable { if (enabled) onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        Text(
            text, fontSize = V2.body,
            color = when {
                danger -> V2.alert
                !enabled -> dimColor()
                else -> inkColor()
            }
        )
    }
}

@Composable
private fun inkColor(): Color =
    if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) Color(0xFFF2F1EC) else Color(0xFF1C2231)

@Composable
private fun dimColor(): Color = inkColor().copy(alpha = 0.4f)

/** Android 语音输入：结果只写输入框，不自动发送（与 iOS SpeechInput 同口径）。 */
private class AndroidSpeech(
    ctx: Context,
    private val onText: (String) -> Unit,
    private val onState: (Boolean, String) -> Unit
) : RecognitionListener {
    private val recognizer: SpeechRecognizer? = runCatching { SpeechRecognizer.createSpeechRecognizer(ctx) }.getOrNull()
    private var base = ""

    fun start(current: String) {
        val r = recognizer
        if (r == null) { onState(false, "语音识别不可用"); return }
        base = current
        r.setRecognitionListener(this)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.CHINA.toString())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PROMPT, "正在听你说…")
        }
        onState(true, "正在听你说，说完自动结束")
        runCatching { r.startListening(intent) }.onFailure { onState(false, "语音识别启动失败") }
    }

    fun destroy() { runCatching { recognizer?.destroy() } }

    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() { onState(false, "") }
    override fun onError(error: Int) { onState(false, "语音识别失败，请重试") }
    override fun onEvent(eventType: Int, params: Bundle?) {}

    override fun onResults(results: Bundle?) {
        val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
        if (text.isNotBlank()) onText(base + text)
        onState(false, "")
    }

    override fun onPartialResults(partialResults: Bundle?) {
        val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
        if (text.isNotBlank()) onText(base + text)
    }
}
