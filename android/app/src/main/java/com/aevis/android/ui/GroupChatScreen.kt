package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.BackgroundStore
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.GroupStore
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.ModelPrefs
import com.aevis.android.core.PersonaLib
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 群聊（2026-11-16）。
 *
 * 用户：「我要能拉一个群，几个人设一起在里面说话」。
 *
 * 和单聊的区别只有三处，其它全部复用（气泡/圆角/字号/背景都读 `ChatPrefs`，
 * 拆句用同一个 `splitReply`）：
 *   1. 一句话可能有好几个人接 —— 随机挑 1~3 个，逐个串行请求，中间留停顿；
 *   2. AI 消息要标**是谁说的**（`Api.Msg.who` + 气泡上方的名字）；
 *   3. 系统提示词里要交代「你在群里、还有谁、别把别人的话说完」。
 *
 * 会话 id 就是群 id（`Api.loadConv(gid)`），所以不需要另建消息表。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun GroupChatScreen(
    gid: String,
    onBack: () -> Unit,
    onAddMember: () -> Unit,
    onOpenPersona: (String) -> Unit,
    // 群资料页（2026-11-16，general-purpose-1 那套页面）：默认空实现，不传也不会崩
    onOpenProfile: (String) -> Unit = {}
) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val ink = MaterialTheme.colorScheme.onSurface
    val cfg = LocalConfiguration.current

    // —— 外观参数：跟单聊同一套（用户改了设置，两边观感要一致）——
    val avatarSize = ChatPrefs.avatarSize.dp
    val bubbleRadius = when (ChatPrefs.bubbleStyle) {
        0 -> 18.dp
        1 -> 8.dp
        else -> 5.dp
    }
    val gap = ChatPrefs.gap.dp
    // 126：跟单聊同一套「消息大小」（13.5 / 15 / 17sp，行高 1.45 倍）
    val msgFont = ChatPrefs.msgFontSp().sp
    val msgLine = ChatPrefs.msgLineSp().sp
    val maxBubbleW = (cfg.screenWidthDp * (ChatPrefs.bubbleWidthPct / 100f)).dp

    // 气泡配色：跟单聊完全一致 —— 群里"我"的气泡也只有一种颜色
    val mineBgBase = BubblePalette.mineColor(ChatPrefs.mineBubble)
    val aiPref = ChatPrefs.aiBubble
    val darkTheme = ink.luminance() > 0.5f
    val aiBgBase = if (aiPref == 0) null else BubblePalette.aiColor(aiPref, darkTheme)

    var group by remember(gid) { mutableStateOf(GroupStore.find(gid)) }
    var persons by remember { mutableStateOf<List<Api.Persona>>(emptyList()) }
    var msgs by remember(gid) { mutableStateOf<List<Api.Msg>>(emptyList()) }
    var input by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var err by remember { mutableStateOf("") }
    var menuOpen by remember { mutableStateOf(false) }
    var showMembers by remember { mutableStateOf(false) }
    var confirmDissolve by remember { mutableStateOf(false) }
    // 表情面板（2026-11-16）
    var emojiSheet by remember { mutableStateOf(false) }
    // 改群名（2026-11-16）：顶栏名字本身和 ⋯ 菜单第一项都开同一个弹窗
    var renameOpen by remember { mutableStateOf(false) }

    val model = remember { ModelPrefs.current() }
    val gname = group?.name.orEmpty().ifBlank { tr("群聊") }
    // 热梗库全文（2026-11-16）：跟单聊同一份，整页读一次盘。
    // 群里更该有点梗感 —— 几个人设互相接梗比干巴巴聊天真实得多。
    val memes = remember { loadMemes(ctx) }

    // 当前状态（2026-11-16）：跟单聊同一套，每 40–90 秒换一次说法
    var statusVer by remember { mutableIntStateOf(0) }
    var statusTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(gid) {
        while (true) {
            kotlinx.coroutines.delay(kotlin.random.Random.nextLong(40_000L, 90_000L))
            statusTick++
        }
    }
    // 2026-11-16：状态由模型给，**按发言人分别存**（`status_<发言人 pid>`）。
    // 顶栏显示"最近一次开口的那个人的状态"，没有就「在线」。
    // 顶栏三态（2026-11-16，91）：
    //   1) 正在发送 → 「{谁} 正在输入中」（谁 = 本轮还没落盘的那个发言人）
    //   2) 回完 → 那个发言人 `[[状态]]` 存下的状态
    //   3) 从没有过状态 → 「在线」
    // 注意：文案只能来自模型标记，前端**不编状态词**。
    // 发送中要说"谁在输入"：从 persons 里按发言人 id 找名字（ms 是 send() 里的局部变量，这里用 persons）
    val status = remember(statusVer, statusTick, msgs.size, sending, persons.size) {
        if (sending) {
            val who = msgs.lastOrNull { it.role != "user" }?.who.orEmpty()
            val nm = persons.firstOrNull { it.id == who }?.name.orEmpty()
            if (nm.isBlank()) tr("正在输入中") else tr("%s 正在输入中", nm)
        } else {
            val lastAiWho = msgs.lastOrNull { it.role != "user" }?.who.orEmpty()
            com.aevis.android.core.StatusStore.get(lastAiWho)?.first ?: tr("在线")
        }
    }

    // 成员按 `memberIds` 的顺序排；找不到的人设直接跳过
    // （用户可能把那个本地角色删了，不能因此让整个群打不开）
    val members = remember(persons, group) {
        group?.memberIds.orEmpty().mapNotNull { id -> persons.firstOrNull { it.id == id } }
    }

    LaunchedEffect(gid) {
        persons = withContext(Dispatchers.IO) {
            runCatching { PersonaLib.localList() }.getOrElse { emptyList() }
        }
        msgs = withContext(Dispatchers.IO) { Api.loadConv(gid) }
    }

    val listState = rememberLazyListState()
    var firstScrollDone by remember(gid) { mutableStateOf(false) }
    LaunchedEffect(msgs.size, sending, gid) {
        if (msgs.isEmpty() && !sending) return@LaunchedEffect
        val target = (msgs.size + if (sending) 1 else 0).coerceAtLeast(0)
        runCatching {
            if (!firstScrollDone) {
                listState.scrollToItem(target)
                firstScrollDone = true
            } else {
                listState.animateScrollToItem(target)
            }
        }
    }

    fun send() {
        val text = input.trim()
        if (text.isEmpty() || sending) return
        input = ""
        err = ""
        val next = msgs + Api.Msg("user", text)
        msgs = next
        Api.saveConv(gid, next)
        sending = true
        scope.launch {
            val g = GroupStore.find(gid) ?: group
            val title = g?.name.orEmpty().ifBlank { tr("群聊") }
            val rp = persons
            val ms = g?.memberIds.orEmpty()
                .mapNotNull { id -> rp.firstOrNull { it.id == id } }

            // 谁来接话：一个人就他，多个人随机挑 1~3 个（顺序也打乱），
            // 否则每次都是同一个人先开口，看着像群里只有一个活人。
            val speakers = when {
                ms.isEmpty() -> emptyList()
                ms.size == 1 -> ms
                else -> ms.shuffled().take((1..minOf(3, ms.size)).random())
            }
            if (speakers.isEmpty()) {
                sending = false
                err = tr("这个群里还没有人")
                return@launch
            }

            for ((idx, sp) in speakers.withIndex()) {
                // 人和人之间停一下 —— 三条一起冒出来不像聊天
                if (idx > 0) delay((700L..1100L).random())

                val persona = PersonaLib.personaText(sp.id, sp.tagline)
                val style = PersonaLib.styleText(sp.id)
                val others = ms.filter { it.id != sp.id }.map { it.name }
                val sys = buildString {
                    append("你在一个叫「$title」的群里。")
                    if (others.isNotEmpty()) append("群里还有：${others.joinToString("、")}。")
                    append("\n你叫${sp.name}。")
                    if (persona.isNotBlank()) append("你的人设：$persona。")
                    if (style.isNotBlank()) append("【说话风格】$style")
                    // 热梗库全文：跟单聊一样放**靠前**（模型对超长 system 末尾注意力很弱）
                    appendMemes(memes)
                    append("\n【群聊规则】\n")
                    append("- 你只是在群里接一句话，不要把别人的话替他们说完；\n")
                    append("- 最多 2 行，每行不超过 30 字，用换行分开；\n")
                    append("- 像微信群那样说话，不要写小作文、不要用序号和 markdown、不要加括号描写动作；\n")
                    append("- 别人正在聊的话题你可以插一句，也可以只回半句，不要每句都抢。")
                    // 硬性禁止字段清单（2026-11-16，跟单聊同一段，放在拼串最末尾）
                    append("\n【硬性禁止】\n")
                    append("不要在回复里输出任何方括号/书名号包裹的字段清单或卡片，包括但不限于：\n")
                    append("【物品：…】、[物品：…]、状态/颜色/气味/大小/样式 这类「键：值」罗列、\n")
                    append("以及用代码围栏包起来的结构化数据。\n")
                    append("物品、身体状态、环境，只能用动作和感官描写自然写进括号里，或直接写在对话里。\n")
                    append("违反这条视为格式错误。")
                    // 状态标记（2026-11-16）：群里按发言人分别存，所以每个人的 sys 都要加
                    append("\n【状态标记】每次回复的最后单独一行，输出：\n")
                    append("[[状态]]这里写你此刻的心情或动作（2–6 个字，不要标点，不要解释，不要换行）\n")
                    append("这一行是给系统读的，用户看不到，不要在任何别的地方提到它。")
                }
                val nameOf = { who: String -> ms.firstOrNull { it.id == who }?.name ?: "" }
                val history = groupHistory(msgs, sp.id, nameOf)

                val reply = withContext(Dispatchers.IO) { Api.chat(model, history, sys) }
                if (reply == null) {
                    sending = false
                    err = Api.lastChatError.ifBlank { tr("发送失败") }
                    return@launch
                }
                // 状态标记：摘掉那一行（用户看不到），按**发言人 pid** 分别存
                val (cleanReply, newStatus) = com.aevis.android.core.splitStatusMarker(reply)
                if (newStatus.isNotBlank()) {
                    com.aevis.android.core.StatusStore.put(sp.id, newStatus)
                    statusVer++
                }
                // 一个人说的话也拆成一到多条 —— 跟单聊一个观感
                splitReply(
                    cleanReply,
                    stripTrailing = com.aevis.android.core.ChatPrefs.stripSplitPunct
                ).forEachIndexed { k, part ->
                    if (k > 0) delay((500L..800L).random())
                    val done = msgs + Api.Msg("assistant", part, sp.id)
                    msgs = done
                    Api.saveConv(gid, done)
                }
            }
            sending = false
        }
    }

    /**
     * 发一张表情包（2026-11-16）。
     *
     * 群里更简单：表情是「我」发的（`role = "user"`、`who` 留空），
     * **不触发任何人回复** —— 真人往群里甩个表情包，也不是每次都有人接。
     */
    fun sendEmoji(url: String) {
        if (url.isEmpty()) return
        emojiSheet = false
        val next = msgs + Api.Msg(role = "user", content = "", img = url)
        msgs = next
        Api.saveConv(gid, next)
    }

    BackHandler { onBack() }

    Box(Modifier.fillMaxSize()) {
        // 背景跟单聊同一套（用户可能设了图/渐变，群里也该是那张）
        BackgroundStore.renderBg(
            ctx = ctx,
            kind = ChatPrefs.bgKind,
            preset = ChatPrefs.bgPreset,
            blur = ChatPrefs.bgBlur,
            dim = ChatPrefs.bgDim,
            ver = 0,
            modifier = Modifier.fillMaxSize()
        )

        Column(
            Modifier.fillMaxSize()
                .background(Color.Transparent)
                .statusBarsPadding()
                .imePadding()
        ) {
            // ---------- 顶栏 ----------
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 8.dp),
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
                Spacer(Modifier.width(4.dp))

                // 群名 + 人数。
                // 点名字 = 改群名（2026-11-16）：用户的直觉就是"这名字能点"，
                // 逼他先去 ⋯ 菜单里找「修改群名」是反人类的。看成员走右边的头像条。
                Column(
                    Modifier.weight(1f)
                        .clip(squircle(10.dp))
                        .tapable { renameOpen = true }
                        .padding(horizontal = 6.dp, vertical = 3.dp)
                ) {
                    Text(
                        gname, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        // 「N 人 · 当前状态」（2026-11-16）：状态跟单聊同一套口径，
                        // 群聊顶栏也得"会动"，而且不能取任何提示词字段。
                        tr("%d 人 · %s", members.size, status), fontSize = 10.5.sp,
                        color = ink.copy(alpha = 0.4f), maxLines = 1
                    )
                }

                // 群头像（2026-11-16）：设过就显示一张群头像，点它进群资料；
                // 没设过还是原来的成员头像条（最多露 5 个，多的折成 +n）
                if (!group?.avatar.isNullOrEmpty()) {
                    Box(Modifier.tapable { onOpenProfile(gid) }) {
                        Avatar(group!!.avatar, group?.name.orEmpty(), 30.dp)
                    }
                } else {
                    GroupAvatarStrip(members) { showMembers = true }
                }
                Spacer(Modifier.width(4.dp))

                // ⋯ 菜单（锚点就是按钮自己的 Box）
                Box(Modifier.size(34.dp), contentAlignment = Alignment.Center) {
                    Box(
                        Modifier.fillMaxSize().clip(squircle(10.dp))
                            .tapable { menuOpen = true },
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "⋯", fontSize = 20.sp, color = ink.copy(alpha = 0.6f),
                            fontWeight = FontWeight.Bold
                        )
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(tr("修改群名")) },
                            onClick = { menuOpen = false; renameOpen = true }
                        )
                        DropdownMenuItem(
                            text = { Text(tr("群资料（头像 / 群名）")) },
                            onClick = { menuOpen = false; onOpenProfile(gid) }
                        )
                        DropdownMenuItem(
                            text = { Text(tr("群成员")) },
                            onClick = { menuOpen = false; showMembers = true }
                        )
                        DropdownMenuItem(
                            text = { Text(tr("加人")) },
                            onClick = { menuOpen = false; onAddMember() }
                        )
                        DropdownMenuItem(
                            text = { Text(tr("清空这个群聊")) },
                            onClick = {
                                menuOpen = false
                                Api.clearConv(gid)
                                msgs = emptyList()
                            }
                        )
                        HorizontalDivider(color = ink.copy(alpha = 0.06f))
                        DropdownMenuItem(
                            text = { Text(tr("解散群聊"), color = V2.alert) },
                            onClick = { menuOpen = false; confirmDissolve = true }
                        )
                    }
                }
            }

            // ---------- 消息区 ----------
            LazyColumn(
                state = listState,
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(
                    start = 12.dp, top = 10.dp, end = 12.dp,
                    // bottom 多留 6dp：最后一条别贴着输入条那条分割线
                    bottom = 16.dp
                )
            ) {
                if (msgs.isEmpty()) {
                    item {
                        Box(
                            Modifier.fillMaxWidth().padding(top = 56.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                GroupAvatarStrip(members, size = 52.dp) {}
                                Spacer(Modifier.height(12.dp))
                                Text(
                                    tr("在「%s」里说点什么", gname),
                                    fontSize = 13.sp, color = ink.copy(alpha = 0.42f)
                                )
                            }
                        }
                    }
                }

                items(msgs.size) { i ->
                    val m = msgs[i]
                    val mine = m.role == "user"
                    // 同一个人连续说的，只在第一条露头像和名字
                    val prevSame = i > 0 &&
                        msgs[i - 1].role == m.role && msgs[i - 1].who == m.who
                    val speaker = persons.firstOrNull { it.id == m.who }

                    Row(
                        Modifier.fillMaxWidth()
                            .padding(top = if (prevSame) 3.dp else 10.dp),
                        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
                        verticalAlignment = Alignment.Top
                    ) {
                        // 128：跟单聊同一套「头像显示」（0 双方 / 1 只角色 / 2 都不显示）
                        if (!mine && ChatPrefs.avatarMode != 2) {
                            if (prevSame) Spacer(Modifier.width(avatarSize + gap))
                            else {
                                Avatar(
                                    speaker?.avatar.orEmpty(),
                                    speaker?.name ?: "AI",
                                    avatarSize
                                )
                                Spacer(Modifier.width(gap))
                            }
                        }

                        Column(
                            horizontalAlignment = if (mine) Alignment.End else Alignment.Start
                        ) {
                            // 发言人名字（10.5sp，气泡上方 2dp）—— 群里必须知道是谁在说
                            if (!mine && !prevSame) {
                                Text(
                                    speaker?.name ?: "AI", fontSize = 10.5.sp,
                                    color = ink.copy(alpha = 0.45f), maxLines = 1,
                                    modifier = Modifier.padding(start = 2.dp)
                                )
                                Spacer(Modifier.height(2.dp))
                            }
                            Box(
                                Modifier.widthIn(max = maxBubbleW)
                                    .clip(
                                        if (mine) RoundedCornerShape(
                                            bubbleRadius, bubbleRadius, 4.dp, bubbleRadius
                                        ) else RoundedCornerShape(
                                            bubbleRadius, bubbleRadius, bubbleRadius, 4.dp
                                        )
                                    )
                                    .background(
                                        when {
                                            mine -> mineBgBase.copy(alpha = 0.92f)
                                            aiBgBase != null -> aiBgBase
                                            darkTheme -> Color.White.copy(alpha = 0.06f)
                                            else -> Color.White.copy(alpha = 0.78f)
                                        }
                                    )
                                    .border(
                                        0.6.dp,
                                        if (darkTheme) Color.White.copy(alpha = 0.14f)
                                        else Color.Black.copy(alpha = 0.05f),
                                        if (mine) RoundedCornerShape(
                                            bubbleRadius, bubbleRadius, 4.dp, bubbleRadius
                                        ) else RoundedCornerShape(
                                            bubbleRadius, bubbleRadius, bubbleRadius, 4.dp
                                        )
                                    )
                                    .padding(
                                        horizontal = if (m.img.isNotEmpty()) 4.dp else 12.dp,
                                        vertical = if (m.img.isNotEmpty()) 4.dp else 9.dp
                                    )
                            ) {
                                if (m.img.isNotEmpty()) {
                                    // 表情包消息（2026-11-16）：气泡里放图，不放文字
                                    EmojiImage(
                                        url = m.img,
                                        modifier = Modifier.size(120.dp),
                                        radius = 10.dp,
                                        scale = androidx.compose.ui.layout.ContentScale.Fit,
                                        placeholderBg = false,
                                        failText = tr("图片加载失败")
                                    )
                                } else {
                                    val tc = when {
                                        mine -> BubblePalette.textOn(mineBgBase)
                                        aiBgBase != null -> BubblePalette.textOn(aiBgBase)
                                        else -> ink
                                    }
                                    Text(
                                        // 括号内心 OS 浅色（2026-11-16），跟单聊同一套渲染
                                        text = chatAnnotated(
                                            m.content, tc,
                                            if (ChatPrefs.annotDim) tc.copy(alpha = 0.6f) else tc
                                        ),
                                        fontSize = msgFont,
                                        lineHeight = msgLine
                                    )
                                }
                            }
                        }

                        // 128：群聊里自己那条也要头像（只有「双方都显示」这一档挂）
                        if (mine && ChatPrefs.avatarMode == 0) {
                            if (prevSame) Spacer(Modifier.width(avatarSize + gap))
                            else {
                                val me = remember { Api.cachedMe() }
                                Spacer(Modifier.width(gap))
                                Avatar(
                                    me?.avatar.orEmpty(),
                                    me?.nickname?.takeIf { it.isNotBlank() } ?: "我",
                                    avatarSize
                                )
                            }
                        }
                    }
                }

                if (sending) {
                    item {
                        Row(
                            Modifier.fillMaxWidth().padding(top = 10.dp),
                            horizontalArrangement = Arrangement.Start
                        ) {
                            Box(
                                Modifier.size(avatarSize).clip(CircleShape)
                                    .background(ink.copy(alpha = 0.08f))
                            )
                            Spacer(Modifier.width(gap))
                            Box(
                                Modifier.clip(
                                    RoundedCornerShape(
                                        bubbleRadius, bubbleRadius, bubbleRadius, 4.dp
                                    )
                                )
                                    .background(ink.copy(alpha = 0.055f))
                                    .padding(horizontal = 12.dp, vertical = 9.dp)
                            ) {
                                Text(
                                    tr("正在输入…"), fontSize = 14.sp,
                                    color = ink.copy(alpha = 0.4f)
                                )
                            }
                        }
                    }
                }
                item { Spacer(Modifier.height(6.dp)) }
            }

            if (err.isNotEmpty()) {
                Text(
                    err, fontSize = 12.sp, color = V2.alert,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp)
                )
            }

            // ---------- 输入区（跟单聊一样）----------
            // 2026-11-16：输入条不透明（用户要「底栏变白、别透出背景图」），
            // 消息区继续透背景，中间一条 0.5dp 分割线。
            Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)) {
            Box(
                Modifier.fillMaxWidth().height(0.5.dp)
                    .background(ink.copy(alpha = 0.08f))
            )
            Row(
                Modifier.fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                // 表情按钮（2026-11-16）：跟单聊同一个面板，选一张直接进群里
                Box(
                    Modifier.size(40.dp).clip(CircleShape)
                        .background(ink.copy(alpha = 0.05f))
                        .tapable { emojiSheet = true },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        painterResource(R.drawable.ic_row_emoji), null,
                        tint = ink.copy(alpha = 0.6f), modifier = Modifier.size(20.dp)
                    )
                }
                Spacer(Modifier.width(8.dp))
                Box(
                    Modifier.weight(1f)
                        .clip(RoundedCornerShape(20.dp))
                        .background(ink.copy(alpha = 0.05f))
                        .padding(horizontal = 14.dp, vertical = 11.dp)
                ) {
                    BasicTextField(
                        value = input,
                        onValueChange = { input = it },
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontSize = 15.sp, color = ink
                        ),
                        maxLines = 4,
                        decorationBox = { inner ->
                            if (input.isEmpty()) {
                                Text(
                                    tr("说点什么…"), fontSize = 15.sp,
                                    color = ink.copy(alpha = 0.32f)
                                )
                            }
                            inner()
                        },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                Spacer(Modifier.width(8.dp))
                val canSend = input.isNotBlank() && !sending
                Box(
                    Modifier.size(42.dp).clip(CircleShape)
                        .background(if (canSend) V2.accent else ink.copy(alpha = 0.08f))
                        .tapable { send() },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        painterResource(R.drawable.ic_row_chevron), null,
                        tint = if (canSend) Color.White else ink.copy(alpha = 0.3f),
                        modifier = Modifier.size(18.dp).rotate(-90f)
                    )
                }
            }
            }
        }   // 输入条容器（不透明底 + 顶部 0.5dp 分割线）
    }

    // ---------- 群成员面板 ----------
    if (showMembers) {
        ModalBottomSheet(
            onDismissRequest = { showMembers = false },
            containerColor = frostedSheetColor(),
            scrimColor = frostedScrimColor()
        ) {
            Column(
                Modifier.fillMaxWidth()
                    .padding(horizontal = V2.gutter)
                    .navigationBarsPadding()
            ) {
                Text(gname, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(2.dp))
                Text(
                    tr("%d 人", members.size), fontSize = 12.sp,
                    color = ink.copy(alpha = 0.45f)
                )
                Spacer(Modifier.height(10.dp))
                Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                    members.forEach { m ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(squircle(V2.rowRadius))
                                .tapable { showMembers = false; onOpenPersona(m.id) }
                                .padding(vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Avatar(m.avatar, m.name, 38.dp)
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    m.name, fontSize = V2.body,
                                    fontWeight = FontWeight.Medium, maxLines = 1
                                )
                                // ⚠️ 这里原来显示成员 tagline，但本地角色的 tagline 存的是
                                // 人设提示词原文（PersonaLib.toPersona）—— 等于把提示词漏给用户。
                                // 2026-11-16 起成员行只显示名字，副标题改成本地状态文案。
                                Text(
                                    statusOf(9999L, 0), fontSize = V2.micro,
                                    color = ink.copy(alpha = 0.4f), maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                            Icon(
                                painterResource(R.drawable.ic_row_chevron), null,
                                tint = ink.copy(alpha = 0.25f),
                                modifier = Modifier.size(13.dp).rotate(180f)
                            )
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
            }
        }
    }

    // ---------- 表情面板（2026-11-16，跟单聊共用 `EmojiSheet`）----------
    if (emojiSheet) {
        EmojiSheet(
            onPick = { url -> sendEmoji(url) },
            onDismiss = { emojiSheet = false }
        )
    }

    // ---------- 改群名 ----------
    //
    // 用 `AlertDialog` + `BasicTextField`（不是 `OutlinedTextField`）：
    // 后者的浮动标签 + 焦点光圈是 Material 原生表单的味道，跟这套 V2 不搭。
    // 打开时**自动聚焦 + 全选**：用户点名字就是想覆盖写，不该再让他手动删一遍。
    if (renameOpen) {
        val cur = group?.name.orEmpty()
        // key 用 renameOpen：每次打开都从当前群名重新预填，不会残留上次改了一半的内容
        var text by remember(renameOpen) {
            mutableStateOf(
                TextFieldValue(cur, TextRange(0, cur.length))
            )
        }
        val focus = remember { FocusRequester() }
        val canSave = text.text.trim().isNotEmpty()
        LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

        AlertDialog(
            onDismissRequest = { renameOpen = false },
            title = { Text(tr("修改群名")) },
            text = {
                Box(
                    Modifier.fillMaxWidth()
                        .clip(squircle(12.dp))
                        .background(ink.copy(alpha = 0.05f))
                        .padding(horizontal = 12.dp, vertical = 10.dp)
                ) {
                    BasicTextField(
                        value = text,
                        // 一边输一边就截到 20 字 —— 群名太长顶栏会被挤爆
                        onValueChange = { v -> text = v.copy(text = v.text.take(20)) },
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontSize = 15.sp, color = ink
                        ),
                        cursorBrush = SolidColor(V2.accent),
                        modifier = Modifier.fillMaxWidth().focusRequester(focus)
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = canSave,
                    onClick = {
                        val g = group ?: return@TextButton
                        val next = g.copy(name = text.text.trim().take(20))
                        // `GroupStore.save` 会重写 updatedAt → 改完的群会顶到聊天列表最前，
                        // 这是对的（刚动过）。回读一次让内存里的 group 和盘上完全一致。
                        GroupStore.save(next)
                        group = GroupStore.find(gid) ?: next
                        renameOpen = false
                    }
                ) {
                    Text(
                        tr("保存"),
                        color = if (canSave) V2.accent else ink.copy(alpha = 0.3f)
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { renameOpen = false }) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }

    // ---------- 解散确认 ----------
    if (confirmDissolve) {
        AlertDialog(
            onDismissRequest = { confirmDissolve = false },
            title = { Text(tr("解散这个群聊？")) },
            text = {
                Text(
                    tr("群和里面的聊天记录都会删掉，删了就找不回来了。"),
                    fontSize = V2.sub
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDissolve = false
                    GroupStore.remove(gid)
                    onBack()
                }) { Text(tr("解散"), color = V2.alert) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDissolve = false }) { Text(tr("再想想")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }
}

/**
 * 成员头像条：最多露 5 个，互相压住一角（重叠 6dp）。
 *
 * 为什么要压：一排完整圆头像在顶栏里太占地方，压住就有"一群人"的感觉，
 * 也是微信/QQ 群通用的做法。
 */
@Composable
private fun GroupAvatarStrip(
    members: List<Api.Persona>,
    size: androidx.compose.ui.unit.Dp = 22.dp,
    onTap: () -> Unit
) {
    if (members.isEmpty()) return
    val ink = MaterialTheme.colorScheme.onSurface
    val shown = members.take(5)
    val step = size - 6.dp                     // 重叠 6dp
    val extra = if (members.size > shown.size) 1 else 0
    Box(
        Modifier
            .size(width = size + step * (shown.size - 1 + extra), height = size)
            .tapable { onTap() }
    ) {
        shown.forEachIndexed { i, m ->
            Box(
                Modifier.offset(x = step * i).size(size).clip(CircleShape)
                    // 压一圈底色描边，叠起来才分得清是一个个圆
                    .border(1.2.dp, MaterialTheme.colorScheme.background, CircleShape)
            ) {
                Avatar(m.avatar, m.name, size)
            }
        }
        if (extra == 1) {
            Box(
                Modifier.offset(x = step * shown.size).size(size).clip(CircleShape)
                    .background(ink.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    "+${members.size - shown.size}", fontSize = 9.sp,
                    color = ink.copy(alpha = 0.65f), fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

/**
 * 群聊的历史重排（2026-11-16）。
 *
 * 模型的接口只有 user / assistant 两种角色，没有"第三个人"这回事。
 * 所以站在**当前发言人**的角度：
 *   · 我说的 → assistant
 *   · 别人说的（包括真正的我）→ user，并在前面标「谁：」，
 *     否则模型会以为那些话是自己说的，接着往下替别人发言。
 * 最多取 16 条 —— 群里人多，全带上去既贵又容易跑题。
 */
private fun groupHistory(
    list: List<Api.Msg>,
    speakerId: String,
    nameOf: (String) -> String
): List<Api.Msg> = list.takeLast(16).map { m ->
    when {
        // 表情包消息要**带着 img 一起传**：`Api.chat()` 靠 `img` 非空把它转成
        // 「[发了一个表情包]」。只 copy content 的话，模型会收到一条空消息。
        m.role == "user" -> Api.Msg("user", m.content, "", m.img)
        m.who == speakerId -> Api.Msg("assistant", m.content, "", m.img)
        else -> {
            val n = nameOf(m.who).ifBlank { tr("有人") }
            Api.Msg("user", "$n：${m.content}", "", m.img)
        }
    }
}
