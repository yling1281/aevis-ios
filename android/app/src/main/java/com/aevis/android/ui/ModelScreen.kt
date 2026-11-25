package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
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
import java.util.Locale

/**
 * 模型选择页（2026-11-15，2026-11-24 状态展示重做）。
 *
 * 用户：「模型状态你不能只有一个小圆点 —— 应该能看到历史记录，也能看到当前状态」。
 * 所以这里每行：
 *   · 一条 **12dp 高的竖条历史**（近 30 分钟 recent / 近 24 小时 history，绿正常红异常灰没数据）；
 *   · 一颗 **四态胶囊**（正常 / 波动 / 异常 / 未监控），来自 providers[].alive + 官方状态；
 *   · 单价、可用率、平均响应、覆盖说明。
 *
 * 数据来源 `/v1/models/status`（官网/iOS 同源，无需 token），失败时用 relayStatus 缓存兜底，
 * 不白屏、不造假数据（没探测数据就画灰条 + 写"暂无探测数据"）。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun ModelScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var rows by remember { mutableStateOf<List<Api.ModelInfo>?>(null) }
    // 2026-11-24：新状态（按 model id 索引）；空 = 还没取到 / 接口失败
    var statusById by remember { mutableStateOf<Map<String, Api.ModelStatus>>(emptyMap()) }
    // R-07：跟着 ModelPrefs.version 走，别用一次性快照
    val mpVer = ModelPrefs.version
    var cur by remember(mpVer) { mutableStateOf(ModelPrefs.current()) }

    LaunchedEffect(Unit) {
        val (models, statusMap) = withContext(Dispatchers.IO) {
            val models = runCatching { Api.modelList() }.getOrDefault(emptyList())
            // 状态：优先 /v1/models/status；失败退回 relayStatus 缓存（不造假）
            val sm = HashMap<String, Api.ModelStatus>()
            val fresh = runCatching { Api.modelsStatus() }.getOrNull()
            if (fresh != null) {
                fresh.forEach { sm[it.model] = it }
            } else {
                // 兜底：relayStatus 的 beats（近 24 小时 50 槽）转成同款状态行
                runCatching { Api.relayStatus() }.getOrNull().orEmpty().forEach { r ->
                    val samples = r.beats.map { it == 1 }
                    val st = if (samples.isEmpty()) Api.ModelStatus.UNKNOWN
                             else if (r.uptime24 == null) Api.ModelStatus.UNKNOWN
                             else if (r.uptime24 >= 0.95) Api.ModelStatus.OK
                             else if (r.uptime24 >= 0.8) Api.ModelStatus.UNSTABLE
                             else Api.ModelStatus.DOWN
                    sm[r.model] = Api.ModelStatus(
                        model = r.model, state = st, samples = samples,
                        rangeLabel = "近 24 小时", rate = r.uptime24 ?: 0.0,
                        avgLatencySec = r.ping?.let { it / 1000.0 },
                        recentSource = "", coverageMinutes = 0,
                        officialState = "", officialDetail = ""
                    )
                }
            }
            Pair(models, sm)
        }
        rows = models
        statusById = statusMap
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
                tr("竖条是最近的探测历史（绿正常 / 红异常 / 灰没数据）；右侧是当前状态。"),
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
                        val st = statusById[m.id]
                        Row(
                            Modifier.fillMaxWidth()
                                .tapable { cur = m.id; ModelPrefs.set(m.id) }
                                .padding(horizontal = V2.gutter, vertical = 13.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        Api.shortLabel(m.id), fontSize = V2.body,
                                        fontWeight = if (on) FontWeight.Medium else FontWeight.Normal,
                                        color = if (on) V2.accent else ink,
                                        // 2026-11-25：长模型名不换行、不吃掉右侧状态区
                                        maxLines = 1
                                    )
                                    if (on) {
                                        Spacer(Modifier.width(6.dp))
                                        Icon(
                                            painterResource(R.drawable.ic_check),
                                            contentDescription = "当前模型",
                                            tint = V2.accent, modifier = Modifier.size(14.dp)
                                        )
                                    }
                                }
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    buildString {
                                        append(m.id)
                                        if (m.points > 0) {
                                            append(" · 约 ")
                                            append(String.format(Locale.US, "%.2f", m.points))
                                            append(" 墨点/次")
                                        }
                                    },
                                    fontSize = 11.sp, color = ink.copy(alpha = 0.42f),
                                    maxLines = 1
                                )
                                // 覆盖 / 平均响应（有才显示）
                                if (st != null && (st.coverageMinutes > 0 || st.avgLatencySec != null)) {
                                    Spacer(Modifier.height(2.dp))
                                    Text(
                                        buildString {
                                            if (st.coverageMinutes > 0) {
                                                append(tr("覆盖 %d 分钟", st.coverageMinutes))
                                            }
                                            if (st.avgLatencySec != null) {
                                                if (isNotEmpty()) append(" · ")
                                                append(tr("平均响应 %.1f 秒", st.avgLatencySec))
                                            }
                                            if (st.recentSource == "provider_aggregate" && isNotEmpty()) {
                                                append(" · ")
                                                append(tr("聚合探测"))
                                            }
                                        },
                                        fontSize = 10.sp, color = ink.copy(alpha = 0.35f),
                                        maxLines = 1
                                    )
                                }
                            }

                            Spacer(Modifier.width(10.dp))

                            // 右：当前状态胶囊（四态）+ 历史竖条
                            Column(horizontalAlignment = Alignment.End) {
                                StatePill(st)
                                Spacer(Modifier.height(6.dp))
                                StatusBars(st)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

/**
 * 四态当前状态胶囊。位置：本文件 [StatePill]。
 * 口径（Api.modelsStatus 已算好 state）：
 *   OK=正常(绿) / UNSTABLE=波动(橙) / DOWN=异常(红) / UNKNOWN=未监控(灰)。
 * 官方状态（stale=false）作为 detail 附在后面，不单独成态。
 */
@Composable
private fun StatePill(st: Api.ModelStatus?) {
    // 2026-11-25：四态颜色按明暗主题各给一支，保证深色底下也读得清。
    val dark = isDarkTheme()
    val (text, color) = when (st?.state ?: Api.ModelStatus.UNKNOWN) {
        Api.ModelStatus.OK -> tr("正常") to if (dark) Color(0xFF5FD89A) else Color(0xFF218A4E)
        Api.ModelStatus.UNSTABLE -> tr("波动") to if (dark) Color(0xFFF0B45A) else Color(0xFFB36A12)
        Api.ModelStatus.DOWN -> tr("异常") to if (dark) Color(0xFFFF7B70) else Color(0xFFC9352A)
        else -> tr("未监控") to MaterialTheme.colorScheme.onSurface.copy(
            alpha = if (dark) 0.5f else 0.42f
        )
    }
    Column(horizontalAlignment = Alignment.End) {
        Text(
            text, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = color,
            maxLines = 1,
            modifier = Modifier.clip(squircle(7.dp))
                .background(color.copy(alpha = if (dark) 0.18f else 0.13f))
                .padding(horizontal = 9.dp, vertical = 3.dp)
        )
        if (st != null && st.officialState.isNotBlank()) {
            Spacer(Modifier.height(3.dp))
            Text(
                st.officialDetail.ifBlank { st.officialState },
                fontSize = 9.5.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
                maxLines = 1
            )
        }
    }
}

/**
 * 历史竖条（12dp 高、每格宽约 3dp）。
 * 绿=正常 / 红=异常 / 灰=没数据（samples 空 → 画一条灰占位并写「暂无探测数据」）。
 * 位置：本文件 [StatusBars]，画法参考 SettingsMoreScreen 的 RelayModel.beats。
 */
@Composable
private fun StatusBars(st: Api.ModelStatus?) {
    val samples = st?.samples.orEmpty()
    val ink = MaterialTheme.colorScheme.onSurface
    val dark = isDarkTheme()
    if (samples.isEmpty()) {
        Text(
            tr("暂无探测数据"), fontSize = 9.5.sp,
            color = ink.copy(alpha = if (dark) 0.4f else 0.32f),
            modifier = Modifier.padding(top = 2.dp)
        )
        return
    }
    val green = if (dark) Color(0xFF5FD89A) else Color(0xFF3FBF6F)
    val red = if (dark) Color(0xFFFF7B70) else Color(0xFFE05A4E)
    // 2026-11-25：窄屏自适应宽度（WebView 里窄机型不溢出）；最多 78dp，至少 44dp
    val w = with(androidx.compose.ui.platform.LocalDensity.current) {
        val maxW = 78.dp.toPx()
        val minW = 44.dp.toPx()
        val avail = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp.dp.toPx() * 0.22f
        avail.coerceIn(minW, maxW).toDp()
    }
    Canvas(Modifier.size(width = w, height = 12.dp)) {
        val n = samples.size.coerceAtLeast(1)
        val gap = 1f
        val bw = ((size.width - gap * (n - 1)) / n).coerceAtLeast(1f)
        for (i in 0 until n) {
            val ok = samples[i]
            val h = if (ok) size.height else size.height * 0.55f
            drawRoundRect(
                // 2026-11-25 修：异常格必须画红，之前无论 ok 都画绿（用户看不到异常）
                color = if (ok) green else red,
                topLeft = Offset(i * (bw + gap), size.height - h),
                size = Size(bw, h),
                cornerRadius = CornerRadius(1f, 1f)
            )
        }
    }
    // 红格数量用一行小字点出来（具体哪几格异常看上面颜色）
    val bad = samples.count { !it }
    if (bad > 0) {
        Text(
            tr("%d 次异常", bad), fontSize = 9.sp,
            color = red, modifier = Modifier.padding(top = 2.dp)
        )
    }
}
