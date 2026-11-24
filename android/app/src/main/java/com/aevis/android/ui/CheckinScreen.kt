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
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 签到（2026-11-15）。
 *
 * 用户：「朋友圈签到、群聊广场这些你都没有做」—— 先从签到开始，最小可验证。
 *
 * 版式照忆伴那张：
 *   大数字（连续天数）+ 累计墨点 → 本周 7 个圆 → 说明 → 签到按钮
 */
@Composable
fun CheckinScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var done by remember { mutableStateOf(false) }
    var streak by remember { mutableIntStateOf(0) }
    var monthCount by remember { mutableIntStateOf(0) }
    var total by remember { mutableIntStateOf(0) }
    var days by remember { mutableStateOf<List<String>>(emptyList()) }
    var nextReward by remember { mutableIntStateOf(1) }
    var busy by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }

    suspend fun load() {
        val st = withContext(Dispatchers.IO) {
            runCatching { Api.checkinStatus() }.getOrNull()
        } ?: return
        done = st.done
        streak = st.streak
        monthCount = st.monthCount
        total = st.totalPoints
        days = st.days
        nextReward = st.nextReward
    }

    LaunchedEffect(Unit) { load() }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "签到", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            // ---- 主卡：大数字 ----
            V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)) {
                Column(
                    Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        if (done) tr("今天已签到") else tr("今天还没签"),
                        fontSize = 12.5.sp, color = ink.copy(alpha = 0.45f)
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            "$streak", fontSize = 44.sp, fontWeight = FontWeight.Bold,
                            color = V2.accent, letterSpacing = (-1.5).sp
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            tr("天连续"), fontSize = 13.sp,
                            color = ink.copy(alpha = 0.5f),
                            modifier = Modifier.padding(bottom = 9.dp)
                        )
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        tr("本月已签 %d 天 · 累计 %d 墨点", monthCount, total),
                        fontSize = 11.5.sp, color = ink.copy(alpha = 0.42f)
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            // ---- 本周 ----
            Text(tr("本周"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    val names = listOf("一", "二", "三", "四", "五", "六", "日")
                    val cal = java.util.Calendar.getInstance()
                    // 本周一为起点
                    val dow = cal.get(java.util.Calendar.DAY_OF_WEEK)
                    val offset = if (dow == java.util.Calendar.SUNDAY) 6 else dow - 2
                    cal.add(java.util.Calendar.DAY_OF_MONTH, -offset)
                    val fmt = java.text.SimpleDateFormat("dd", java.util.Locale.US)
                    names.forEachIndexed { i, nm ->
                        val d = fmt.format(cal.time)
                        val signed = days.contains(d)
                        val isToday = i == offset
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(
                                Modifier.size(36.dp).clip(CircleShape)
                                    .background(
                                        when {
                                            signed -> V2.accent
                                            isToday -> V2.accent.copy(alpha = 0.16f)
                                            else -> ink.copy(alpha = 0.05f)
                                        }
                                    ),
                                contentAlignment = Alignment.Center
                            ) {
                                if (signed) {
                                    Icon(
                                        painterResource(R.drawable.ic_check), contentDescription = "已打卡",
                                        tint = Color.White, modifier = Modifier.size(15.dp)
                                    )
                                } else {
                                    Text(nm, fontSize = 12.sp,
                                        color = if (isToday) V2.accent
                                        else ink.copy(alpha = 0.38f))
                                }
                            }
                            Spacer(Modifier.height(5.dp))
                            Text(
                                d, fontSize = 10.sp,
                                color = ink.copy(alpha = 0.32f)
                            )
                        }
                        cal.add(java.util.Calendar.DAY_OF_MONTH, 1)
                    }
                }
            }

            Spacer(Modifier.height(14.dp))

            // ---- 签到按钮 ----
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .clip(RoundedCornerShape(15.dp))
                    .background(
                        when {
                            done -> ink.copy(alpha = 0.07f)
                            busy -> ink.copy(alpha = 0.10f)
                            else -> V2.accent
                        }
                    )
                    .tapable {
                        if (done || busy) return@tapable
                        busy = true
                        note = ""
                    }
                    .padding(vertical = 15.dp),
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    when {
                        busy -> tr("签到中…")
                        done -> tr("今天已签到，明天再来")
                        else -> tr("签到领 %d 墨点", nextReward)
                    },
                    fontSize = 15.sp, fontWeight = FontWeight.Medium,
                    color = if (done || busy) ink.copy(alpha = 0.4f) else Color.White
                )
            }

            LaunchedEffect(busy) {
                if (!busy) return@LaunchedEffect
                val r = withContext(Dispatchers.IO) {
                    runCatching { Api.checkin() }.getOrNull()
                }
                if (r == null) {
                    note = "签到失败，检查网络"
                } else if (r.already) {
                    note = "今天已经签过了"
                } else {
                    note = "签到成功，+${r.points} 墨点"
                }
                // ⚠️ 顺序很重要：`load()` 必须在 `busy = false` **之前**。
                //    LaunchedEffect 的 key 是 `busy`，先设 false 会把当前协程直接取消，
                //    后面的 load() 根本跑不到 —— 表现就是「提示成功但数字还是 0」。
                load()
                busy = false
            }

            if (note.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                Text(
                    note, fontSize = 12.5.sp, color = V2.accent,
                    modifier = Modifier.padding(horizontal = V2.gutter)
                )
            }

            Spacer(Modifier.height(V2.sectionGap))
            Text(
                tr("连续签到奖励会递增：1 → 2 → 3 → 5 → 8 墨点，断签从 1 重新开始。"),
                fontSize = 11.sp, color = ink.copy(alpha = 0.34f), lineHeight = 15.sp,
                modifier = Modifier.padding(horizontal = V2.gutter)
            )

            Spacer(Modifier.height(34.dp))
        }
    }
}
