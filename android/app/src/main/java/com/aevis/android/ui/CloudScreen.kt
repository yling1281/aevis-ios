package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 云空间（2026-11-16）。
 *
 * 用户：「服务这里加一个云服务，默认每人 1 个 G 的空间，超了要自己买」。
 *
 * 这页只做**看**和**引导**：
 *   · 顶部一条用量条（超过 90% 变橙）
 *   · 三行明细：聊天记录备份 / 图片缓存 / 其他
 *   · 「扩容」先做成禁用态 —— 价格没定，**不编价格**
 *
 * 数据来自 `GET /v1/cloud/usage`；拿不到就显示 `—`（绝不显示 0，0 会让人以为空间用光）。
 */
@Composable
fun CloudScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = androidx.compose.ui.platform.LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    var usage by remember { mutableStateOf<Api.CloudUsage?>(null) }
    var loaded by remember { mutableStateOf(false) }
    // 本地图片缓存（这台机器上的）
    var busy by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var imgCount by remember { mutableIntStateOf(0) }
    var imgBytes by remember { mutableLongStateOf(0L) }
    // 恢复码（2026-11-16，119）
    var code by remember { mutableStateOf<String?>(null) }
    var showRecover by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            usage = runCatching { Api.cloudUsage() }.getOrNull()
            code = runCatching { Api.recoverCode() }.getOrNull()
            // 本地图片缓存 = SecureCache 的目录（加密缓存的所有图片，张数 + 字节数）
            runCatching {
                val dir = java.io.File(ctx.filesDir, "secure_cache")
                val files = dir.listFiles()?.filter { it.isFile } ?: emptyList()
                imgCount = files.size
                imgBytes = files.sumOf { it.length() }
            }
            loaded = true
        }
    }

    // 清理云备份二次确认（不可逆）
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(tr("清理云端备份？")) },
            text = {
                Text(
                    tr("云端那份聊天记录会被删掉，这台设备上的记录不受影响。"),
                    fontSize = V2.sub, lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    busy = true
                    scope.launch {
                        val ok = withContext(Dispatchers.IO) { runCatching { Api.deleteBackup() }.getOrDefault(false) }
                        usage = withContext(Dispatchers.IO) { runCatching { Api.cloudUsage() }.getOrNull() }
                        busy = false
                        android.widget.Toast.makeText(
                            ctx, if (ok) "已清理" else "清理失败",
                            android.widget.Toast.LENGTH_SHORT
                        ).show()
                    }
                }) { Text(tr("清理"), color = V2.alert) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClear = false }) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "云空间", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            // ---------- 恢复码（2026-11-16，119）----------
            // 换手机 / 重装后，只要这串码就能把聊天记录拉回来（不依赖登录态）。
            V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            tr("恢复码"), fontSize = 12.sp,
                            color = ink.copy(alpha = 0.45f)
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            if (code.isNullOrBlank()) "····-····" else code.orEmpty(),
                            fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            letterSpacing = 2.sp
                        )
                    }
                    Text(
                        tr("复制"),
                        fontSize = 12.sp, fontWeight = FontWeight.Medium,
                        color = V2.accent,
                        modifier = Modifier
                            .clip(squircle(9.dp))
                            .background(V2.accent.copy(alpha = 0.12f))
                            .tapable(enabled = !code.isNullOrBlank()) {
                                runCatching {
                                    val cm = ctx.getSystemService(
                                        android.content.Context.CLIPBOARD_SERVICE
                                    ) as android.content.ClipboardManager
                                    cm.setPrimaryClip(
                                        android.content.ClipData.newPlainText(
                                            "Aevis 恢复码", code.orEmpty()
                                        )
                                    )
                                    android.widget.Toast.makeText(
                                        ctx, "已复制恢复码", android.widget.Toast.LENGTH_SHORT
                                    ).show()
                                }
                            }
                            .padding(horizontal = 10.dp, vertical = 6.dp)
                    )
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    tr("换手机或重装后，用这串码就能把聊天记录拉回来"),
                    fontSize = V2.micro, color = ink.copy(alpha = 0.45f), lineHeight = 16.sp
                )
            }

            // ---------- 用量条 ----------
            V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)) {
                val u = usage
                val used = u?.used ?: -1L
                val quota = u?.quota ?: 0L
                val pct = if (quota > 0) (used.toFloat() / quota).coerceIn(0f, 1f) else 0f
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        if (used >= 0) fmtSize(used) else "—",
                        fontSize = 26.sp, fontWeight = FontWeight.Bold,
                        color = ink, letterSpacing = (-0.5).sp
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        "/ " + (if (quota > 0) fmtSize(quota) else "—"),
                        fontSize = 13.sp, color = ink.copy(alpha = 0.45f),
                        modifier = Modifier.padding(bottom = 5.dp)
                    )
                    Spacer(Modifier.weight(1f))
                    if (loaded && u != null) {
                        Text(
                            String.format(java.util.Locale.US, "%.1f%%", pct * 100),
                            fontSize = 12.sp, color = ink.copy(alpha = 0.42f),
                            modifier = Modifier.padding(bottom = 5.dp)
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
                Box(
                    Modifier.fillMaxWidth().height(7.dp)
                        .clip(squircle(4.dp))
                        .background(ink.copy(alpha = 0.07f))
                ) {
                    Box(
                        Modifier.fillMaxWidth(pct.coerceAtLeast(if (u == null) 0f else 0.02f))
                            .fillMaxHeight()
                            .clip(squircle(4.dp))
                            // >90% 变橙：不是"错误"，但该提醒了
                            .background(if (pct > 0.9f) Color(0xFFE0902E) else V2.accent)
                    )
                }
            }

            // 立即同步 / 清理云备份（2026-11-16）
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                CloudAction(tr("立即同步"), busy, Modifier.weight(1f)) {
                    busy = true
                    scope.launch {
                        withContext(Dispatchers.IO) { runCatching { Api.backupPush() } }
                        usage = withContext(Dispatchers.IO) { runCatching { Api.cloudUsage() }.getOrNull() }
                        busy = false
                        android.widget.Toast.makeText(ctx, "已同步", android.widget.Toast.LENGTH_SHORT).show()
                    }
                }
                CloudAction(tr("清理云备份"), busy, Modifier.weight(1f)) { confirmClear = true }
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 明细 ----------
            Text(
                tr("占用明细"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
            )
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                val u = usage
                CloudRow(
                    title = tr("聊天记录备份"),
                    sub = when {
                        u == null -> "—"
                        u.chatBytes <= 0 -> tr("还没有备份")
                        else -> fmtSize(u.chatBytes) +
                            if (u.chatAt.isNotBlank()) " · " + u.chatAt.take(10) else ""
                    },
                    tag = if (u != null && u.chatBytes > 0) tr("有") else tr("无")
                )
                ThinDivider()
                CloudRow(
                    title = tr("图片缓存"),
                    sub = if (loaded) tr("%d 张 · %s", imgCount, fmtSize(imgBytes))
                    else tr("正在统计…"),
                    tag = tr("本机")
                )
                ThinDivider()
                CloudRow(
                    title = tr("其他"),
                    // 总用量 - 聊天备份 - 图片，负数就显示 0
                    sub = if (u == null) "—"
                    else fmtSize((u.used - u.chatBytes - imgBytes).coerceAtLeast(0L)),
                    tag = ""
                )
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 扩容（禁用）----------
            Box(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .clip(squircle(14.dp))
                    .background(ink.copy(alpha = 0.06f))
                    .padding(vertical = 14.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    tr("扩容 · 即将开放"), fontSize = V2.body,
                    fontWeight = FontWeight.Medium, color = ink.copy(alpha = 0.35f)
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                tr("默认 1 GB，超出后新的备份会被拒绝，直到你清理或扩容。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.4f), lineHeight = 18.sp,
                modifier = Modifier.padding(horizontal = V2.gutter)
            )

            // 同步状态（2026-11-16）：成功绿字 / 失败红字，不只闪 Toast
            val okAt = Api.lastBackupOkAt
            val err = Api.lastBackupError
            Text(
                when {
                    err.isNotBlank() -> tr("上次同步失败：%s", err)
                    okAt > 0L -> tr(
                        "上次同步：%s · %s",
                        java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.US)
                            .format(java.util.Date(okAt)),
                        fmtSize(Api.lastBackupBytes)
                    )
                    else -> tr("还没有同步过")
                },
                fontSize = 10.5.sp, lineHeight = 16.sp,
                color = if (err.isNotBlank()) V2.alert else ink.copy(alpha = 0.35f),
                modifier = Modifier.padding(horizontal = V2.gutter)
            )
            Spacer(Modifier.height(8.dp))

            // ---------- 用恢复码恢复（2026-11-16，119）----------
            Spacer(Modifier.height(6.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().tapable { showRecover = true }
                        .padding(horizontal = V2.gutter, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    androidx.compose.material3.Icon(
                        androidx.compose.ui.res.painterResource(
                            com.aevis.android.R.drawable.ic_import
                        ), null,
                        tint = ink.copy(alpha = 0.72f),
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(tr("用恢复码恢复"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("在另一台手机 / 重装后输入这串码"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    androidx.compose.material3.Icon(
                        androidx.compose.ui.res.painterResource(
                            com.aevis.android.R.drawable.ic_chevron
                        ), null,
                        tint = ink.copy(alpha = 0.25f),
                        modifier = Modifier.size(15.dp)
                    )
                }
            }

            Spacer(Modifier.height(34.dp))
        }
    }

    if (showRecover) {
        RecoverCodeSheet(
            onDismiss = { showRecover = false },
            onRecovered = { n ->
                showRecover = false
                usage = runCatching { Api.cloudUsage() }.getOrNull()
                android.widget.Toast.makeText(
                    ctx, "已恢复 $n 个会话", android.widget.Toast.LENGTH_LONG
                ).show()
            }
        )
    }
}

/** 底部两个动作按钮（同步 / 清理）。*/
@Composable
private fun CloudAction(
    label: String,
    busy: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Box(
        modifier.height(42.dp).clip(squircle(12.dp))
            .background(ink.copy(alpha = if (busy) 0.04f else 0.07f))
            .tapable(enabled = !busy) { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Text(
            if (busy) tr("处理中…") else label,
            fontSize = V2.sub, color = ink.copy(alpha = if (busy) 0.35f else 0.75f)
        )
    }
}

/** 一行明细：标题 + 副标题 + 右侧小标签。*/
@Composable
private fun CloudRow(title: String, sub: String, tag: String) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = V2.body, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(2.dp))
            Text(sub, fontSize = V2.micro, color = ink.copy(alpha = 0.45f))
        }
        if (tag.isNotEmpty()) {
            Text(
                tag, fontSize = 10.sp, color = ink.copy(alpha = 0.5f),
                modifier = Modifier.clip(squircle(6.dp))
                    .background(ink.copy(alpha = 0.06f))
                    .padding(horizontal = 7.dp, vertical = 2.dp)
            )
        }
    }
}

/** 12345678 → "11.8 MB" / "1.00 GB"。*/
private fun fmtSize(b: Long): String = when {
    b <= 0 -> "0 B"
    b < 1024 -> "$b B"
    b < 1024 * 1024 -> String.format(java.util.Locale.US, "%.1f KB", b / 1024.0)
    b < 1024L * 1024 * 1024 -> String.format(java.util.Locale.US, "%.1f MB", b / 1048576.0)
    else -> String.format(java.util.Locale.US, "%.2f GB", b / 1073741824.0)
}

/** 0.5dp 分割线（本文件自己的，不抢 Screens 里的 private 版本）。*/
@Composable
private fun ThinDivider() {
    Box(
        Modifier.fillMaxWidth().height(0.5.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f))
    )
}
