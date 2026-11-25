package com.aevis.android.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.I18n.tr

/**
 * 聊天设置半窗（2026-11-16，88；95 重做视觉）。
 *
 * 三组：聊天方式 / 回复方式 / 记忆与情绪。
 * 所有开关都**直接落到 ChatPrefs 并立刻生效**（ChatScreen 每次重组都读 prefs），
 * 不放"看起来能点但没接线"的假开关。
 *
 * 2026-11-16（95）只动样式，不动任何行为：
 *   · 「分段符号」「保留的标点」原来 12sp、45% 透明度，一串标点糊成几个灰点还被截断
 *     —— 现在统一 13sp、70%、等宽字体、右对齐，一串标点能一眼数清；
 *   · 整页原来是平铺的开关，没有层级 —— 现在每组之间留 8dp + 一行 11sp 组标题；
 *   · 开关统一成 44×26dp（Material 默认 52×32 在半窗里偏胖），开启色走 `V2.accent`。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatSettingsSheet(
    pid: String,
    onOpenPersona: () -> Unit,
    // 「完成」/点外部关闭只关半窗，**不做任何导航**（2026-11-16，99 修 bug：
    // 原来关闭回调直接调 onOpenPersona，导致点「完成」会跳进编辑角色页）
    onClose: () -> Unit = {}
) {
    val ink = MaterialTheme.colorScheme.onSurface
    // 136（根因）：这五项都是普通 prefs getter，**不订阅 `uiVersion` 就不会重组** ——
    // 点了 chip / 拖了滑块，pref 写进去了，但界面还显示旧值，看起来就是"点了没反应"。
    @Suppress("UNUSED_VARIABLE")
    val uiVer = ChatPrefs.uiVersion
    var sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    // 天气（110）：现实感知开且有城市才显示；拿不到整行不渲染
    val wctx = androidx.compose.ui.platform.LocalContext.current.applicationContext
    var weatherLine by remember { mutableStateOf("") }
    LaunchedEffect(ChatPrefs.realityAware) {
        if (!ChatPrefs.realityAware) { weatherLine = ""; return@LaunchedEffect }
        weatherLine = withContext(Dispatchers.IO) {
            runCatching {
                val c = ChatPrefs.city
                if (c.isBlank()) return@runCatching ""
                @Suppress("DEPRECATION")
                val a = android.location.Geocoder(wctx, java.util.Locale.getDefault())
                    .getFromLocationName(c, 1)?.firstOrNull() ?: return@runCatching ""
                val w = com.aevis.android.data.Api.weather(a.latitude, a.longitude)
                    ?: return@runCatching ""
                val t = if (w.temp == w.temp.toInt().toDouble()) "${w.temp.toInt()}"
                        else "%.1f".format(w.temp)
                "$c · ${w.desc} ${t}℃"
            }.getOrDefault("")
        }
    }

    ModalBottomSheet(
        onDismissRequest = { onClose() },
        sheetState = sheetState,
        // 135：半窗**不用玻璃**，实底 + 底下压一层遮罩，字才看得清
        containerColor = frostedSheetColor(),
        scrimColor = frostedScrimColor().copy(
            alpha = if (ink.luminance() > 0.5f) 0.55f else 0.32f
        ),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(
            topStart = 24.dp, topEnd = 24.dp
        )
    ) {
                Column(
            Modifier.fillMaxWidth().navigationBarsPadding()
                .heightIn(max = 620.dp)
        ) {
            // 177：标题栏**移出滚动区**（吸顶），滚动只发生在下面这个内层 Column
            Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(tr("聊天设置"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                            Spacer(Modifier.weight(1f))
                            Text(
                                tr("完成"), fontSize = 15.sp, fontWeight = FontWeight.Medium,
                                color = V2.accent,
                                modifier = Modifier.tapable { onClose() }
                                    .padding(horizontal = 4.dp, vertical = 4.dp)
                            )
                        }
            Column(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .verticalScroll(rememberScrollState())
            ) {


            // 135：这五项**按角色独立**，先说明白，别让人以为改的是全局
            Text(
                tr("下面这些仅对这个角色生效（全局默认在「通用配置」里）"),
                fontSize = 10.5.sp, lineHeight = 16.sp, color = ink.copy(alpha = 0.4f),
                modifier = Modifier.padding(top = 8.dp, bottom = 2.dp)
            )

            // 135：实时预览 —— 改字号 / 括号 / 头像时这里立刻变（不用关窗）
            SheetSection(tr("预览"))
            val pvSize = ChatPrefs.msgFontSpOf(pid).sp
            val pvLine = ChatPrefs.msgLineSpOf(pid).sp
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.Top
            ) {
                if (ChatPrefs.avatarModeOf(pid) != 2) {
                    Avatar("", "AI", 30.dp)
                    Spacer(Modifier.width(8.dp))
                }
                Column {
                    val tc = ink
                    val dim = if (ChatPrefs.annotDimOf(pid)) tc.copy(alpha = 0.6f) else tc
                    Text(
                        text = chatAnnotated(tr("（她抬眼看你）今天想聊点什么？"), tc, dim),
                        fontSize = pvSize, lineHeight = pvLine,
                        modifier = Modifier.clip(squircle(10.dp))
                            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                            .padding(horizontal = 10.dp, vertical = 8.dp)
                    )
                }
            }

            // ---------- 126：流式速度 ----------
            // 用户参考图的第一组：右侧显示"每秒约 N 字"，下面四段 chip。
            SheetSection(tr("流式速度"))
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("逐字速度"), fontSize = V2.body)
                Spacer(Modifier.weight(1f))
                Text(
                    tr("每秒约 %d 字", (1000L / ChatPrefs.typeSpeedMs()).toInt()),
                    fontSize = 12.sp, fontWeight = FontWeight.Medium, color = V2.accent
                )
            }
            Spacer(Modifier.height(6.dp))
            Row(
                Modifier.fillMaxWidth()
                    .height(40.dp)                      // 178：固定行高，防点芯片时整屏跳位
                    .horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,   // 178：固定高度后垂直居中
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val ts = ChatPrefs.typeSpeed
                Chip(tr("慢"), ts == 0) { ChatPrefs.typeSpeed = 0; ChatPrefs.bumpUi() }
                Chip(tr("适中"), ts == 1) { ChatPrefs.typeSpeed = 1; ChatPrefs.bumpUi() }
                Chip(tr("快"), ts == 2) { ChatPrefs.typeSpeed = 2; ChatPrefs.bumpUi() }
                Chip(tr("很快"), ts == 3) { ChatPrefs.typeSpeed = 3; ChatPrefs.bumpUi() }
            }

            // ---------- 126：显示 ----------
            SheetSection(tr("显示"))
            SwitchRow(
                tr("括号内容变浅"), tr("（动作描写）用更浅的颜色，跟对话区分开"),
                ChatPrefs.annotDimOf(pid)
            ) { ChatPrefs.setAnnotDim(pid, it) }
            Spacer(Modifier.height(6.dp))
            Text(tr("头像显示"), fontSize = 12.sp, color = ink.copy(alpha = 0.5f))
            Spacer(Modifier.height(6.dp))
            Row(
                Modifier.fillMaxWidth()
                    .height(40.dp)                      // 178：固定行高，防点芯片时整屏跳位
                    .horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,   // 178：固定高度后垂直居中
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val am = ChatPrefs.avatarModeOf(pid)
                Chip(tr("双方都显示"), am == 0) { ChatPrefs.setAvatarMode(pid, 0) }
                Chip(tr("只显示角色"), am == 1) { ChatPrefs.setAvatarMode(pid, 1) }
                Chip(tr("都不显示"), am == 2) { ChatPrefs.setAvatarMode(pid, 2) }
            }

            // ---------- 126：输入与状态 ----------
            SheetSection(tr("输入与状态"))
            SwitchRow(
                tr("回车发送"), tr("关掉后回车是换行，用右侧按钮发送"),
                ChatPrefs.enterSendOf(pid)
            ) { ChatPrefs.setEnterSend(pid, it) }
            SwitchRow(
                tr("显示回复状态"), tr("顶栏「正在输入中」与气泡下的状态提示"),
                ChatPrefs.showReplyStatusOf(pid)
            ) { ChatPrefs.setShowReplyStatus(pid, it) }

            // ---------- 126：消息大小 ----------
            SheetSection(tr("消息大小"))
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("字号"), fontSize = V2.body)
                Spacer(Modifier.weight(1f))
                Text(
                    when (ChatPrefs.msgSizeOf(pid)) {
                        0 -> tr("小")
                        2 -> tr("大")
                        else -> tr("标准")
                    },
                    fontSize = 12.sp, fontWeight = FontWeight.Medium, color = V2.accent
                )
            }
            androidx.compose.material3.Slider(
                value = ChatPrefs.msgSizeOf(pid).toFloat(),
                // 136：四舍五入吸附到 0/1/2（`toInt()` 会把 0.9 截成 0，看着像拖不动）
                onValueChange = {
                    ChatPrefs.setMsgSize(pid, Math.round(it).toInt().coerceIn(0, 2))
                },
                valueRange = 0f..2f,
                steps = 1,
                colors = androidx.compose.material3.SliderDefaults.colors(
                    thumbColor = V2.accent,
                    activeTrackColor = V2.accent,
                    inactiveTrackColor = ink.copy(alpha = 0.10f)
                ),
                modifier = Modifier.fillMaxWidth().height(34.dp)
            )
            Text(
                tr("小 13.5 · 标准 15 · 大 17（行高 1.45 倍）"),
                fontSize = 10.5.sp, color = ink.copy(alpha = 0.35f)
            )

            // ---------- 1. 聊天方式 ----------
            SheetSection(tr("聊天方式"))
            Text(tr("优先用"), fontSize = 12.sp, color = ink.copy(alpha = 0.5f))
            Spacer(Modifier.height(6.dp))
            Row(
                Modifier.fillMaxWidth()
                    .height(40.dp)                      // 178：固定行高，防点芯片时整屏跳位
                    .horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,   // 178：固定高度后垂直居中
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val cs = ChatPrefs.chargeSource
                Chip(tr("自动"), cs == 0) { ChatPrefs.chargeSource = 0 }
                Chip(tr("会员额度"), cs == 0) { ChatPrefs.chargeSource = 0 }
                Chip(tr("墨点"), cs == 1) { ChatPrefs.chargeSource = 1 }
            }
            Spacer(Modifier.height(10.dp))
            SwitchRow(
                tr("时间感知"), tr("让它知道你那边的时间、电量和天气"),
                ChatPrefs.realityAware
            ) { ChatPrefs.realityAware = it }
            if (weatherLine.isNotBlank()) {
                Text(
                    weatherLine, fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                    modifier = Modifier.padding(start = 2.dp, bottom = 4.dp)
                )
            }

            // ---------- 2. 回复方式 ----------
            SheetSection(tr("回复方式"))
            SwitchRow(
                tr("普通模式（一条条回）"), tr("关 = 内心 OS，整段一条"),
                ChatPrefs.chatMode == 0
            ) { on ->
                ChatPrefs.chatMode = if (on) 0 else 1
            }
            // 逐字是显示效果，跟模式无关（2026-11-16）
            SwitchRow(
                tr("逐字显示"), tr("在当前这条气泡里一个字一个字蹦"),
                ChatPrefs.typewriter
            ) { ChatPrefs.typewriter = it }
            ReadRow(tr("分段符号"), "。！？～")
            Spacer(Modifier.height(8.dp))
            Text(tr("回复长度"), fontSize = 12.sp, color = ink.copy(alpha = 0.5f))
            Spacer(Modifier.height(6.dp))
            Row(
                Modifier.fillMaxWidth()
                    .height(40.dp)                      // 178：固定行高，防点芯片时整屏跳位
                    .horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,   // 178：固定高度后垂直居中
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val rl = ChatPrefs.replyLen
                Chip(tr("简洁"), rl == 0) { ChatPrefs.replyLen = 0 }
                Chip(tr("常规"), rl == 1) { ChatPrefs.replyLen = 1 }
                Chip(tr("话痨"), rl == 2) { ChatPrefs.replyLen = 2 }
            }
            Spacer(Modifier.height(6.dp))
            SwitchRow(
                tr("括号内容单独一行"), tr("括号里的内容单独作为一条发出"),
                ChatPrefs.parenOwnLine
            ) { ChatPrefs.parenOwnLine = it }
            SwitchRow(
                tr("去掉分段处的标点"), tr("拆完每条末尾的标点去掉"),
                ChatPrefs.stripSplitPunct
            ) { ChatPrefs.stripSplitPunct = it }
            ReadRow(tr("保留的标点"), "？！～…")
            SwitchRow(
                tr("合并发送"), tr("忽略分段，整段一条发出"),
                ChatPrefs.mergeSend
            ) { ChatPrefs.mergeSend = it }
            Spacer(Modifier.height(4.dp))
            Text(
                tr("括号内容单独一行：括号里的内容单独作为一条发出，里面有分段标点也不截断。"),
                fontSize = 10.5.sp, lineHeight = 16.sp, color = ink.copy(alpha = 0.35f)
            )

            // ---------- 3. 记忆与情绪 ----------
            SheetSection(tr("记忆与情绪"))
            Row(
                Modifier.fillMaxWidth().padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("上下文条数"), fontSize = V2.body)
                Spacer(Modifier.weight(1f))
                Stepper(
                    value = ChatPrefs.ctxWindow,
                    onChange = { ChatPrefs.ctxWindow = it }
                )
            }
            Text(
                tr("只把最近 %d 条发给模型", ChatPrefs.ctxWindow),
                fontSize = 10.5.sp, color = ink.copy(alpha = 0.35f)
            )
            Spacer(Modifier.height(8.dp))
            Row(
                Modifier.fillMaxWidth().tapable { onOpenPersona() }.padding(vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("角色档案"), fontSize = V2.body)
                Spacer(Modifier.weight(1f))
                Text("›", fontSize = 18.sp, color = ink.copy(alpha = 0.3f))
            }
            Spacer(Modifier.height(20.dp))
                    }
        }
    }
}


/**
 * 组标题：11sp / onSurface 45% / 字距 .04em。
 * 组与组之间只靠这 8dp + 一行小标题分层，不再加分割线（半窗里线多了像表格）。
 */
@Composable
private fun SheetSection(title: String) {
    Spacer(Modifier.height(8.dp))
    Text(
        title, fontSize = 11.sp, fontWeight = FontWeight.Medium,
        letterSpacing = 0.44.sp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f)
    )
    Spacer(Modifier.height(6.dp))
}

@Composable
private fun Chip(label: String, on: Boolean, onClick: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Text(
        label, fontSize = 12.sp,
        // 178：字重固定，选中态只改颜色/底色 —— 原来切 Medium 会引起重排跳位
        fontWeight = FontWeight.Medium,
        color = if (on) V2.accent else ink.copy(alpha = 0.6f),
        // 136：padding 放前面 —— 否则 hit 区域只有文字那块，肉眼"点在胶囊上"却落在外面
        modifier = Modifier
            .clip(squircle(9.dp))
            .background(if (on) V2.accent.copy(alpha = 0.16f) else ink.copy(alpha = 0.05f))
            // 136：tapable 放在内边距**之前** → 整块胶囊（含内边距）都能点
            .tapable { onClick() }
            .padding(horizontal = 12.dp, vertical = 6.dp)
    )
}

@Composable
private fun SwitchRow(title: String, sub: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = V2.body)
            Spacer(Modifier.height(1.dp))
            Text(sub, fontSize = 10.5.sp, color = ink.copy(alpha = 0.4f))
        }
        Spacer(Modifier.width(10.dp))
        V2Switch(checked = checked, onChange = onChange)
    }
}

/** 44×26dp 的小开关。行为完全等价于 Material `Switch`，只是尺寸和配色按 V2 走。*/
@Composable
private fun V2Switch(checked: Boolean, onChange: (Boolean) -> Unit) {
    val trackW = 44.dp
    val trackH = 26.dp
    val knob = 22.dp
    val pad = (trackH - knob) / 2
    val offTrack = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f)
    val track by animateColorAsState(
        if (checked) V2.accent else offTrack, label = "swTrack"
    )
    val knobX by animateDpAsState(
        if (checked) trackW - knob - pad else pad, label = "swKnob"
    )
    Box(
        Modifier.size(trackW, trackH).clip(CircleShape).background(track)
            .tapable { onChange(!checked) }
    ) {
        Box(
            Modifier.align(Alignment.CenterStart).offset(x = knobX)
                .size(knob).clip(CircleShape).background(Color.White)
        )
    }
}

/**
 * 只读的「标签 …… 值」行。
 *
 * 右值统一 13sp / onSurface 70% / **等宽**：分段符号那几个标点等宽之后才对得齐，
 * 中文字体里 `。！？～…` 的宽度不一致，混排看起来像一堆灰点。
 */
@Composable
private fun ReadRow(label: String, value: String) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, fontSize = V2.body)
        Spacer(Modifier.weight(1f))
        Text(
            value, fontSize = 13.sp, textAlign = TextAlign.End,
            fontFamily = FontFamily.Monospace,
            color = ink.copy(alpha = 0.7f),
            maxLines = 1, softWrap = false
        )
    }
}

/** 3–24 步进器。*/
@Composable
private fun Stepper(value: Int, onChange: (Int) -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier.size(28.dp).clip(squircle(8.dp))
                .background(ink.copy(alpha = 0.06f))
                .tapable { onChange((value - 1).coerceIn(3, 24)) },
            contentAlignment = Alignment.Center
        ) { Text("−", fontSize = 15.sp, color = ink.copy(alpha = 0.6f)) }
        Text(
            "$value", fontSize = 14.sp,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.padding(horizontal = 12.dp)
        )
        Box(
            Modifier.size(28.dp).clip(squircle(8.dp))
                .background(ink.copy(alpha = 0.06f))
                .tapable { onChange((value + 1).coerceIn(3, 24)) },
            contentAlignment = Alignment.Center
        ) { Text("+", fontSize = 15.sp, color = ink.copy(alpha = 0.6f)) }
    }
}
