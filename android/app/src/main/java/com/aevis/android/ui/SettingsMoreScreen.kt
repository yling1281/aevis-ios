package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 设置「更多」页（2026-11-16，109；125 改数据驱动）。
 *
 * 用户原话：「更多里面做的那些弹跳的，基础也是配置」——
 * 所以现在**行是数组、动作是枚举**：加一行只改 [moreGroups]，UI 一行都不用动。
 * 从行里弹出的半窗统一走 [MoreSheetHost]，不在这里各写一个 `showXxx` 布尔。
 */
@Composable
fun SettingsMoreScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    BackHandler { onBack() }
    // 当前打开的半窗 id（null = 没开）—— 125：整页只有一个宿主，天然不会叠层
    var sheet by remember { mutableStateOf<String?>(null) }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = tr("更多"), onBack = onBack)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(6.dp))

            moreGroups().forEach { (title, items) ->
                GroupCard(title) {
                    items.forEachIndexed { i, item ->
                        if (i > 0) ThinLine()
                        MoreRow(
                            icon = item.icon,
                            title = item.title,
                            sub = item.subtitle,
                            onClick = {
                                when (val a = item.action) {
                                    is MoreAction.Route -> onOpen(a.route)
                                    is MoreAction.Sheet -> sheet = a.id
                                    is MoreAction.Toggle -> a.onChange(!a.on)
                                }
                            }
                        )
                    }
                }
            }

            Spacer(Modifier.height(30.dp))
        }
    }

    MoreSheetHost(id = sheet, onClose = { sheet = null })
}

/** 一个动作：跳页面 / 弹半窗 / 切开关（125）。*/
sealed interface MoreAction {
    data class Route(val route: String) : MoreAction
    data class Sheet(val id: String) : MoreAction
    data class Toggle(val on: Boolean, val onChange: (Boolean) -> Unit) : MoreAction
}

/** 更多页的一行（125）：**只描述，不渲染**。*/
data class MoreItem(
    val id: String,
    val title: String,
    val subtitle: String,
    @DrawableRes val icon: Int,
    val action: MoreAction
)

/**
 * 「更多」页的全部行（2026-11-16，125）。
 *
 * ⚠️ 加一行就在对应分组里追一条，不需要碰任何 UI 代码。
 * `Sheet(...)` 的 id 必须和 [MoreSheetHost] 里的分支对上。
 */
private fun moreGroups(): List<Pair<String, List<MoreItem>>> = listOf(
    tr("偏好设置") to listOf(
        MoreItem(
            "inbox", tr("通知管理"), tr("站内信、更新提醒"),
            R.drawable.ic_set_bell, MoreAction.Route("inbox")
        ),
        MoreItem(
            "settings2", tr("通用配置"), tr("主题、背景、弹窗"),
            R.drawable.ic_set_sliders, MoreAction.Route("settings2")
        ),
        // 2026-11-25：增长入口（群聊/企微客服/活动/邀请），链接后台热更新
        MoreItem(
            "growth", tr("社区与活动"), tr("群聊、客服、活动、邀请"),
            R.drawable.ic_row_addfriend, MoreAction.Route("growth")
        )
    ),
    tr("数据管理") to listOf(
        MoreItem(
            "permission", tr("权限控制"), tr("相机、相册、通知"),
            R.drawable.ic_set_shield, MoreAction.Route("permission")
        ),
        MoreItem(
            "cloud", tr("存储设置"), tr("云空间、清理"),
            R.drawable.ic_set_layers, MoreAction.Route("cloud")
        ),
        MoreItem(
            "account", tr("个人信息"), tr("头像、Aevis 号"),
            R.drawable.ic_set_person, MoreAction.Route("account")
        ),
        MoreItem(
            "library", tr("资源库"), tr("照片、视频、文件"),
            R.drawable.ic_set_layers, MoreAction.Route("library")
        )
    ),
    tr("软件设置") to listOf(
        MoreItem(
            "serverstatus", tr("服务器状态"), tr("线路延迟、模型成功率"),
            R.drawable.ic_set_monitor, MoreAction.Route("serverstatus")
        ),
        MoreItem(
            "about", tr("关于"), tr("版本、更新日志"),
            R.drawable.ic_set_info, MoreAction.Route("about")
        )
    ),
    tr("恢复与备份") to listOf(
        MoreItem(
            "recover", tr("用恢复码恢复"), tr("换机后凭 8 位码找回聊天"),
            R.drawable.ic_import, MoreAction.Sheet("recover")
        ),
        MoreItem(
            "restore_roles", tr("从云端恢复人设"), tr("本地角色不丢，同 id 按云端更新"),
            R.drawable.ic_set_person, MoreAction.Sheet("restore_roles")
        ),
        MoreItem(
            "clear_cloud", tr("清理云端备份"), tr("只删云端那份，本机记录不动"),
            R.drawable.ic_export, MoreAction.Sheet("clear_cloud")
        )
    )
)

@Composable
private fun GroupCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.padding(horizontal = V2.gutter, vertical = 5.dp)) {
        Text(
            title, fontSize = 11.sp,
            color = ink.copy(alpha = 0.45f),
            modifier = Modifier.padding(start = 6.dp, bottom = 5.dp)
        )
        V2Card(Modifier, pad = 0.dp) { content() }
    }
}

/**
 * 「更多」页的一行：24dp 线条图标 + 标题 + 副标题 + 右箭头。
 *
 * 115：图标从 emoji 字符串（`"🔔"` 这种）换成矢量 drawable ——
 * emoji 在不同机型上字形/颜色都不一样，还有的会被系统渲染成彩色方块，
 * 跟"全 App 一套线条图标"的目标冲突。行尾的 `›` 也换成 drawable。
 */
@Composable
private fun MoreRow(
    @DrawableRes icon: Int,
    title: String,
    sub: String,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            painterResource(icon), null,
            tint = ink.copy(alpha = 0.72f),
            modifier = Modifier.size(24.dp)
        )
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(1.dp))
            Text(sub, fontSize = 11.sp, color = ink.copy(alpha = 0.45f))
        }
        Icon(
            painterResource(R.drawable.ic_chevron), null,
            tint = ink.copy(alpha = 0.25f),
            modifier = Modifier.size(15.dp)
        )
    }
}

// ---------------------------------------------------------------- 服务器状态

/**
 * 服务器状态页（2026-11-16，109；115 重写渲染）。
 *
 * 三组：集群 / 服务器（延迟）/ 模型（成功率 + 近 24 小时柱状图）。
 *
 * 115 为什么重写：上一版把 30+ 个模型 × 50 根柱子全塞进一个 `Column`，
 * 一次组合就是上千个 composable，进页面直接卡死、滚动掉帧。
 * 现在：
 *   · 列表换 `LazyColumn` + `key(model)`，只组合屏幕上真正看得见的几张卡；
 *   · 柱子**一张 Canvas** 循环 `drawRoundRect`（不是 50 个 Box），高度固定 12dp；
 *   · 线路探测**只跑一次**（`LaunchedEffect(tick)` 里并发测完一次性写回状态），
 *     不再让每行的 `LaunchedEffect(line.id, tick)` 自己加 tick 触发重测；
 *   · `/v1/relay/status` 走 `Api` 的进程内缓存（5 分钟），进页面先用缓存渲染再后台刷新；
 *   · 所有网络（`pingLineById` / `relayStatus`）都在 `Dispatchers.IO`，组合函数里没有任何同步请求。
 */
@Composable
fun ServerStatusScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var tick by remember { mutableIntStateOf(0) }
    // 先吃进程内缓存：第一帧就有内容，不用等 13KB 回来
    var stats by remember { mutableStateOf<List<Api.RelayModel>?>(Api.relayStatusCached()) }
    // id → 探测结果（null = 还没测出来）。114 起是 `PingResult`（能分辨超时/TLS/HTTP）
    val latency = remember { mutableStateMapOf<Int, Api.PingResult>() }

    // 模型统计：进页面拉一次；5 分钟内命中缓存。点「刷新」才 force 真正重拉。
    LaunchedEffect(tick) {
        val fresh = withContext(Dispatchers.IO) {
            runCatching { Api.relayStatus(force = tick > 0) }.getOrNull()
        }
        if (fresh != null) stats = fresh
    }

    // 线路探测：**只在这里跑**（进页面一次 / 点刷新 / 点某一行时 tick++）。
    // 并发测完一次性写回，避免多条线程同时改 Compose 状态。
    LaunchedEffect(tick) {
        val ids = Api.lines().filter { it.chat }.map { it.id }
        val results = withContext(Dispatchers.IO) {
            coroutineScope {
                ids.map { id -> async { id to Api.pingLineById(id) } }
                    .map { it.await() }.toMap()
            }
        }
        latency.clear()
        results.forEach { (id, r) -> latency[id] = r }
    }
    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(
            title = tr("服务状态"),
            onBack = onBack,
            trailing = {
                Text(
                    tr("刷新"), fontSize = 13.sp, color = V2.accent,
                    modifier = Modifier.tapable { tick++ }
                )
            }
        )

        // 115：LazyColumn —— 模型多的时候只组合可见项，滚动才不掉帧
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 30.dp)
        ) {
            // ---------- 集群 ----------
            item(key = "cluster") {
                SectionTitle(tr("集群"))
                V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                    // 110：用户明确「只有一个主集群」，广州那行删掉
                    ClusterRow(tr("主集群"), tr("使用中"), true)
                }
            }

            // ---------- 服务器 ----------
            item(key = "servers") {
                SectionTitle(tr("服务器"))
                V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                    // 自动选择（推荐）：id 0 = 谁先回用谁
                    Row(
                        Modifier.fillMaxWidth()
                            .tapable { Api.setLineById(0); tick++ }
                            .padding(horizontal = V2.gutter, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            tr("自动选择（推荐）"), fontSize = 14.sp,
                            fontWeight = FontWeight.Medium
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            tr("谁先回用谁"), fontSize = 10.5.sp,
                            color = ink.copy(alpha = 0.4f)
                        )
                        Spacer(Modifier.weight(1f))
                        if (Api.currentLineId() == 0) {
                            Icon(
                                androidx.compose.ui.res.painterResource(
                                    com.aevis.android.R.drawable.ic_login_check
                                ), null, tint = V2.accent,
                                modifier = Modifier.size(15.dp)
                            )
                        }
                    }

                    // 有几条显示几条，按实测延迟升序：通的在前（按 ms），
                    // 其它失败排中间，超时排最后，还没测出来的垫最前（灰点，等结果）。
                    fun rank(p: Api.PingResult?): Int = when {
                        p == null -> -1
                        p.fail == Api.PingFail.NONE -> 0
                        p.fail == Api.PingFail.TIMEOUT -> 2
                        else -> 1
                    }
                    val ordered = Api.lines().filter { it.chat }.sortedWith(
                        compareBy(
                            { rank(latency[it.id]) },
                            { latency[it.id]?.ms ?: Long.MAX_VALUE }
                        )
                    )
                    // 118：勾选跟着**实际在用的那条**走（竞速赢家），没跑过请求才回落到用户选择
                    val activeId = Api.activeLineId().takeIf { it > 0 } ?: Api.currentLineId()
                    ordered.forEach { line ->
                        ThinLine()
                        ServerRow(
                            line = line,
                            ping = latency[line.id],
                            selected = activeId == line.id
                        ) {
                            // 失败行也能点：切过去 + 重测（tick++ 触发上面那个探测 Effect）
                            Api.setLineById(line.id)
                            tick++
                        }
                    }
                }
            }

            // ---------- 模型 ----------
            item(key = "models-title") { SectionTitle(tr("模型")) }
            val list = stats
            when {
                list == null -> item(key = "models-loading") {
                    V2Card(Modifier.padding(horizontal = V2.gutter)) {
                        Text(
                            tr("正在读取统计…"), fontSize = 12.sp,
                            color = ink.copy(alpha = 0.45f)
                        )
                    }
                }
                list.isEmpty() -> item(key = "models-empty") {
                    V2Card(Modifier.padding(horizontal = V2.gutter)) {
                        Text(
                            tr("暂无模型状态"), fontSize = 12.sp,
                            color = ink.copy(alpha = 0.45f)
                        )
                    }
                }
                else -> items(list, key = { it.model }) { st ->
                    ModelStatCard(st, ink)
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(t: String) {
    val ink = MaterialTheme.colorScheme.onSurface
    Text(
        t, fontSize = 11.sp, color = ink.copy(alpha = 0.45f),
        modifier = Modifier.padding(horizontal = V2.gutter + 6.dp, vertical = 8.dp)
    )
}

@Composable
private fun ClusterRow(name: String, note: String, active: Boolean) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(name, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(1.dp))
            Text(note, fontSize = 11.sp, color = ink.copy(alpha = 0.45f))
        }
        if (active) {
            Icon(
                painterResource(R.drawable.ic_login_check), null,
                tint = V2.accent, modifier = Modifier.size(15.dp)
            )
        }
    }
}

@Composable
private fun ServerRow(
    line: Api.Line,
    ping: Api.PingResult?,
    selected: Boolean,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 状态点（114 四态）：绿=通 / 橙=超时 / 红=TLS、HTTP 5xx、网络错 / 灰=还没测出来
        val dot = when {
            ping == null -> ink.copy(alpha = 0.18f)
            ping.fail == Api.PingFail.NONE -> Color(0xFF3FBF6F)
            ping.fail == Api.PingFail.TIMEOUT -> Color(0xFFE0902E)
            else -> Color(0xFFE5484D)
        }
        Box(Modifier.size(7.dp).clip(androidx.compose.foundation.shape.CircleShape).background(dot))
        Spacer(Modifier.width(9.dp))
        Text(line.label, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.width(6.dp))
        Text(line.note, fontSize = 10.5.sp, color = ink.copy(alpha = 0.4f))
        Spacer(Modifier.weight(1f))
        Text(
            when {
                ping == null -> "—"
                ping.fail == Api.PingFail.NONE -> "${ping.ms} ms"
                ping.fail == Api.PingFail.TIMEOUT -> tr("超时")
                ping.fail == Api.PingFail.TLS -> tr("TLS 失败")
                ping.fail == Api.PingFail.HTTP -> "HTTP ${ping.detail}"
                else -> tr("网络错误")
            },
            fontSize = 12.sp,
            color = when {
                ping == null -> ink.copy(alpha = 0.3f)
                ping.fail == Api.PingFail.NONE -> ink.copy(alpha = 0.6f)
                ping.fail == Api.PingFail.TIMEOUT -> Color(0xFFE0902E)
                else -> V2.alert.copy(alpha = 0.9f)
            }
        )
        if (selected) {
            Spacer(Modifier.width(8.dp))
            Icon(
                painterResource(R.drawable.ic_login_check), null,
                tint = V2.accent, modifier = Modifier.size(14.dp)
            )
        }
    }
}

@Composable
private fun ModelStatCard(st: Api.RelayModel, ink: Color) {
    V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 5.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(st.name, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                if (st.vendor.isNotBlank() || st.note.isNotBlank()) {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        listOf(st.vendor, st.note).filter { it.isNotBlank() }.joinToString(" · "),
                        fontSize = 10.5.sp, color = ink.copy(alpha = 0.42f)
                    )
                }
                Spacer(Modifier.height(2.dp))
                Text(
                    when {
                        st.ping == null -> tr("平均响应 —")
                        st.ping >= 1000 -> tr("平均响应 %.1f 秒", st.ping / 1000.0)
                        else -> tr("平均响应 %d ms", st.ping)
                    },
                    fontSize = 11.sp, color = ink.copy(alpha = 0.45f)
                )
            }
            Text(
                if (st.uptime24 == null) "—" else "%.1f%%".format(st.uptime24 * 100),
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                color = if (st.uptime24 == null) ink.copy(alpha = 0.3f) else ink
            )
        }

        // 柱子：beats 是**近 24 小时**的 50 个 30 分钟槽（不是 30 分钟，标签别写错）
        if (st.beats.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Text(
                tr("近 24 小时"), fontSize = 9.5.sp, color = ink.copy(alpha = 0.35f)
            )
            Spacer(Modifier.height(4.dp))
            val beats = st.beats
            // 115：高度固定 12dp —— 单卡不再撑 30dp 的图，50 个模型叠起来差出一屏
            Canvas(Modifier.fillMaxWidth().height(12.dp)) {
                val n = beats.size.coerceAtLeast(1)
                val gap = 1.5.dp.toPx()
                val w = ((size.width - gap * (n - 1)) / n).coerceAtLeast(1f)
                for (i in 0 until n) {
                    val ok = beats[i] == 1
                    val h = if (ok) size.height else size.height * 0.55f
                    drawRoundRect(
                        color = if (ok) Color(0xFF3FBF6F) else Color(0xFFE05A4E),
                        topLeft = androidx.compose.ui.geometry.Offset(i * (w + gap), size.height - h),
                        size = androidx.compose.ui.geometry.Size(w, h),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(1f, 1f)
                    )
                }
            }
        }
    }
}

@Composable
private fun ThinLine() {
    Box(
        Modifier.fillMaxWidth().height(0.5.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f))
    )
}

/**
 * 「更多」页所有半窗/确认框的**唯一宿主**（2026-11-16，125）。
 *
 * 用户要求这些"弹跳的东西"也走配置：行的 `MoreAction.Sheet(id)` 只给一个 id，
 * 具体弹什么由这里决定。好处是**天然不会叠层**（同一时刻只有一个 id），
 * 半窗自带返回键关闭；新增一个半窗只需在这里加一个 `when` 分支。
 */
@Composable
internal fun MoreSheetHost(id: String?, onClose: () -> Unit) {
    if (id == null) return
    val ctx = LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    var busy by remember(id) { mutableStateOf(false) }

    when (id) {
        "recover" -> RecoverCodeSheet(
            onDismiss = onClose,
            onRecovered = { n ->
                onClose()
                android.widget.Toast.makeText(
                    ctx, "已恢复 $n 个会话", android.widget.Toast.LENGTH_LONG
                ).show()
            }
        )

        "restore_roles" -> AlertDialog(
            onDismissRequest = { if (!busy) onClose() },
            title = { Text(tr("从云端恢复人设？")) },
            text = {
                Text(
                    tr("会把服务端「我的角色」写回本地；同 id 的按云端那份更新，本地新建的保留。"),
                    fontSize = V2.sub, lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    busy = true
                    scope.launch {
                        val (n, err) = withContext(Dispatchers.IO) {
                            com.aevis.android.core.PersonaLib.restoreFromCloud(force = true)
                        }
                        busy = false
                        onClose()
                        android.widget.Toast.makeText(
                            ctx,
                            when {
                                err.isNotBlank() -> "恢复失败：$err"
                                n > 0 -> "已恢复 $n 个角色"
                                else -> "云端没有角色可恢复"
                            },
                            android.widget.Toast.LENGTH_LONG
                        ).show()
                    }
                }) { Text(tr("恢复"), color = V2.accent) }
            },
            dismissButton = {
                TextButton(onClick = onClose) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )

        "clear_cloud" -> AlertDialog(
            onDismissRequest = { if (!busy) onClose() },
            title = { Text(tr("清理云端备份？")) },
            text = {
                Text(
                    tr("云端那份聊天记录会被删掉，这台设备上的记录不受影响。"),
                    fontSize = V2.sub, lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    busy = true
                    scope.launch {
                        val ok = withContext(Dispatchers.IO) {
                            runCatching { Api.deleteBackup() }.getOrDefault(false)
                        }
                        busy = false
                        onClose()
                        android.widget.Toast.makeText(
                            ctx, if (ok) "已清理" else "清理失败",
                            android.widget.Toast.LENGTH_SHORT
                        ).show()
                    }
                }) { Text(tr("清理"), color = V2.alert) }
            },
            dismissButton = {
                TextButton(onClick = onClose) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }
}
