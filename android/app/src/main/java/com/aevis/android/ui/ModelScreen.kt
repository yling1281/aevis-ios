package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.ModelPrefs
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 模型选择页（2026-11-15）。
 *
 * 用户：「模型状态的话，你这个切换的话，你要单独做一个二级菜单，而不是在上面只是做一个按钮」。
 * 所以顶栏那个小标签只显示**上下文用量**，模型切换在这里 —— 完整的列表、在线状态、单价。
 *
 * 列表数据走 `Api.modelList()`（内部拼了 `/v1/llm/models` 的定价和 `/v1/llm/status` 的可用率）。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun ModelScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var rows by remember { mutableStateOf<List<Api.ModelInfo>?>(null) }
    // R-07：跟着 ModelPrefs.version 走，别用一次性快照
    val mpVer = ModelPrefs.version
    var cur by remember(mpVer) { mutableStateOf(ModelPrefs.current()) }
    var err by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        rows = withContext(Dispatchers.IO) {
            runCatching { Api.modelList() }.getOrElse { emptyList() }
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "模型", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Text(
                tr("默认用哪个模型聊天。绿点是在线，可用率来自最近的探测记录。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.45f), lineHeight = 16.sp,
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
            )
            Spacer(Modifier.height(8.dp))

            val list = rows
            when {
                list == null -> Box(
                    Modifier.fillMaxWidth().padding(top = 60.dp),
                    contentAlignment = Alignment.Center
                ) { Text(tr("正在读取…"), fontSize = 13.sp, color = ink.copy(alpha = 0.4f)) }

                list.isEmpty() -> Box(
                    Modifier.fillMaxWidth().padding(top = 60.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(tr("没拿到模型列表"), fontSize = V2.body)
                        Spacer(Modifier.height(6.dp))
                        Text(tr("检查网络，或稍后再进"),
                            fontSize = V2.tiny, color = ink.copy(alpha = 0.42f))
                    }
                }

                else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                    list.take(40).forEachIndexed { i, m ->
                        if (i > 0) Box(
                            Modifier.fillMaxWidth().height(0.5.dp)
                                .background(ink.copy(alpha = 0.07f))
                        )
                        val on = m.id == cur
                        Row(
                            Modifier.fillMaxWidth()
                                .tapable { cur = m.id; ModelPrefs.set(m.id) }
                                .padding(horizontal = V2.gutter, vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(
                                Modifier.size(8.dp).clip(CircleShape)
                                    .background(
                                        if (m.online) Color(0xFF4CAF50)
                                        else ink.copy(alpha = 0.18f)
                                    )
                            )
                            Spacer(Modifier.width(11.dp))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    Api.shortLabel(m.id), fontSize = V2.body,
                                    fontWeight = if (on) FontWeight.Medium else FontWeight.Normal
                                )
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    buildString {
                                        append(m.id)
                                        append(" · ")
                                        append(if (m.online) "在线" else "可能不可用")
                                        append(" · 可用率 ")
                                        append(String.format(java.util.Locale.US, "%.1f%%", m.uptime))
                                        if (m.points > 0) {
                                            append(" · 约 ")
                                            append(String.format(java.util.Locale.US, "%.2f", m.points))
                                            append(" 墨点/次")
                                        }
                                    },
                                    fontSize = 11.sp, color = ink.copy(alpha = 0.42f)
                                )
                            }
                            if (on) {
                                Icon(
                                    painterResource(R.drawable.ic_check), contentDescription = "当前模型",
                                    tint = V2.accent, modifier = Modifier.size(16.dp)
                                )
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}
