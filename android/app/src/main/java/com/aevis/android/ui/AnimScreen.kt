package com.aevis.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.AnimPrefs
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.ThemePrefs

/**
 * 外观与动效（2026-11-15 起叫「动效手感」，2026-11-16 扩成现在这样）。
 *
 * 用户：「我想变成浅色模式，不知道怎么变，你没开那个开关」——
 * 所以最上面加**主题**三档；下面三个动效滑杆原样保留（视频解不了，
 * 曲线只能靠参数逼近，干脆让用户自己调）。
 *
 * 每一项都是**改完立刻生效**：主题走 `ThemePrefs.version` 触发整树重组，
 * 动效参数在 `tapable` / 转场里现读。
 */
@Composable
fun AnimScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var themeMode by remember { mutableIntStateOf(ThemePrefs.mode) }
    var press by remember { mutableStateOf(AnimPrefs.pressPct) }
    var shift by remember { mutableStateOf(AnimPrefs.shiftDp) }
    var bounce by remember { mutableStateOf(AnimPrefs.bouncePct) }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "外观与动效", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            // ---------- 主题 ----------
            SectionLabel(tr("主题"))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                // 三档都是"选中 = 淡主色底 + 主色描边"，跟聊天外观页那三个气泡形状一个样式
                listOf(
                    ThemePrefs.FOLLOW_SYSTEM to tr("跟随系统"),
                    ThemePrefs.LIGHT to tr("浅色"),
                    ThemePrefs.DARK to tr("深色")
                ).forEach { (m, label) ->
                    val on = themeMode == m
                    Column(
                        Modifier.weight(1f)
                            .clip(squircle(14.dp))
                            .background(
                                if (on) V2.accent.copy(alpha = 0.10f) else ink.copy(alpha = 0.04f)
                            )
                            .then(
                                if (on) Modifier.border(1.5.dp, V2.accent, squircle(14.dp))
                                else Modifier
                            )
                            .tapable {
                                // 写盘 + 更新本地 state；写盘会 ++version，整棵树立刻换色
                                themeMode = m
                                ThemePrefs.mode = m
                            }
                            .padding(vertical = 13.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        // 主题的小缩略：半个月亮/太阳，比纯文字直观
                        Box(
                            Modifier.size(22.dp).clip(squircle(7.dp))
                                .background(
                                    when (m) {
                                        ThemePrefs.LIGHT -> V2.bgLight
                                        ThemePrefs.DARK -> V2.bgDark
                                        // 跟随系统：一半深一半浅，一眼就知道"看系统"
                                        else -> V2.bgLight
                                    }
                                )
                                .then(
                                    if (m == ThemePrefs.FOLLOW_SYSTEM) {
                                        Modifier.background(
                                            androidx.compose.ui.graphics.Brush.verticalGradient(
                                                listOf(V2.bgLight, V2.bgLight, V2.bgDark, V2.bgDark)
                                            )
                                        )
                                    } else Modifier
                                )
                                .then(
                                    Modifier.border(
                                        0.8.dp,
                                        ink.copy(alpha = 0.18f),
                                        squircle(7.dp)
                                    )
                                )
                        )
                        Spacer(Modifier.height(7.dp))
                        Text(
                            label, fontSize = 11.5.sp,
                            color = if (on) V2.accent else ink.copy(alpha = 0.6f)
                        )
                    }
                }
            }
            Text(
                tr("「跟随系统」会跟着手机的深色开关走。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.38f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 8.dp)
            )

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 动效 ----------
            SectionLabel(tr("动效"))
            Text(
                tr("觉得生硬就调这里：越往左越轻，越往右越弹。改完立刻生效。"),
                fontSize = 12.sp, color = ink.copy(alpha = 0.42f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
            )

            SliderRow("按压缩放", "%.2f".format(press / 100f), press.toFloat(), 80f, 100f,
                ink) { press = it.toInt(); AnimPrefs.pressPct = press }
            SliderRow("上浮位移", "$shift dp", shift.toFloat(), 0f, 40f, ink) {
                shift = it.toInt(); AnimPrefs.shiftDp = shift
            }
            SliderRow("回弹力度", "%.2f".format(bounce / 100f), bounce.toFloat(), 25f, 90f,
                ink) { bounce = it.toInt(); AnimPrefs.bouncePct = bounce }

            Spacer(Modifier.height(8.dp))
            Text(
                tr("提示：回弹力度越小越像果冻，0.45 左右比较自然；0.90 就基本不弹了。"),
                fontSize = 11.sp, color = ink.copy(alpha = 0.32f),
                modifier = Modifier.padding(horizontal = V2.gutter)
            )
            Spacer(Modifier.height(28.dp))
        }
    }
}

/** 区块标题（跟聊天外观页同一个观感）。*/
@Composable
private fun SectionLabel(text: String) {
    Text(
        text, fontSize = V2.sub, fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        modifier = Modifier.padding(start = V2.gutter, end = V2.gutter, top = 6.dp, bottom = 8.dp)
    )
}

@Composable
private fun SliderRow(
    name: String, value: String, v: Float, from: Float, to: Float,
    ink: androidx.compose.ui.graphics.Color, onChange: (Float) -> Unit
) {
    Column(Modifier.padding(horizontal = V2.gutter, vertical = 10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(name, fontSize = 14.sp, color = ink.copy(alpha = 0.72f))
            Spacer(Modifier.weight(1f))
            Text(value, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        }
        Slider(value = v, onValueChange = onChange, valueRange = from..to)
    }
}
