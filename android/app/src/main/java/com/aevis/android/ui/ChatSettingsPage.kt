package com.aevis.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.ChatPrefs

/**
 * 聊天设置（整页，2026-11-17）。
 *
 * 用户：「不要往上滑的那个，直接搞个二级菜单」——原来这里是 ModalBottomSheet 半窗。
 * 新页面路由 `chatset:<pid>`，全部直连 ChatPrefs，改完聊天页立刻生效。
 */

private val CardBg = Color(0xFFFFFFFF)
private val InkDark = Color(0xFF1B1D2A)
private val InkDim = Color(0xFF6B7189)
private val Accent = Color(0xFF4A6CF7)
private val PageBg = Color(0xFFF5F6FA)

private val BubbleColors = listOf(
    Color(0xFFD8E2FF),
    Color(0xFFFFD9E2),
    Color(0xFFD9F2E6),
    Color(0xFFFFEFD1)
)

@Composable
/**
 * ⚠️ 2026-11-17（174）**已废弃，不再挂路由**：设置项已统一到 `ChatSettingsSheet`（半窗），
 * 这个整页版本口径与半窗不一致（字号曾把 0..2 档位当 sp 用），保留文件仅作参考。
 */
fun ChatSettingsPage(pid: String, onBack: () -> Unit) {
    // 174：订阅 prefs 版本 —— 不读它的话，点了只写盘不重组，看着就是"完全没反应"
    val uiVer = com.aevis.android.core.ChatPrefs.uiVersion

    @Suppress("UNUSED_VARIABLE")
    val ver = ChatPrefs.uiVersion   // 订阅：pref 改了要重组

    Column(Modifier.fillMaxSize().background(PageBg).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(40.dp).clip(RoundedCornerShape(50)).tapable { onBack() },
                contentAlignment = Alignment.Center
            ) { Text("‹", fontSize = 27.sp, color = InkDark) }
            Text("聊天设置", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = InkDark)
        }

        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 6.dp)
        ) {
            // 预览
            Card {
                Text("预览", fontSize = 12.sp, color = InkDim)
                Spacer(Modifier.height(10.dp))
                Box(
                    Modifier.fillMaxWidth(ChatPrefs.bubbleWidthPct / 100f)
                        .clip(shapeOf(ChatPrefs.bubbleStyle))
                        .background(BubbleColors[ChatPrefs.bubbleStyle.coerceIn(0, 3)])
                        .padding(horizontal = 13.dp, vertical = 10.dp)
                ) {
                    Text(
                        "（她抬眼看你）今天想聊点什么？",
                        // 174 修：msgSize 是 **0..2 的档位**，不是字号！
                        // 以前这里 .sp 直接把档位当字号 → 显示 1sp、胶囊高亮也永远对不上
                        fontSize = ChatPrefs.msgFontSp().sp,
                        lineHeight = (ChatPrefs.msgFontSp() + 8).sp,
                        color = InkDark
                    )
                }
            }

            // 字体大小
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("字体大小", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = InkDark)
                    Spacer(Modifier.weight(1f))
                    Text("${ChatPrefs.msgFontSp()} sp", fontSize = 12.sp, color = InkDim)
                }
                Spacer(Modifier.height(10.dp))
                // 三档对应 msgSize 0/1/2（13.5 / 15 / 17），选中的判断才和写入口径一致
                SegRow(listOf("小" to 0, "标准" to 1, "大" to 2),
                    ChatPrefs.msgSize) { ChatPrefs.msgSize = it }
            }

            // 气泡配色
            Card {
                Text("气泡配色", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = InkDark)
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    BubbleColors.forEachIndexed { idx, color ->
                        val on = ChatPrefs.bubbleStyle == idx
                        Box(
                            Modifier.size(44.dp).clip(RoundedCornerShape(14.dp))
                                .background(color)
                                .tapable { ChatPrefs.bubbleStyle = idx },
                            contentAlignment = Alignment.Center
                        ) { if (on) Text("✓", fontSize = 16.sp, color = InkDark) }
                    }
                }
            }

            // 气泡宽度
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("气泡宽度", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = InkDark)
                    Spacer(Modifier.weight(1f))
                    Text("${ChatPrefs.bubbleWidthPct}%", fontSize = 12.sp, color = InkDim)
                }
                Slider(
                    value = ChatPrefs.bubbleWidthPct.toFloat(),
                    onValueChange = { ChatPrefs.bubbleWidthPct = it.toInt() },
                    valueRange = 55f..88f
                )
            }

            // 开关
            Card {
                Toggle("显示时间", ChatPrefs.displayMode != 0) {
                    ChatPrefs.displayMode = if (it) 1 else 0
                }
                Line()
                Toggle("显示已读状态", ChatPrefs.showReplyStatus) { ChatPrefs.showReplyStatus = it }
                Line()
                Toggle("括号描写变灰", ChatPrefs.annotDim) { ChatPrefs.annotDim = it }
                Line()
                Toggle("逐字显示", ChatPrefs.typewriter) { ChatPrefs.typewriter = it }
                Line()
                Toggle("提示音", ChatPrefs.soundOn) { ChatPrefs.soundOn = it }
                Line()
                Toggle("回车发送", ChatPrefs.enterSend) { ChatPrefs.enterSend = it }
            }

            // 头像
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("头像大小", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = InkDark)
                    Spacer(Modifier.weight(1f))
                    Text("${ChatPrefs.avatarSize} dp", fontSize = 12.sp, color = InkDim)
                }
                Slider(
                    value = ChatPrefs.avatarSize.toFloat(),
                    onValueChange = { ChatPrefs.avatarSize = it.toInt() },
                    valueRange = 24f..48f
                )
            }

            // 时间格式
            Card {
                Text("时间格式", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = InkDark)
                Spacer(Modifier.height(10.dp))
                SegRow(listOf("24 小时" to 0, "12 小时" to 1), ChatPrefs.displayMode) {
                    ChatPrefs.displayMode = it
                }
            }

            Spacer(Modifier.height(28.dp))
        }
    }
}

private fun shapeOf(style: Int) = when (style) {
    0 -> RoundedCornerShape(20.dp)
    1 -> RoundedCornerShape(8.dp)
    else -> RoundedCornerShape(4.dp)
}

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 6.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(CardBg)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        content = content
    )
}

@Composable
private fun SegRow(items: List<Pair<String, Int>>, current: Int, onPick: (Int) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items.forEach { (label, value) ->
            val on = current == value
            Box(
                Modifier.clip(RoundedCornerShape(12.dp))
                    .background(if (on) Accent.copy(alpha = 0.14f) else PageBg)
                    .padding(horizontal = 14.dp, vertical = 8.dp)
                    .tapable { onPick(value) }
            ) {
                Text(
                    label, fontSize = 13.sp,
                    color = if (on) Accent else InkDim,
                    fontWeight = if (on) FontWeight.Medium else FontWeight.Normal
                )
            }
        }
    }
}

@Composable
private fun Toggle(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, fontSize = 14.sp, color = InkDark)
        Spacer(Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun Line() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0xFFF0F1F5)))
}
