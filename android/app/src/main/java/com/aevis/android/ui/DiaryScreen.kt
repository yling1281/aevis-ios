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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.DiaryStore
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 日记页（2026-11-15）。
 *
 * 按忆伴的 `DiaryActivity` 那种排法：时间倒序，一条是一张卡片，
 * 头像是写这篇的角色，标题是日期，正文两三行。
 *
 * 内容由 `DiaryStore` 在**打开 App 时**自动补写（今天聊过、还没写，就写一篇）。
 */
@Composable
fun DiaryScreen(onBack: () -> Unit, onlyPid: String? = null) {
    val ink = MaterialTheme.colorScheme.onSurface
    var tab by remember { mutableIntStateOf(0) }          // 0 日记 / 1 周记
    var rows by remember { mutableStateOf<List<DiaryStore.Entry>?>(null) }
    var persons by remember { mutableStateOf<List<Api.Persona>>(emptyList()) }
    var expanded by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    fun reload() {
        rows = DiaryStore.list(pid = onlyPid, kind = if (tab == 0) "day" else "week")
    }

    LaunchedEffect(Unit) {
        persons = withContext(Dispatchers.IO) {
            runCatching { Api.personas() }.getOrElse { emptyList() }
        }
        reload()
    }
    LaunchedEffect(tab) { reload() }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 顶栏（2026-11-16）：走公共 `SubPageHeader`，右侧「补写今天的」原样搬进 trailing，
        // 一个功能都不能丢
        SubPageHeader(
            title = "日记",
            onBack = onBack,
            trailing = {
                if (busy) {
                    Text(tr("正在写…"), fontSize = 12.sp, color = ink.copy(alpha = 0.4f))
                } else {
                    Text(
                        tr("补写今天的"), fontSize = 12.5.sp, color = V2.accent,
                        modifier = Modifier.tapable {
                            busy = true
                        }.padding(4.dp)
                    )
                }
            }
        )

        // 补写：给今天聊过但还没写的人各写一篇
        LaunchedEffect(busy) {
            if (busy) {
                withContext(Dispatchers.IO) { DiaryStore.catchUp(persons) }
                reload()
                busy = false
            }
        }

        // 日记 / 周记
        Row(
            Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
                .clip(squircle(12.dp))
                .background(ink.copy(alpha = 0.05f))
                .padding(3.dp)
        ) {
            listOf(tr("日记"), tr("周记")).forEachIndexed { i, label ->
                Text(
                    label, fontSize = 13.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    color = if (tab == i) ink else ink.copy(alpha = 0.45f),
                    fontWeight = if (tab == i) FontWeight.Medium else FontWeight.Normal,
                    modifier = Modifier.clip(RoundedCornerShape(10.dp))
                        .background(if (tab == i) MaterialTheme.colorScheme.surface
                        else androidx.compose.ui.graphics.Color.Transparent)
                        .tapable { tab = i }
                        .padding(horizontal = 22.dp, vertical = 7.dp)
                )
            }
        }

        Spacer(Modifier.height(8.dp))

        val list = rows
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            when {
                list == null -> {}
                list.isEmpty() -> {
                    Box(
                        Modifier.fillMaxWidth().padding(top = 70.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(tr("还没有%s", if (tab == 0) tr("日记") else tr("周记")),
                                fontSize = V2.body, fontWeight = FontWeight.Medium)
                            Spacer(Modifier.height(6.dp))
                            Text(
                                if (tab == 0) tr("今天和谁聊过，它就会写一篇")
                                else tr("攒够三天的日记，周日会自动写周记"),
                                fontSize = V2.tiny, color = ink.copy(alpha = 0.42f)
                            )
                        }
                    }
                }
                else -> list.forEach { e ->
                    val open = expanded == (e.pid + e.date)
                    V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Avatar("", e.name, 34.dp)
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(e.name, fontSize = V2.body,
                                    fontWeight = FontWeight.Medium)
                                Text(e.date, fontSize = V2.micro,
                                    color = ink.copy(alpha = 0.4f))
                            }
                            Text(
                                if (open) tr("收起") else tr("展开"),
                                fontSize = 12.sp, color = V2.accent
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        // 导入了手写体就用它渲染正文；没导入就用系统字体
                        val family = remember {
                            val f = com.aevis.android.core.FontStore.currentFile()
                            if (f.exists()) runCatching {
                                androidx.compose.ui.text.font.FontFamily(
                                    androidx.compose.ui.text.font.Font(f)
                                )
                            }.getOrNull() else null
                        }
                        Text(
                            e.content,
                            fontSize = 14.sp, lineHeight = 22.sp,
                            maxLines = if (open) Int.MAX_VALUE else 5,
                            color = ink.copy(alpha = 0.82f),
                            fontFamily = family
                        )
                    }
                }
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}
