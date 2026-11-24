package com.aevis.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 更新日志（2026-11-16，104）。
 *
 * 数据全部来自 `GET /v1/app/changelog`，**客户端不写死任何文案** ——
 * team-lead 以后发版只改服务端 `app_changelog.json`，用户不用更新 App 就能看到。
 * 展示：按版本**倒序**（接口顺序为准，服务端已按新→旧给），版本号 + 日期 + 每条一行 `·`。
 */
@Composable
fun ChangeLogScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var logs by remember { mutableStateOf<List<Api.ChangeLog>?>(null) }

    LaunchedEffect(Unit) {
        logs = withContext(Dispatchers.IO) {
            runCatching { Api.changeLog() }.getOrDefault(emptyList())
        }
    }

    // 用 SubPageHeader 而不是 Pages.kt 里的 PageScaffold（那是 private 的）
    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = tr("更新日志"), onBack = onBack)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            val items = logs
            when {
                items == null -> Box(
                    Modifier.fillMaxWidth().padding(vertical = 60.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        tr("正在加载…"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f)
                    )
                }
                items.isEmpty() -> Box(
                    Modifier.fillMaxWidth().padding(vertical = 60.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        tr("还没有更新日志"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f)
                    )
                }
                else -> items.forEach { lg ->
                    V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 5.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "v${lg.version.ifBlank { "—" }}",
                                fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                                fontFamily = FontFamily.Monospace
                            )
                            Spacer(Modifier.weight(1f))
                            if (lg.date.isNotBlank()) {
                                Text(
                                    lg.date, fontSize = 11.sp,
                                    color = ink.copy(alpha = 0.4f)
                                )
                            }
                        }
                        Spacer(Modifier.height(7.dp))
                        lg.items.forEach { line ->
                            Row(Modifier.padding(vertical = 1.dp)) {
                                Text(
                                    "·", fontSize = 12.sp,
                                    color = ink.copy(alpha = 0.35f)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    line, fontSize = 12.5.sp, lineHeight = 19.sp,
                                    color = ink.copy(alpha = 0.75f)
                                )
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
        }
    }
}
