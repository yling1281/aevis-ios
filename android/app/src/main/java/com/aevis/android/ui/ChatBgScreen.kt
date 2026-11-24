package com.aevis.android.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.BackgroundStore
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.I18n.tr

/**
 * 聊天背景设置（2026-11-15）。
 *
 * 用户：「背景自定义和玻璃的那些」「自定义背景图，整体背景图，还有这个聊天记录背景图」。
 *
 * 支持：
 *   · 纯色 / 渐变（预设几套）/ 相册选图
 *   · 模糊强度（0–24，深度模糊要 Android 12+，低版本自动降级成半透明）
 *   · 遮罩浓度（图太亮压暗一点，文字才看得清）
 *
 * ⚠️ 上一版这里点不动，是因为 `onOpenBackground` 是个空 lambda —— 路由压根没传。
 */
@Composable
fun ChatBgScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current

    var kind by remember { mutableIntStateOf(ChatPrefs.bgKind) }
    var blur by remember { mutableIntStateOf(ChatPrefs.bgBlur) }
    var dim by remember { mutableIntStateOf(ChatPrefs.bgDim) }
    var preset by remember { mutableIntStateOf(ChatPrefs.bgPreset) }
    var imgVer by remember { mutableIntStateOf(0) }
    val imgPath = ChatPrefs.bgImagePath

    val pick = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val ok = BackgroundStore.import(ctx, uri)
        if (ok) {
            kind = 1
            ChatPrefs.bgKind = 1
            imgVer++
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "聊天背景", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            // ---- 预览 ----
            // 116：预览底色跟主题走（原来写死米白，深色模式下是一块发光的白板）
            Box(
                Modifier.fillMaxWidth().height(150.dp)
                    .padding(horizontal = V2.gutter)
                    .clip(squircle(V2.cardRadius))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
            ) {
                BackgroundStore.renderBg(ctx, kind, preset, blur, dim, imgVer,
                    Modifier.fillMaxSize())
                // 叠两条假气泡看效果
                Column(Modifier.fillMaxSize().padding(12.dp)) {
                    Box(
                        Modifier.clip(RoundedCornerShape(14.dp))
                            // 116：示例气泡底色用 surface（白卡/深卡自动切换），
                            // 写死白底时深色模式下是"白底白字"
                            .background(
                                MaterialTheme.colorScheme.surface.copy(alpha = 0.88f)
                            )
                            .padding(horizontal = 10.dp, vertical = 7.dp)
                    ) { Text(tr("这样看得清吗"), fontSize = 13.sp) }
                    Spacer(Modifier.height(8.dp))
                    Box(
                        Modifier.align(Alignment.End)
                            .clip(RoundedCornerShape(14.dp))
                            .background(V2.accent.copy(alpha = 0.88f))
                            .padding(horizontal = 10.dp, vertical = 7.dp)
                    ) { Text(tr("挺清楚的"), fontSize = 13.sp, color = Color.White) }
                }
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---- 背景类型 ----
            Text(tr("背景"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                listOf(tr("纯色"), tr("图片"), tr("渐变")).forEachIndexed { i, label ->
                    val on = kind == i
                    Box(
                        Modifier.weight(1f)
                            .clip(squircle(12.dp))
                            .background(if (on) V2.accent.copy(alpha = 0.12f)
                            else ink.copy(alpha = 0.05f))
                            .then(if (on) Modifier.border(1.5.dp, V2.accent,
                                squircle(12.dp)) else Modifier)
                            .tapable {
                                kind = i
                                ChatPrefs.bgKind = i
                            }
                            .padding(vertical = 11.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(label, fontSize = 13.sp,
                            color = if (on) V2.accent else ink.copy(alpha = 0.6f))
                    }
                }
            }

            // 选图
            if (kind == 1) {
                Spacer(Modifier.height(10.dp))
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                        .clip(RoundedCornerShape(13.dp))
                        .background(V2.accent)
                        .tapable { pick.launch(arrayOf("image/*")) }
                        .padding(vertical = 13.dp),
                    horizontalArrangement = Arrangement.Center
                ) {
                    Text(
                        if (imgPath.isBlank()) tr("从相册选图") else tr("换一张"),
                        fontSize = 14.sp, color = Color.White,
                        fontWeight = FontWeight.Medium
                    )
                }
            }

            // 渐变预设
            if (kind == 2) {
                Spacer(Modifier.height(10.dp))
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = V2.gutter),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    BackgroundStore.presets.forEachIndexed { i, colors ->
                        val on = preset == i
                        Box(
                            Modifier.size(56.dp, 40.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(
                                    androidx.compose.ui.graphics.Brush.linearGradient(colors)
                                )
                                .then(if (on) Modifier.border(2.dp, V2.accent,
                                    RoundedCornerShape(10.dp)) else Modifier)
                                .tapable {
                                    preset = i
                                    ChatPrefs.bgPreset = i
                                }
                        )
                    }
                }
            }

            Spacer(Modifier.height(18.dp))

            // ---- 模糊 ----
            SettingRow(
                title = tr("模糊强度"),
                value = blur, range = 0f..24f, unit = "",
                onChange = { blur = it; ChatPrefs.bgBlur = it }
            )

            // ---- 遮罩 ----
            SettingRow(
                title = tr("遮罩浓度"),
                value = dim, range = 0f..60f, unit = "%",
                onChange = { dim = it; ChatPrefs.bgDim = it }
            )

            Spacer(Modifier.height(10.dp))
            Text(
                tr("提示：模糊在 Android 12 以上是真实背景模糊，低版本会自动降级，效果略浅。"),
                fontSize = 11.sp, color = ink.copy(alpha = 0.36f), lineHeight = 15.sp,
                modifier = Modifier.padding(horizontal = V2.gutter)
            )

            if (kind == 1 && imgPath.isNotBlank()) {
                Spacer(Modifier.height(14.dp))
                Text(
                    tr("移除背景图"), fontSize = 13.sp, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter)
                        .tapable {
                            BackgroundStore.clear(ctx)
                            kind = 0
                            ChatPrefs.bgKind = 0
                            imgVer++
                        }
                        .padding(vertical = 6.dp)
                )
            }

            Spacer(Modifier.height(34.dp))
        }
    }
}

@Composable
private fun SettingRow(
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
        androidx.compose.material3.Slider(
            value = value.toFloat(),
            onValueChange = { onChange(it.toInt()) },
            valueRange = range,
            colors = androidx.compose.material3.SliderDefaults.colors(
                thumbColor = V2.accent,
                activeTrackColor = V2.accent,
                inactiveTrackColor = ink.copy(alpha = 0.10f)
            ),
            modifier = Modifier.fillMaxWidth().height(34.dp)
        )
    }
}
