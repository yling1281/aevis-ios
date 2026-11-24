package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.I18n.tr

/**
 * 聊天外观设置（2026-11-15，2026-11-16 加「气泡颜色」）。
 *
 * 用户：「用户能控制头像大小，能控制气泡的形状，有三个形状，还能控制气泡与头像之间的间距，
 * 还能自定义整体背景或者聊天背景，或者模糊或者动效」，
 * 后面又加一条：「气泡颜色我要自己能调」。
 *
 * 结构参照「忆伴」的 `ChatSettingsActivity`：外观参数 + 背景 两块。
 * 每一项改完**立刻写盘**，聊天页返回时自动生效（不需要点保存）。
 */
@Composable
fun ChatSettingsScreen(onBack: () -> Unit, onOpenBackground: () -> Unit = {}) {
    val ink = MaterialTheme.colorScheme.onSurface
    val dark = ink.luminance() > 0.5f

    // 用 mutableState 包一层，拖动滑块时立刻看到预览
    var avatar by remember { mutableIntStateOf(ChatPrefs.avatarSize) }
    var bubble by remember { mutableIntStateOf(ChatPrefs.bubbleStyle) }
    var gap by remember { mutableIntStateOf(ChatPrefs.gap) }
    // 127：字号合并到 `msgSize`（跟「聊天设置」半窗同一个值）
    var msgSize by remember { mutableIntStateOf(ChatPrefs.msgSize) }
    var width by remember { mutableIntStateOf(ChatPrefs.bubbleWidthPct) }
    // 气泡颜色（2026-11-16）。写盘 + 更新本地 state，预览立刻变
    var mineBubble by remember { mutableIntStateOf(ChatPrefs.mineBubble) }
    var aiBubble by remember { mutableIntStateOf(ChatPrefs.aiBubble) }
    // 取色弹窗开给谁：null = 关闭 / true = 我的气泡 / false = 对方气泡
    var sheetForMine by remember { mutableStateOf<Boolean?>(null) }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 顶栏走公共的 `SubPageHeader`（2026-11-16 视觉统一）
        SubPageHeader(title = "聊天外观", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            // ---------- 实时预览 ----------
            SectionLabel(tr("预览"))
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                PreviewBubble(
                    avatar = avatar.dp, bubble = bubble, gap = gap.dp,
                    font = ChatPrefs.msgFontSp().sp, widthPct = width,
                    mineBg = BubblePalette.mineColor(mineBubble),
                    // 对方「跟随主题」时传 null，预览就画原来那层淡底
                    aiBg = if (aiBubble == 0) null else BubblePalette.aiColor(aiBubble, dark)
                )
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 头像大小 ----------
            SettingSlider(
                title = tr("头像大小"),
                value = avatar, range = 32f..72f, unit = "dp",
                onChange = { avatar = it; ChatPrefs.avatarSize = it }
            )

            // ---------- 气泡形状 ----------
            // 2026-11-16：三张缩略卡换成公共的 `SegmentedTabs`（滑动指示块 + 内容过渡），
            // 形状本身在上面的「预览」里已经是活的，这里不需要再画三个小方块。
            // 当前状态（2026-11-16）：用户要"能看出依据"，别显得玄学。
            // 文案来自 `core/StatusOf` 的本地关键词推断，这里只展示。
            SectionLabel(tr("显示"))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("当前状态"), fontSize = V2.body)
                Spacer(Modifier.weight(1f))
                // 依据来自模型给的状态（StatusStore），不是本地关键词
                val label = com.aevis.android.core.StatusStore.lastText
                val at = com.aevis.android.core.StatusStore.lastAt
                val mins = com.aevis.android.core.StatusStore.agoMinutes(at)
                Text(
                    when {
                        label.isBlank() -> "在线"
                        mins == Long.MAX_VALUE -> tr("%s（模型判断）", label)
                        else -> tr("%s（模型判断 · %d 分钟前）", label, mins)
                    },
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
                )
            }
            Spacer(Modifier.height(4.dp))

            // 常驻通知开关（2026-11-16）：默认开
            val ctx = androidx.compose.ui.platform.LocalContext.current
            var keepAlive by remember { mutableStateOf(com.aevis.android.core.ChatPrefs.keepAlive) }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text(tr("常驻通知"), fontSize = V2.body)
                    Spacer(Modifier.height(2.dp))
                    Text(
                        tr("通知栏留一条「在等你」，点开回 App"),
                        fontSize = 11.sp, color = ink.copy(alpha = 0.42f)
                    )
                }
                androidx.compose.material3.Switch(
                    checked = keepAlive,
                    onCheckedChange = {
                        keepAlive = it
                        com.aevis.android.core.ChatPrefs.keepAlive = it
                        com.aevis.android.core.AeviService.apply(ctx)
                    }
                )
            }
            Spacer(Modifier.height(6.dp))

            SectionLabel(tr("气泡形状"))
            SegmentedTabs(
                tabs = listOf(tr("大圆角"), tr("小圆角"), tr("尖角")),
                selected = bubble,
                onSelect = { bubble = it; ChatPrefs.bubbleStyle = it }
            )

            // ---------- 气泡颜色（2026-11-16 新增）----------
            // 放在「形状」之后、「间距」之前：形状和颜色是同一类"气泡长什么样"的设置，
            // 中间隔一个间距滑块会让人以为颜色属于别的分组。
            SectionLabel(tr("气泡颜色"))
            BubbleColorBlock(
                title = tr("我的气泡"),
                current = mineBubble,
                presets = BubblePalette.presets.map { it.mine.toInt() },
                onPick = { mineBubble = it; ChatPrefs.mineBubble = it },
                onCustom = { sheetForMine = true }
            )
            BubbleColorBlock(
                title = tr("对方气泡"),
                current = aiBubble,
                presets = BubblePalette.presets.map { it.ai.toInt() },
                // 对方这侧多一个「跟随主题」—— 0 是它的默认值，
                // 不给出口的话用户一旦点了别的色就再也回不去
                showThemeChip = true,
                onReset = { aiBubble = 0; ChatPrefs.aiBubble = 0 },
                onPick = { aiBubble = it; ChatPrefs.aiBubble = it },
                onCustom = { sheetForMine = false }
            )

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 间距 ----------
            SettingSlider(
                title = tr("气泡与头像间距"),
                value = gap, range = 2f..20f, unit = "dp",
                onChange = { gap = it; ChatPrefs.gap = it }
            )

            // ---------- 字号（127：跟聊天设置半窗共用 `msgSize`）----------
            MsgSizeChips(value = msgSize) { v ->
                msgSize = v
                ChatPrefs.msgSize = v
            }

            // ---------- 气泡宽度 ----------
            SettingSlider(
                title = tr("气泡最大宽度"),
                value = width, range = 55f..88f, unit = "%",
                onChange = { width = it; ChatPrefs.bubbleWidthPct = it }
            )

            Spacer(Modifier.height(V2.sectionGap))
            SectionLabel(tr("聊天背景"))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().tapable { onOpenBackground() }
                        .padding(horizontal = V2.gutter, vertical = 15.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(tr("背景图与模糊"), fontSize = V2.body)
                    Spacer(Modifier.weight(1f))
                    Text(tr("去设置"), fontSize = V2.tiny, color = V2.accent)
                    Spacer(Modifier.width(4.dp))
                    Icon(painterResource(R.drawable.ic_row_chevron), null,
                        tint = ink.copy(alpha = 0.25f),
                        modifier = Modifier.size(13.dp).rotate(180f))
                }
            }

            Spacer(Modifier.height(V2.sectionGap))
            Text(
                tr("改动即时生效，返回聊天页就能看到。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.32f),
                modifier = Modifier.padding(horizontal = V2.gutter)
            )
            Spacer(Modifier.height(34.dp))
        }
    }

    // ---------- 取色弹窗（2026-11-16）----------
    // HSV 三条滑块，比给几十个色块更"自由"（用户说的原话是「自己能调」）。
    // 只有点「用这个颜色」才写盘；点取消/下滑关掉都不写。
    val target = sheetForMine
    if (target != null) {
        ColorSheet(
            title = if (target) tr("我的气泡颜色") else tr("对方气泡颜色"),
            initial = if (target) mineBubble else aiBubble,
            onDismiss = { sheetForMine = null },
            onConfirm = { c ->
                if (target) { mineBubble = c; ChatPrefs.mineBubble = c }
                else { aiBubble = c; ChatPrefs.aiBubble = c }
                sheetForMine = null
            }
        )
    }
}

/** 区块标题（一眼能看出分组，又不抢正文）。*/
@Composable
private fun SectionLabel(text: String) {
    Text(
        text, fontSize = V2.sub, fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        modifier = Modifier.padding(start = V2.gutter, end = V2.gutter, top = 6.dp, bottom = 8.dp)
    )
}

/**
 * 一行气泡配色：标题 + 六个预设圆点（+ 可选的「跟随主题」/「取色」）。
 *
 * 选中态用**外圈 2dp 主色环 + 内圈白勾**，而不是把圆点放大 ——
 * 放大会让六个点的直径不一致，一行看着就歪。
 */
@Composable
private fun BubbleColorBlock(
    title: String,
    current: Int,
    presets: List<Int>,
    onPick: (Int) -> Unit,
    onCustom: () -> Unit,
    showThemeChip: Boolean = false,
    onReset: (() -> Unit)? = null
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontSize = V2.body)
            Spacer(Modifier.weight(1f))
            if (showThemeChip && onReset != null) {
                val themeOn = current == 0
                Text(
                    tr("跟随主题"),
                    fontSize = V2.micro,
                    color = if (themeOn) V2.accent else ink.copy(alpha = 0.45f),
                    modifier = Modifier
                        .clip(squircle(9.dp))
                        .background(
                            if (themeOn) V2.accent.copy(alpha = 0.12f) else ink.copy(alpha = 0.05f)
                        )
                        .tapable { onReset() }
                        .padding(horizontal = 9.dp, vertical = 5.dp)
                )
                Spacer(Modifier.width(8.dp))
            }
            Text(
                tr("取色"),
                fontSize = V2.tiny, color = V2.accent, fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .clip(squircle(9.dp))
                    .tapable { onCustom() }
                    .padding(horizontal = 8.dp, vertical = 5.dp)
            )
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            presets.forEach { c ->
                val on = current == c
                Box(
                    Modifier.size(34.dp).clip(CircleShape)
                        .then(if (on) Modifier.border(2.dp, V2.accent, CircleShape) else Modifier)
                        .tapable { onPick(c) },
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        Modifier.size(if (on) 24.dp else 28.dp).clip(CircleShape)
                            .background(Color(c)),
                        contentAlignment = Alignment.Center
                    ) {
                        if (on) {
                            Icon(
                                painterResource(R.drawable.ic_check), contentDescription = null,
                                tint = BubblePalette.textOn(Color(c)),
                                modifier = Modifier.size(13.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

/** 一条通用滑块行。 */
/**
 * 字号三档（2026-11-16，127）：跟聊天设置半窗的「消息大小」**同一个 pref**，
 * 两个入口显示的值永远一致（改一边、另一边重开就是新值）。
 */
@Composable
private fun MsgSizeChips(value: Int, onChange: (Int) -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.padding(horizontal = V2.gutter, vertical = 2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(tr("文字大小"), fontSize = V2.body)
            Spacer(Modifier.weight(1f))
            Text(
                when (value) { 0 -> tr("小"); 2 -> tr("大"); else -> tr("标准") },
                fontSize = V2.tiny, color = V2.accent, fontWeight = FontWeight.Medium
            )
        }
        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(0 to tr("小"), 1 to tr("标准"), 2 to tr("大")).forEach { (v, label) ->
                val on = value == v
                Text(
                    label, fontSize = 12.sp,
                    color = if (on) V2.accent else ink.copy(alpha = 0.6f),
                    modifier = Modifier.clip(squircle(9.dp))
                        .background(
                            if (on) V2.accent.copy(alpha = 0.13f) else ink.copy(alpha = 0.05f)
                        )
                        .tapable { onChange(v) }
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                )
            }
        }
    }
}

@Composable
private fun SettingSlider(
    title: String,
    value: Int,
    range: ClosedFloatingPointRange<Float>,
    unit: String,
    onChange: (Int) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.padding(horizontal = V2.gutter, vertical = 2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontSize = V2.body)
            Spacer(Modifier.weight(1f))
            Text("$value$unit", fontSize = V2.tiny, color = V2.accent,
                fontWeight = FontWeight.Medium)
        }
        Slider(
            value = value.toFloat(),
            onValueChange = { onChange(it.toInt()) },
            valueRange = range,
            colors = SliderDefaults.colors(
                thumbColor = V2.accent,
                activeTrackColor = V2.accent,
                inactiveTrackColor = ink.copy(alpha = 0.10f)
            ),
            modifier = Modifier.fillMaxWidth().height(34.dp)
        )
    }
}

/**
 * 取色面板：色相 / 饱和 / 明度 三条滑块 + 实时预览。
 *
 * 为什么用 HSV 而不是色轮或色板：色轮在手机上太难点准，
 * 色板永远是"别人挑好的颜色"；三条滑块手指一拖就能扫过整个色域，
 * 「自己能调」这件事才成立。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ColorSheet(
    title: String,
    initial: Int,
    onDismiss: () -> Unit,
    onConfirm: (Int) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface

    // 进来的那一刻把当前值转成 HSV（`initial == 0` 说明还是「跟随主题」，
    // 用主色当起点，免得一进来是一个黑块）
    val start = remember(initial) {
        val arr = FloatArray(3)
        android.graphics.Color.colorToHSV(
            if (initial == 0) 0xFF9B8AF0.toInt() else initial, arr
        )
        arr
    }
    var h by remember(initial) { mutableFloatStateOf(start[0]) }
    var s by remember(initial) { mutableFloatStateOf(start[1] * 100f) }
    var v by remember(initial) { mutableFloatStateOf(start[2] * 100f) }

    // HSVToColor 会给不透明色，正好 —— 透明度由聊天页那边统一叠（0.92 / 0.55）
    val color = Color(
        android.graphics.Color.HSVToColor(
            floatArrayOf(h.coerceIn(0f, 360f), s / 100f, v / 100f)
        )
    )
    val hex = String.format("#%06X", 0xFFFFFF and color.toArgb())

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
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(10.dp))

            // 预览：就用当前颜色画一条气泡，字色跟它算 —— 所见即所得
            Box(
                Modifier.fillMaxWidth()
                    .clip(squircle(14.dp))
                    .background(ink.copy(alpha = 0.04f))
                    .padding(12.dp)
            ) {
                Box(
                    Modifier.clip(squircle(16.dp))
                        .background(color)
                        .padding(horizontal = 13.dp, vertical = 10.dp)
                ) {
                    Text(
                        tr("这个颜色看着舒服吗？"),
                        fontSize = 15.sp, color = BubblePalette.textOn(color)
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
            SettingSlider(tr("色相"), h.toInt(), 0f..360f, "°") { h = it.toFloat() }
            SettingSlider(tr("饱和度"), s.toInt(), 0f..100f, "%") { s = it.toFloat() }
            SettingSlider(tr("明度"), v.toInt(), 0f..100f, "%") { v = it.toFloat() }

            Text(
                hex, fontSize = V2.tiny, color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 2.dp)
            )

            Spacer(Modifier.height(14.dp))
            Row(
                Modifier.fillMaxWidth().padding(bottom = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                // 取消 = 什么都不写，直接关
                Box(
                    Modifier.weight(1f).clip(squircle(14.dp))
                        .background(ink.copy(alpha = 0.06f))
                        .tapable { onDismiss() }
                        .padding(vertical = 13.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(tr("取消"), fontSize = V2.body, color = ink.copy(alpha = 0.7f))
                }
                Box(
                    Modifier.weight(1.4f).clip(squircle(14.dp))
                        .background(V2.accent)
                        .tapable { onConfirm(color.toArgb()) }
                        .padding(vertical = 13.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        tr("用这个颜色"), fontSize = V2.body,
                        fontWeight = FontWeight.Medium, color = Color.White
                    )
                }
            }
        }
    }
}

/** 预览：一条 AI、一条我。颜色跟着设置实时变（用户要"在设置页就能看到效果"）。*/
@Composable
private fun PreviewBubble(
    avatar: Dp,
    bubble: Int,
    gap: Dp,
    font: TextUnit,
    widthPct: Int,
    mineBg: Color,
    aiBg: Color?
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val r = when (bubble) { 0 -> 18.dp; 1 -> 8.dp; else -> 5.dp }
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Box(
                Modifier.size(avatar).clip(CircleShape)
                    .background(V2.accent.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center
            ) {
                Text("AI", fontSize = (avatar.value * 0.32f).sp,
                    color = V2.accent, fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.width(gap))
            Box(
                Modifier.clip(RoundedCornerShape(r, r, r, 4.dp))
                    .background(aiBg ?: ink.copy(alpha = 0.055f))
                    .padding(horizontal = 11.dp, vertical = 8.dp)
            ) {
                Text(
                    tr("这样看着还行吗？"), fontSize = font,
                    lineHeight = (font.value + 6).sp,
                    color = aiBg?.let { BubblePalette.textOn(it) } ?: ink
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Box(
                Modifier.clip(RoundedCornerShape(r, r, 4.dp, r))
                    .background(mineBg)
                    .padding(horizontal = 11.dp, vertical = 8.dp)
            ) {
                Text(
                    tr("挺好的"), fontSize = font,
                    lineHeight = (font.value + 6).sp,
                    color = BubblePalette.textOn(mineBg)
                )
            }
        }
    }
}
