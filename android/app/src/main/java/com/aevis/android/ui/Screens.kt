package com.aevis.android.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
// 转场（2026-11-16）：AnimatedContent / AnimatedVisibility 都在 BOM 2024.09.00 里，不需要新依赖
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Dp
import kotlin.math.roundToInt
import androidx.compose.ui.unit.dp
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.sp
import com.aevis.android.BuildConfig
import com.aevis.android.R
import com.aevis.android.core.NativeCore
import com.aevis.android.core.I18n
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.GroupStore
import com.aevis.android.core.LocalPersonaStore
import com.aevis.android.core.PersonaLib
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * iOS 那张「V2Card」：**连续圆角**、纯白、0.5dp 极淡描边、无阴影。
 *
 * 2026-11-14 用户：「该圆润的地方没圆润起来，该白的地方没白起来」——
 * 之前用的是 `RoundedCornerShape`（正圆弧）+ 没描边，卡片看着"平、方、灰"。
 * 现在换成 squircle（超椭圆），再补一层 8% 的描边把边"立"起来。
 */
@Composable
fun V2Card(
    modifier: Modifier = Modifier,
    pad: Dp = V2.cardPad,
    content: @Composable ColumnScope.() -> Unit
) {
    val shape = squircle(V2.cardRadius)
    // 毛玻璃（2026-11-16，112）：只在「设了主背景」时切换，`default` 还是原来那张纯白卡
    // （连描边粗细都不变 —— 0.5dp vs 1dp 的差别在老观感里一眼就能看出来）。
    val skin = appSkin()
    val fill = skin?.cardFill ?: MaterialTheme.colorScheme.surface
    val stroke = skin?.cardStroke
        ?: MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(fill)
            .border(if (skin == null) 0.5.dp else 1.dp, stroke, shape)
            .padding(pad),
        content = content
    )
}

/** 图标方块：40 圆角 13，淡色底。*/
@Composable
fun IconBox(@DrawableRes icon: Int, tint: Color = V2.accent) {
    Box(
        Modifier.size(V2.iconBox)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.13f)),
        contentAlignment = Alignment.Center
    ) { Icon(painterResource(icon), null, tint = tint, modifier = Modifier.size(18.dp)) }
}


/**
 * 点击但**不要 Material 的水波纹**。
 *
 * 用户一直说「一看就是安卓味」—— 水波纹是最典型的那个味。iOS 上是整行按下变淡，
 * 这里用 `indication = null` 把涟漪去掉，按下态交给 `Modifier.alpha`（见 RowItem）。
 */
/// 从扫码内容里抠出登录票号。
/// 和 iOS（`QRScan.ticket`）、网页、小程序用的是**同一套规则**，
/// 四端扫同一张码必须都能认出来。
private fun parseScanTicket(raw: String): String {
    if (raw.isEmpty()) return ""
    val m = Regex("[?&]t=([0-9a-fA-F]{16,64})").find(raw) ?: return ""
    return m.groupValues.getOrNull(1) ?: ""
}

/**
 * 全 App 唯一的可点修饰符：果冻按压 + 无水波纹。
 *
 * `onLongClick`（2026-11-16 加）：聊天列表要「长按清空对话」。
 * ⚠️ 它必须排在 `onClick` **前面** —— 尾随 lambda 永远绑定最后一个参数，
 *    放在后面会让全工程几百个 `tapable { ... }` 全部绑到长按上去。
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun Modifier.tapable(
    enabled: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit
): Modifier {
    val src = remember { MutableInteractionSource() }
    // 2026-11-15 用户：「点按钮的话也可以像果冻一样弹跳一下」——
    // 按下缩到 0.94，松手用低阻尼 spring 弹回去（会轻微过冲，就是果冻感）。
    // 用 PressInteraction 自己收（老版本 foundation 没有 collectIsPressedAsState）
    var pressed by remember { mutableStateOf(false) }
    LaunchedEffect(src) {
        src.interactions.collect { it ->
            when (it) {
                is androidx.compose.foundation.interaction.PressInteraction.Press -> pressed = true
                is androidx.compose.foundation.interaction.PressInteraction.Release -> pressed = false
                is androidx.compose.foundation.interaction.PressInteraction.Cancel -> pressed = false
            }
        }
    }
    val sc by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (pressed && enabled)
            com.aevis.android.core.AnimPrefs.pressScale else 1f,
        animationSpec = androidx.compose.animation.core.spring(
            dampingRatio = com.aevis.android.core.AnimPrefs.damping,
            stiffness = androidx.compose.animation.core.Spring.StiffnessMedium
        ),
        label = "tap"
    )
    return this.then(
        Modifier.graphicsLayer { scaleX = sc; scaleY = sc }
            .let { base ->
                if (onLongClick == null) {
                    base.clickable(
                        interactionSource = src, indication = null,
                        enabled = enabled, onClick = onClick
                    )
                } else {
                    // 有长按才用 combinedClickable —— 没有长按的几百处保持原来的 clickable
                    base.combinedClickable(
                        interactionSource = src, indication = null, enabled = enabled,
                        onClick = onClick, onLongClick = onLongClick
                    )
                }
            }
    )
}

// ------------------------------------------------------------------ 主壳

/**
 * 用系统浏览器打开链接（2026-11-16）。
 *
 * 关于页 / 更新弹窗 / 官网都走这一个 —— 抽出来是为了统一兜底：
 * 设备上没有浏览器时 `ActivityNotFoundException` 会直接崩，必须 catch 并给一句人话。
 */
internal fun openUrl(ctx: android.content.Context, url: String) {
    if (url.isBlank()) return
    try {
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    } catch (e: android.content.ActivityNotFoundException) {
        Toast.makeText(ctx, "没有可用的浏览器", Toast.LENGTH_SHORT).show()
    } catch (e: Exception) {
        Toast.makeText(ctx, "打不开这个链接", Toast.LENGTH_SHORT).show()
    }
}

/**
 * 更新弹窗（2026-11-16）—— 冷启动和「关于 → 检查更新」共用。
 *
 * `force == true`（服务端要求强更）时：**只留「去下载」**，返回键 / 点外面都关不掉。
 */
@Composable
internal fun UpdateDialog(info: com.aevis.android.data.Api.UpdateInfo, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    var logs by remember { mutableStateOf<List<com.aevis.android.data.Api.ChangeLog>>(emptyList()) }
    // 只显示 <= 最新版本 的条目（比 latest 还新的不给用户看，那是没发布的）
    val shownLogs = remember(logs, info.latest) {
        logs.filter { cmpVersion(it.version, info.latest) <= 0 }
    }
    LaunchedEffect(Unit) {
        logs = withContext(Dispatchers.IO) {
            runCatching { com.aevis.android.data.Api.changeLog() }.getOrDefault(emptyList())
        }
    }

    // ---------- App 内下载安装 APK（2026-11-24）----------
    // 之前 confirmButton 是 openUrl(ctx, info.url) 跳浏览器，用户还得自己去下载目录找包。
    // 现在 App 内下载完直接调系统安装器。
    // phase：0 空闲 / 1 下载中 / 2 已拉起安装器 / 3 失败 / 4 等待开启「安装未知应用」权限
    var phase by remember { mutableIntStateOf(0) }
    var progress by remember { mutableIntStateOf(-1) } // -1 = 服务端没给长度，用不确定进度
    var errMsg by remember { mutableStateOf("") }
    var apkRef by remember { mutableStateOf<java.io.File?>(null) }
    val scope = rememberCoroutineScope()

    // 从「安装未知应用」设置页返回后接着装：权限开了就装，没开就留在错误态给人话
    val unknownSrcLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        val apk = apkRef
        if (apk != null && com.aevis.android.core.ApkInstaller.canInstallUnknownApps(ctx)) {
            try {
                com.aevis.android.core.ApkInstaller.install(ctx, apk)
                phase = 2
            } catch (e: Exception) {
                errMsg = e.message ?: tr("安装失败")
                phase = 3
            }
        } else {
            errMsg = tr("未允许本 App 安装未知应用，无法安装更新")
            phase = 3
        }
    }

    /** 起下载协程：不阻塞主线程；进度和失败都留在弹窗里，不 Toast 一下就消失。 */
    fun startDownload() {
        if (phase == 1 || phase == 4) return // 下载中 / 等权限时禁重复点击
        phase = 1
        progress = -1
        errMsg = ""
        apkRef = null
        scope.launch {
            try {
                val file = com.aevis.android.core.ApkInstaller.download(ctx, info.url) { p ->
                    progress = p
                }
                apkRef = file
                if (!com.aevis.android.core.ApkInstaller.canInstallUnknownApps(ctx)) {
                    // 包先下好，再引导授权；回来在 launcher 回调里安装
                    phase = 4
                    try {
                        unknownSrcLauncher.launch(
                            com.aevis.android.core.ApkInstaller.unknownAppsSettingsIntent(ctx)
                        )
                    } catch (e: Exception) {
                        errMsg = tr("打不开设置页：%s", e.message ?: "请手动开启安装权限")
                        phase = 3
                    }
                } else {
                    com.aevis.android.core.ApkInstaller.install(ctx, file)
                    phase = 2
                }
            } catch (e: Exception) {
                errMsg = e.message ?: tr("下载失败")
                phase = 3
            }
        }
    }

    AlertDialog(
        // 下载中 / 等权限时不允许关弹窗，避免下载完找不到界面
        onDismissRequest = { if (!info.force && phase != 1 && phase != 4) onDismiss() },
        title = { Text(tr("发现新版本 %s", info.latest)) },
        text = {
            Column {
                Text(
                    info.notes.ifBlank { tr("有更新可用，建议升级到最新版本。") },
                    fontSize = V2.sub, lineHeight = 20.sp
                )
                // 更新日志（2026-11-16）：`GET /v1/app/changelog`，按版本分组，最高 180dp 可滚。
                // 拿不到就只显示 notes（不占位、不显示空块）。
                if (shownLogs.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Column(
                        Modifier.fillMaxWidth().heightIn(max = 180.dp)
                            .verticalScroll(rememberScrollState())
                    ) {
                        shownLogs.forEach { lg ->
                            Text(
                                (if (lg.version.isNotBlank()) lg.version else "") +
                                    (if (lg.date.isNotBlank()) "　" + lg.date else ""),
                                fontSize = 12.sp, fontWeight = FontWeight.Medium,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            lg.items.forEach { line ->
                                Text(
                                    "· $line", fontSize = 11.5.sp, lineHeight = 17.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                                )
                            }
                            Spacer(Modifier.height(8.dp))
                        }
                    }
                }
                // 下载进度 / 结果（2026-11-24）：所有状态都留在弹窗内，失败可就地重试
                when (phase) {
                    1 -> {
                        Spacer(Modifier.height(12.dp))
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth(),
                            color = V2.accent,
                            trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            if (progress >= 0) tr("正在下载更新 %d%%", progress)
                            else tr("正在连接服务器下载更新…"),
                            fontSize = 11.5.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f)
                        )
                    }
                    2 -> {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            tr("已开始安装，请按系统提示完成"),
                            fontSize = 11.5.sp, color = V2.accent
                        )
                    }
                    3 -> {
                        Spacer(Modifier.height(10.dp))
                        Text(errMsg, fontSize = 11.5.sp, color = MaterialTheme.colorScheme.error)
                    }
                    4 -> {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            tr("安装包已就绪，请在系统设置里允许本 App 安装未知应用，返回后会自动安装"),
                            fontSize = 11.5.sp, color = V2.accent
                        )
                    }
                }
            }
        },
        confirmButton = {
            when (phase) {
                1 -> TextButton(onClick = {}, enabled = false) {
                    Text(
                        if (progress >= 0) tr("下载中 %d%%", progress) else tr("下载中…"),
                        color = V2.accent
                    )
                }
                2 -> TextButton(onClick = {}, enabled = false) {
                    Text(tr("安装中"), color = V2.accent)
                }
                4 -> TextButton(onClick = {}, enabled = false) {
                    Text(tr("等待授权"), color = V2.accent)
                }
                3 -> TextButton(onClick = { startDownload() }) {
                    Text(tr("重试"), color = V2.accent)
                }
                else -> TextButton(onClick = { startDownload() }) {
                    Text(tr("去下载"), color = V2.accent)
                }
            }
        },
        dismissButton = if (info.force) {
            null
        } else {
            { TextButton(onClick = onDismiss) { Text(tr("稍后")) } }
        },
        containerColor = frostedSheetColor()
    )
}

/** 图标改成 name —— 用的是我们自己在 `AevisIcons.kt` 里画的那套（照搬 iOS）。*/
private data class Tab(val id: String, val title: String)

// `ModalBottomSheet`（云端记录恢复的半窗）在 material3 里还是 Experimental 的
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun Shell(onSignOut: () -> Unit) {
    // 2026-11-15 按忆伴的 Dock 改：主页放第一位（用量额度 + 服务 + 发现 + 好友）
    // 2026-11-15 用户：「发现页的话就没必要了」→ 去掉，只留三个
    // 2026-11-25：chat flag 关时隐藏「聊天」tab（默认全关是预期）；主页 + 我永远在。
    val chatTabOn = Api.featureEnabled("chat")
    val tabs = buildList {
        add(Tab("home", "主页"))
        if (chatTabOn) add(Tab("chat", "聊天"))
        add(Tab("me", "我"))
    }
    var idx by remember { mutableIntStateOf(0) }
    // 二级页面（2026-11-14）：商城 / 浏览器 / 站内信 / 关于。
    // 之前这些东西全是 Toast，用户：「你啥也不行」。
    var page by remember { mutableStateOf<String?>(null) }
    // 从聊天页进外观/模型/日记，返回时要回到**那个对话**，不是回列表
    var backTo by remember { mutableStateOf<String?>(null) }
    // BUG-B：Dock 的**实测高度**（不写死 96dp）—— 首页内容要让它，不然名字被压住
    var dockHeight by remember { mutableStateOf(0.dp) }
    val dockDensity = androidx.compose.ui.platform.LocalDensity.current

    // ---------- 更新检查（2026-11-16）----------
    // 之前打的是 `/v1/app/version`（服务端没这个路径，永远 404）→ **从来没弹过更新**。
    // 现在冷启动查一次 `/v1/app/update`；同一个 latest 每天最多提示一次
    // （用户点「稍后」记下当天日期，第二天再提醒）。
    var updateInfo by remember { mutableStateOf<com.aevis.android.data.Api.UpdateInfo?>(null) }
    // 2026-11-25：冷启动后台预拉广场/表情/商品/额度/余额/会员态落盘，
    // 各页冷启动先读缓存立即显示，断网也不白屏（对标 iOS HardCache）。
    val prefetchCtx = LocalContext.current
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            com.aevis.android.core.ColdCache.prefetch(prefetchCtx)
        }
    }
    LaunchedEffect(Unit) {
        val u = withContext(Dispatchers.IO) { runCatching { Api.checkUpdate() }.getOrNull() }
        // 2026-11-24 强制更新门禁：force=true 必须真拦住 —— 绕过"今天已稍后"的抑制，
        // 每次冷启动都弹，且不给孩子 dismiss 按钮（UpdateDialog 里已处理）。
        if (u != null && u.update &&
            (u.force || !com.aevis.android.core.ChatPrefs.updateSkippedToday(u.latest))
        ) {
            updateInfo = u
        }
    }

    // ---------- 聊天云备份 / 自动恢复（2026-11-16，116）----------
    //
    // 用户最痛的点：删了重装、云端明明有备份（138KB / 23 段），却得自己进
    // 「云空间 → 从云端恢复」才回得来。现在分三种情况：
    //   ① 本地一条消息都没有 + 云端有 → **直接恢复**（开关默认开，不弹窗打断），恢复完 Toast；
    //   ② 本地一条消息都没有 + 用户关了「自动恢复」→ 半窗问一句；
    //   ③ 本地有数据 + 云端 `at` 比本地最后一条更新 → 半窗问「恢复云端 / 保留本地」，**绝不自动覆盖**；
    //   ④ 其它（本地更新 / 云端没有）→ 照旧把本地推上去。
    // 整个过程有进度态，失败会显示原因（HTTP 码 / 空备份），不静默。
    // stage：0 空闲 / 1 问一句 / 2 正在恢复 / 3 恢复失败
    var restoreStage by remember { mutableIntStateOf(0) }
    var restoreMeta by remember { mutableStateOf<Api.BackupMeta?>(null) }
    var restoreErr by remember { mutableStateOf("") }
    // 合并提示的累计（121）：对话 + 角色合成一条 Toast，恢复完一起报
    var restoredChats by remember { mutableIntStateOf(0) }
    var restoredRoles by remember { mutableIntStateOf(0) }
    // 本地是否一条消息都没有（决定要不要在恢复半窗里给「用恢复码」的后路）
    var restoreLocalEmpty by remember { mutableStateOf(false) }
    // 「用恢复码恢复」半窗（2026-11-16，119）
    var showRecoverSheet by remember { mutableStateOf(false) }
    val restoreScope = rememberCoroutineScope()
    val shellCtx = LocalContext.current

    /** 统一提示：对话 + 角色合成**一条** Toast（2026-11-16，121，不许各弹一次）。*/
    fun flushRestoreToast() {
        val c = restoredChats
        val r = restoredRoles
        if (c <= 0 && r <= 0) return
        restoredChats = 0
        restoredRoles = 0
        val parts = ArrayList<String>(2)
        if (c > 0) parts.add(tr("%d 段对话", c))
        if (r > 0) parts.add(tr("%d 个角色", r))
        Toast.makeText(
            shellCtx, tr("已恢复 ") + parts.joinToString(" · "), Toast.LENGTH_LONG
        ).show()
    }

    /** 真正去拉云端对话：成功累计条数，失败进「失败态」并带上原因。*/
    fun startRestore(meta: Api.BackupMeta) {
        restoreMeta = meta
        restoreErr = ""
        restoreStage = 2
        restoreScope.launch {
            val n = withContext(Dispatchers.IO) {
                runCatching { Api.backupPull(force = true) }.getOrDefault(0)
            }
            if (n > 0) {
                restoredChats += n
                restoreStage = 0
                flushRestoreToast()
            } else {
                restoreErr = Api.lastRestoreError.ifBlank { tr("恢复失败，请稍后再试") }
                restoreStage = 3
            }
        }
    }

    LaunchedEffect(Unit) {
        // 0) 角色档案（121）：本地一个角色都没有就从云端拉回来。
        //    放在对话恢复**之前**跑完，最后只弹一条合并 Toast。
        val (roleN, roleErr) = withContext(Dispatchers.IO) {
            com.aevis.android.core.PersonaLib.restoreFromCloud()
        }
        if (roleN > 0) restoredRoles = roleN
        if (roleN == 0 && roleErr.isNotBlank()) {
            // 人设恢复失败不让整条启动流程沉默 —— 单独报一句（对话那条走半窗）
            Toast.makeText(
                shellCtx, tr("角色恢复失败：%s", roleErr), Toast.LENGTH_LONG
            ).show()
        }

        val meta = withContext(Dispatchers.IO) {
            runCatching { Api.backupMeta() }.getOrNull()
        }
        // 云端没备份（或没登录）：把本地推上去，什么都不问，但角色的提示要照发
        if (meta == null || meta.count <= 0) {
            withContext(Dispatchers.IO) { runCatching { Api.backupPush() } }
            flushRestoreToast()
            return@LaunchedEffect
        }
        val localEmpty = withContext(Dispatchers.IO) {
            runCatching { Api.packConvs().length() == 0 }.getOrDefault(true)
        }
        val localAt = withContext(Dispatchers.IO) { Api.lastLocalChatAt() }
        val auto = com.aevis.android.core.ChatPrefs.autoRestore
        restoreMeta = meta
        restoreLocalEmpty = localEmpty
        when {
            // ① 首次安装 / 清数据 → 自动恢复，不打断
            localEmpty && auto -> {
                // 等首页画完再动手，别跟启动动画抢主线程
                kotlinx.coroutines.delay(300)
                restoreMeta = meta
                restoreErr = ""
                restoreStage = 2
                val chats = withContext(Dispatchers.IO) {
                    runCatching { Api.backupPull(force = true) }.getOrDefault(0)
                }
                if (chats > 0) {
                    restoredChats = chats
                    restoreStage = 0
                    flushRestoreToast()
                } else {
                    restoreErr = Api.lastRestoreError.ifBlank { tr("恢复失败，请稍后再试") }
                    restoreStage = 3
                }
            }
            // ② 本地空但关了自动恢复
            localEmpty -> {
                restoreStage = 1
                flushRestoreToast()   // 角色已经恢复了，先让它报一声
            }
            // ③ 本地有数据 + 云端更新（`at` 为 0 = 服务端没记时间，不拿来比）
            meta.at > 0 && meta.at > localAt -> {
                restoreStage = 1
                flushRestoreToast()
            }
            // ④ 本地更新：保住本地，顺手推一份
            else -> {
                withContext(Dispatchers.IO) {
                    runCatching { Api.backupPull() }
                    runCatching { Api.backupPush() }
                }
                flushRestoreToast()
            }
        }
    }

    // ---------- 133：主动消息（横幅 / 角标）----------
    // 只轮询「用户开了主动唤醒」的角色；当前正打开的那个会话交给 ChatScreen 自己插消息，
    // 这里跳过 —— 否则同一条会进两次。
    val bannerQueue = remember { androidx.compose.runtime.mutableStateListOf<BannerItem>() }
    LaunchedEffect(Unit) {
        while (true) {
            val openPid = page?.let {
                if (it.startsWith("chat:")) it.removePrefix("chat:") else null
            }
            val targets = com.aevis.android.core.LocalPersonaStore.all()
                .filter { com.aevis.android.core.ChatPrefs.proactiveOn(it.id) }
            targets.forEach { p ->
                if (openPid == p.id) return@forEach
                val items = withContext(Dispatchers.IO) { Api.proactivePending(p.id) }
                if (items.isEmpty()) return@forEach
                withContext(Dispatchers.IO) {
                    val conv = Api.loadConv(p.id).toMutableList()
                    items.forEach {
                        conv.add(Api.Msg(role = "assistant", content = it.text, proactive = true))
                    }
                    Api.saveConv(p.id, conv)
                    Api.proactiveAck(items.map { it.id })
                }
                com.aevis.android.core.ChatPrefs.bumpProactiveUnread(p.id, items.size)
                if (com.aevis.android.core.ChatPrefs.msgBanner &&
                    bannerQueue.size < 3 && items.isNotEmpty()
                ) {
                    bannerQueue.add(
                        BannerItem(p.id, p.name, p.avatar, items.first().text)
                    )
                }
            }
            kotlinx.coroutines.delay(3 * 60 * 1000L)
        }
    }

    // ---------- 二级页转场（2026-11-16）----------
    //
    // 用户：「整体界面动画呢，切换二级界面要优化」。
    // 以前这里是 `if (sub != null) { when { ... }; return }` —— 二级页是**硬切**，
    // 一点过渡都没有。现在改成「主页常驻 + 二级页覆盖层」：
    //   · 主页在二级页打开时轻微缩小 + 左移 + 变暗（iOS 卡片栈那种纵深）
    //   · 二级页从右侧滑入、带回弹；阻尼/位移读 `AnimPrefs`，用户在
    //     「更多 → 动效手感」里调完**立刻**影响转场（所以这些值在组合里现读，不能 remember 死）
    //
    // ⚠️ 坚持**不做 early return**：上一版 early return 把 BackHandler 弄挂过一次
    //    （enabled 从 false→true 时没真正挂上，按返回直接退出 App）。
    //    现在 BackHandler 在顶层、用 enabled 控制，结构始终稳定。
    val sub = page

    // 退场动画期间 `sub` 已经是 null，但内容不能跟着消失 —— 记住最后一个非空路由
    var lastSub by remember { mutableStateOf<String?>(null) }
    // 退场标记（2026-11-16）：滑出那 200ms 里 `sub` 已经是 null，BackHandler 一禁用，
    // 用户连按两次返回就会**直接退出 App**（真机上很容易按出来）。
    // 退场期间把返回键吞掉（什么都不做），退完恢复原样。
    var exiting by remember { mutableStateOf(false) }
    LaunchedEffect(sub) {
        if (sub != null) {
            lastSub = sub
            exiting = false
        } else if (lastSub != null) {
            exiting = true
            kotlinx.coroutines.delay(220)   // 比退场 200ms 多一点点，确保滑完了才放开
            exiting = false
        }
    }

    // ---------- 点一下 → 等按压弹回来 → 再跳（2026-11-16）----------
    //
    // 用户：「点击跳转的时候…你要等按下的这个弹跳的这个动作弄完才能转过去」。
    // `tapable` 是按下缩到 0.94、松手 spring 弹回，但 `clickable` 在**抬手那一瞬**
    // 就回调 → 页面立刻推入，回弹那一下根本看不见，观感是"点一下直接闪走"。
    //
    // 所以延迟放在**导航**这一层，**不动 `tapable`** —— 全 App 都在用它，
    // 还有大量非跳转的开关（切开关不该有 140ms 延迟）。
    val scope = rememberCoroutineScope()
    var navLock by remember { mutableStateOf(false) }
    // 每次发起导航 +1；真正执行前比对一次，用来"取消"已排队但还没跑的导航
    // （点了「聊天外观」又立刻按系统返回时，不能让 140ms 后那次跳转把人又拽进去）
    var navSeq by remember { mutableIntStateOf(0) }

    /**
     * 返回上一层（2026-11-16，115）。
     *
     * ⚠️ 这就是「返回自己叠自己」的根因修法：**返回不等于"去某个路由"**。
     * 以前全面写成 `go(backTo)`，而 `go` 里又会「进二级页就记 backTo = 当前页」——
     * 于是 `go(backTo)` 把 backTo 记成了当前页自己，下一次返回又回到这一页，
     * 表现就是「更多 → 服务器状态 → 返回 → 还是服务器状态」。
     * 现在返回只做两件事：`page = backTo`、`backTo = null`，**绝不记新的一层**。
     */
    fun goBack() {
        navSeq++          // 取消还没执行的排队导航
        navLock = false
        val t = backTo
        backTo = null
        page = t          // t 为 null = 回到 tab 根
    }

    /** 点一下 → 等按压的果冻弹回来 → 再跳。系统返回键不走这里（必须即回）。*/
    fun goLater(route: String?) {
        if (navLock) return
        navLock = true
        val mine = ++navSeq
        scope.launch {
            // delay 只接受 Long：navDelayMs 是 Int，必须显式转（字面量能隐式升，变量不行）
            delay(com.aevis.android.core.AnimPrefs.navDelayMs.toLong())
            if (mine == navSeq) {
                // #3（99/100）：进二级页时记住"从哪来"，返回时用 `back()` 回到那一层。
                // 115：**自引用防护** —— 要去的正好是 backTo（说明这是一次"回上一层"），
                // 就直接把它消费掉，不要再把当前页记成新的 backTo（否则原地打转）。
                if (route != null && route == backTo) {
                    backTo = null
                } else if (route != null) {
                    backTo = page
                }
                page = route
            }
            // ⚠️ 一定要在 page 赋值**之后**才解锁，否则 140ms 内连点会进两次
            navLock = false
        }
    }

    /** Dock 切 tab 同理：先让按压和胶囊动效走完再换内容。*/
    fun tabLater(i: Int) {
        if (navLock || i == idx) return
        navLock = true
        val mine = ++navSeq
        scope.launch {
            delay(com.aevis.android.core.AnimPrefs.navDelayMs.toLong())
            if (mine == navSeq) idx = i
            navLock = false
        }
    }

    // 只吞返回键、不做事：根状态下 `lastSub == null` → `exiting` 恒为 false，
    // 根页面的"返回即退出 App"行为一点没变。
    // 115：系统返回也走 `goBack()` —— 一级一级退，不会原地打转，也不会顺手记新的一层。
    BackHandler(enabled = sub != null || exiting) {
        if (sub != null) goBack()
    }

    val open by animateFloatAsState(
        targetValue = if (sub != null) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = 320f),
        label = "pageOpen"
    )

    // 位移量要在这里折算成 px —— `slideIn*` 的 lambda 里没有 Density 作用域
    val density = LocalDensity.current
    val shiftPx = with(density) { com.aevis.android.core.AnimPrefs.shiftDp.dp.toPx() }
    val pageDamping = com.aevis.android.core.AnimPrefs.damping

    Box(Modifier.fillMaxSize()) {
        // 主背景在 `MainActivity` 最外层画（整个 App 只画一次，登录页也吃同一张）；
        // 这里不再重复铺 —— 重复铺等于把背景图解码两遍。

        // ---------- 主页（常驻，二级页打开时后退一点）----------
        Box(
            Modifier.fillMaxSize().graphicsLayer {
                val s = 1f - 0.035f * open
                scaleX = s
                scaleY = s
                translationX = -26.dp.toPx() * open
                alpha = 1f - 0.32f * open
            }
        ) {
            Scaffold(
                containerColor = MaterialTheme.colorScheme.background,
                // 2026-11-14 用户：「屏幕上面它肯定有一个东西吧…你肯定是要搞一下呀」——
                // enableEdgeToEdge 之后内容会顶到状态栏底下，标题被时间和信号压住。
                // 这里把 Scaffold 自带的 inset 关掉（bottomBar 自己已经 navigationBarsPadding，
                // 不关会双倍），改由内容层显式 statusBarsPadding。
                contentWindowInsets = WindowInsets(0, 0, 0, 0),
                bottomBar = {
                    // iOS 的**悬浮胶囊 Dock**。
                    // 2026-11-14 用户：「下面那个圆圈拉长一点」「下面那个 Dock 栏可以拉长一点」——
                    // 通栏底栏 + 细分割线是最"安卓"的两个特征，所以改成：
                    // 左右留 20dp、整体 66dp 高、33dp 圆角（纯胶囊）、选中项一块淡紫胶囊。
                    // 悬浮胶囊 Dock + **流动指示器**（2026-11-15）
                    //
                    // 用户：「跟那个小白条一样直接滑过去，然后还有弹跳、果冻那种」。
                    // 所以不是每个 tab 自己画一块底色，而是**一块**指示块在两格之间滑，
                    // 滑动时横向拉长、纵向压扁（squash & stretch），停下时 spring 回弹。
                    Box(
                        Modifier.fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(horizontal = 28.dp, vertical = 10.dp)
                            .onGloballyPositioned { co ->
                                val h = with(dockDensity) { co.size.height.toDp() }
                                if (h > dockHeight) dockHeight = h
                            }
                    ) {
                        // dock 也要玻璃化（2026-11-16，112）：它是贴着背景浮着的一块，
                        // 不透明的话在照片上就是一个白膏药；玻璃时字/图标仍然有对比基底。
                        val dockSkin = appSkin()
                        BoxWithConstraints(
                            Modifier.fillMaxWidth().height(66.dp)
                                .clip(squircle(33.dp))
                                // 2026-11-24「Dock 怪怪的」：非玻璃模式下也用语义磨砂底，
                                // 跟弹窗/卡片一套质感，不再是突兀的一条实色胶囊。
                                .background(dockSkin?.barFill ?: frostedSheetColor())
                                .border(
                                    if (dockSkin == null) 0.5.dp else 1.dp,
                                    dockSkin?.cardStroke
                                        ?: MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                                    squircle(33.dp)
                                )
                                .padding(horizontal = 8.dp)
                        ) {
                            val itemW: Dp = maxWidth / tabs.size
                            // 2026-11-24：指示器改"稳一点"的滑动 —— 原来的果冻
                            // `scaleY = 2 - sx` 过冲太夸张（用户：「怪怪的」），
                            // 保留一点弹性但不再纵向压扁变形。
                            val pos by androidx.compose.animation.core.animateFloatAsState(
                                targetValue = idx.toFloat(),
                                animationSpec = androidx.compose.animation.core.spring(
                                    dampingRatio = 0.7f,
                                    stiffness = androidx.compose.animation.core.Spring.StiffnessMedium
                                ),
                                label = "dockPos"
                            )
                            Box(
                                Modifier
                                    .offset { androidx.compose.ui.unit.IntOffset((itemW * pos).roundToPx(), 0) }
                                    .width(itemW)
                                    .fillMaxHeight()
                                    .padding(horizontal = 5.dp, vertical = 9.dp)
                                    .clip(squircle(24.dp))
                                    .background(V2.accent.copy(alpha = 0.15f))
                            )

                            Row(
                                Modifier.fillMaxSize(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                tabs.forEachIndexed { i, t ->
                                    val on = idx == i
                                    val tint = if (on) V2.accent
                                    else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f)
                                    // 2026-11-24：选中放大收敛到 1.08、阻尼调高，
                                    // 不再一跳一跳地过冲（"怪怪的"主要就来自这里）
                                    val iconScale by androidx.compose.animation.core.animateFloatAsState(
                                        targetValue = if (on) 1.08f else 1f,
                                        animationSpec = androidx.compose.animation.core.spring(
                                            dampingRatio = 0.65f,
                                            stiffness = androidx.compose.animation.core.Spring.StiffnessMedium
                                        ),
                                        label = "iconScale"
                                    )
                                    Box(
                                        // 切 tab 也等按压走完（tabLater）：先让图标/胶囊的
                                        // 动效起步，再换内容，不然切 tab 是"瞬移"
                                        Modifier.weight(1f).fillMaxHeight().tapable { tabLater(i) },
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Row(
                                            Modifier.padding(horizontal = 13.dp, vertical = 7.dp),
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Box(Modifier.graphicsLayer {
                                                scaleX = iconScale; scaleY = iconScale
                                            }) {
                                                // 「我」tab 的未读小红点（只一个点，不显示数字）
                                                if (t.id == "me" && com.aevis.android.core.InboxBadge.hasUnread) {
                                                    Box(
                                                        Modifier.align(Alignment.TopEnd)
                                                            .offset(x = 3.dp, y = (-1).dp)
                                                            .size(6.dp)
                                                            .clip(CircleShape)
                                                            .background(V2.alert)
                                                    )
                                                }
                                                when (t.id) {
                                                    "chat" -> IcChat(tint, 22.dp)
                                                    "contacts" -> IcPeople(tint, 22.dp)
                                                    "discover" -> IcCompass(tint, 22.dp)
                                                    else -> IcPerson(tint, 22.dp)
                                                }
                                            }
                                            // 只有选中项带文字（窄屏 + 大字体时不撑爆）
                                            if (on) {
                                                Spacer(Modifier.width(6.dp))
                                                Text(
                                                    tr(t.title),
                                                    fontSize = 12.sp,
                                                    fontWeight = FontWeight.SemiBold,
                                                    color = tint,
                                                    maxLines = 1,
                                                    softWrap = false
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            ) { pad ->
                Box(Modifier.padding(pad).fillMaxSize().statusBarsPadding()) {
                    AnimatedContent(
                        targetState = idx,
                        transitionSpec = {
                            // 前进往下、后退往上；位移只取 shiftDp 的一半，切 tab 不该像翻页那么夸张
                            val dir = if (targetState > initialState) 1 else -1
                            (
                                fadeIn(tween(190)) +
                                    slideInVertically(
                                        animationSpec = tween(230),
                                        initialOffsetY = { (shiftPx / 2f * dir).toInt() }
                                    )
                                ).togetherWith(fadeOut(tween(120)))
                        },
                        label = "tab"
                    ) { i ->
                        // 125：**每个 tab 自己铺背景**（跟二级页同一套），切 tab 时跟着重绘
                        PageBackdrop {
                        when (i) {
                            // 所有"点了就跳"的入口都走 goLater：等按压的果冻弹回来再推页
                            // （用户原话是点通知时的观感，所以「我」页这几行尤其要对）
                            0 -> HomeTab(
                                onOpenPage = { goLater(it) },
                                // 「查看全部 N 个 →」跳到聊天 tab（首页自己切不了 tab）
                                onOpenChatList = { tabLater(1) },
                                chatTabOn = chatTabOn,
                                bottomInset = dockHeight
                            )
                            1 -> ChatTab(
                                // 「去人设广场」必须跳 `plaza`（标题「人设广场」），
                                // 别跳 `mall` —— 那是「商城」的入口，点了「去广场」看到「商城」是同一类错位
                                onFindMore = { goLater("plaza") },
                                onOpenChat = { pid -> goLater("chat:" + pid) },
                                onCreatePersona = { goLater("personanew") },
                                onCreateGroup = { goLater("groupnew") },
                                onOpenGroup = { gid -> goLater("group:" + gid) },
                                // 群资料从**列表**进来：返回目标是列表本身（backTo 清空）
                                onOpenGroupProfile = { gid ->
                                    backTo = null
                                    goLater("groupprofile:" + gid)
                                }
                            )

                            else -> MeTab(
                                onSignOut = onSignOut,
                                onOpenInbox = { goLater("inbox") },
                                onOpenAbout = { goLater("about") },
                                onOpenAccount = { goLater("account") },
                                onOpenPermission = { goLater("permission") },
                                onOpenDiary = { goLater("diary") },
                                onOpenFont = { goLater("font") },
                                onOpenModels = { goLater("models") },
                                onOpenRecharge = { goLater("recharge") }
                            )
                        }
                        }
                    }
                }
            }
        }

        // ---------- 二级页覆盖层 ----------
        AnimatedVisibility(
            visible = sub != null,
            enter = slideInHorizontally(
                animationSpec = spring(dampingRatio = pageDamping, stiffness = 330f),
                initialOffsetX = { it }
            ) + fadeIn(tween(110)),
            exit = slideOutHorizontally(
                animationSpec = tween(200),
                targetOffsetX = { it }
            ) + fadeOut(tween(160))
        ) {
            // 兜一层底色：滑动过程中不能透出下面的主页。
            // ChatScreen / GroupChatScreen 自己带背景，设置类页面靠这层兜底。
            Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
                // 页面内再套一层：chat → chatlook / persona → personaedit 这种「页中页」
                // 也要有过渡，不能硬切。这里用很轻的竖向淡入，别抢横向主转场。
                // ⚠️ 只认 `lastSub`，**不要再读 `sub`** —— 退场时 sub 已经是 null，读了就白屏。
                AnimatedContent(
                    targetState = lastSub,
                    transitionSpec = {
                        (
                            fadeIn(tween(180)) +
                                slideInVertically(
                                    animationSpec = tween(200),
                                    initialOffsetY = { shiftPx.toInt() }
                                )
                            ).togetherWith(fadeOut(tween(120)))
                    },
                    label = "subPage"
                ) { route ->
                    if (route != null) {
                        SubPageHost(
                            route = route,
                            // go / back 也走延迟：二级页里点「模型」「查看人设」这些
                            // 同样是"点了就跳"，弹回来那一下一样要看得见
                            go = { goLater(it) },
                            // 返回**不再**走 goLater（那会记 backTo）；统一 goBack()
                            back = { goBack() },
                            setBackTo = { backTo = it },
                            onSignOut = onSignOut
                        )
                    }
                }
            }
        }
    }

    // 站内信未读（2026-11-16，104）：进 Shell 拉一次（App 回前台时 MainActivity 也会再拉）
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { runCatching { com.aevis.android.core.InboxBadge.refresh() } }
    }

    // 支付半窗（2026-11-16，100）：任何地方 payOrder() 都会落到这里
    PaySheetHost()

    // ---------- 云端记录恢复半窗（2026-11-16，116）----------
    // 三态共用同一个半窗：
    //   1 = 问（云端更新 / 关了自动恢复）
    //   2 = 正在恢复（进度条，不可点外面关掉）
    //   3 = 恢复失败（原因 + 重试）
    if (restoreStage != 0) {
        val meta = restoreMeta
        ModalBottomSheet(
            onDismissRequest = {
                // 恢复中不允许滑掉 —— 不然用户会以为没在干活
                if (restoreStage != 2) restoreStage = 0
            },
            containerColor = frostedSheetColor(),
            scrimColor = frostedScrimColor()
        ) {
            Column(
                Modifier.fillMaxWidth()
                    .padding(horizontal = V2.gutter)
                    .navigationBarsPadding()
            ) {
                when (restoreStage) {
                    2 -> {
                        Text(
                            tr("正在恢复聊天记录…"),
                            fontSize = 17.sp, fontWeight = FontWeight.SemiBold
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            if (meta != null && meta.count > 0)
                                tr("云端有 %d 段对话，正在写回这台设备", meta.count)
                            else tr("正在从云端拉取"),
                            fontSize = V2.tiny,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f)
                        )
                        Spacer(Modifier.height(16.dp))
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth(),
                            color = V2.accent,
                            trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
                        )
                        Spacer(Modifier.height(20.dp))
                    }
                    3 -> {
                        Text(
                            tr("没能恢复聊天记录"),
                            fontSize = 17.sp, fontWeight = FontWeight.SemiBold
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            restoreErr.ifBlank { tr("稍后再试一次") },
                            fontSize = V2.tiny,
                            color = V2.alert.copy(alpha = 0.9f),
                            lineHeight = 18.sp
                        )
                        Spacer(Modifier.height(16.dp))
                        PrimarySheetButton(
                            tr("再试一次"), V2.accent, Color.White
                        ) {
                            if (meta != null) startRestore(meta) else restoreStage = 1
                        }
                        Spacer(Modifier.height(10.dp))
                        PrimarySheetButton(
                            tr("先不用"), null,
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f)
                        ) { restoreStage = 0 }
                        Spacer(Modifier.height(16.dp))
                    }
                    else -> {
                        Text(
                            tr("云端备份比这台设备新"),
                            fontSize = 17.sp, fontWeight = FontWeight.SemiBold
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            buildString {
                                if (meta != null && meta.count > 0) {
                                    append(tr("%d 段对话", meta.count))
                                    if (meta.bytes > 0) append(" · " + fmtBackupSize(meta.bytes))
                                    if (meta.at > 0) append(" · " + fmtBackupTime(meta.at))
                                } else {
                                    append(tr("云端有你的聊天记录"))
                                }
                            },
                            fontSize = V2.tiny,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f)
                        )
                        Spacer(Modifier.height(16.dp))
                        PrimarySheetButton(
                            tr("恢复云端"), V2.accent, Color.White
                        ) {
                            if (meta != null) startRestore(meta) else restoreStage = 0
                        }
                        Spacer(Modifier.height(10.dp))
                        PrimarySheetButton(
                            tr("保留本地"), null,
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f)
                        ) { restoreStage = 0 }
                        // 119：本地空、云端这条也没拉到（或用户不敢点）时，给一个「用恢复码」的后路。
                        // **只是提示，不强制** —— 不点它就等于关掉这个半窗。
                        if (restoreLocalEmpty) {
                            Spacer(Modifier.height(10.dp))
                            Text(
                                tr("有恢复码？点这里"),
                                fontSize = V2.tiny, color = V2.accent,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth()
                                    .tapable {
                                        restoreStage = 0
                                        showRecoverSheet = true
                                    }
                                    .padding(vertical = 8.dp)
                            )
                        }
                        Spacer(Modifier.height(16.dp))
                    }
                }
            }
        }
    }

    // 「用恢复码恢复」半窗（2026-11-16，119）：启动流程和云空间页共用同一个组件
    if (showRecoverSheet) {
        RecoverCodeSheet(
            onDismiss = { showRecoverSheet = false },
            onRecovered = { n ->
                showRecoverSheet = false
                Toast.makeText(
                    shellCtx, tr("已从恢复码恢复 %d 个会话", n), Toast.LENGTH_LONG
                ).show()
            }
        )
    }

    // 133：应用内新消息横幅（浮在最上层，不抢焦点）
    MessageBannerHost(bannerQueue) { pid ->
        com.aevis.android.core.ChatPrefs.clearProactiveUnread(pid)
        tabLater(1)
        goLater("chat:" + pid)
    }

    // ---------- 更新弹窗（2026-11-16）----------
    // 冷启动查出来的；「稍后」会把当天日期记下来，同一个版本一天只弹一次。
    updateInfo?.let { u ->
        UpdateDialog(u) {
            com.aevis.android.core.ChatPrefs.markUpdateSkipped(u.latest)
            updateInfo = null
        }
    }
}

/**
 * 半窗里的整宽按钮（2026-11-16，116）。
 *
 * ⚠️ 高度走 `heightIn(min = 48.dp)` + 上下 padding，**不写死 `height`**：
 * 用户把系统字号调到最大时，写死高度的按钮会把文字裁掉一半。
 */
@Composable
private fun PrimarySheetButton(
    text: String,
    bg: Color?,
    fg: Color,
    onClick: () -> Unit
) {
    Box(
        Modifier.fillMaxWidth()
            .clip(squircle(14.dp))
            .background(bg ?: MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f))
            .tapable { onClick() }
            .padding(horizontal = 16.dp, vertical = 14.dp)
            .heightIn(min = 48.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text, fontSize = V2.body, fontWeight = FontWeight.Medium,
            color = fg, textAlign = TextAlign.Center
        )
    }
}

/** 138.5 KB / 1.2 MB —— 云备份大小的人话写法。*/
internal fun fmtBackupSize(bytes: Long): String = when {
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / 1048576.0)
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024.0)
    bytes > 0 -> "$bytes B"
    else -> "—"
}

/** 11-16 23:26（备份时间）。*/
internal fun fmtBackupTime(at: Long): String = runCatching {
    java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.US)
        .format(java.util.Date(at))
}.getOrDefault("—")

/**
 * 二级页路由表（2026-11-16 从 `Shell` 里抽出来）。
 *
 * 为什么要抽：转场要给 `AnimatedContent` 一个「当前路由」去驱动它。
 * 如果把 `when (sub)` 留在 Shell 里，退场那 200ms 内 `sub` 已经是 null，
 * 内容会跟着消失（滑到一半白屏）。这里只认传进来的 `route`。
 *
 * `page = x` 一律换成 `go(x)`，`page = null` 换成 `back()` —— 行为完全不变，
 * 只是把"改路由"这件事收口，以后要加守卫（未登录 / 未保存提示）只改一处。
 */
/**
 * 2026-11-25 模块开关门禁：flag 关时页面不渲染，给一句说明而不是白屏。
 * 入口列表（tab / 首页宫格 / 设置行）各自也会按同一个 flag 隐藏，这里是第二道闸。
 * ⚠️ 登录 / 协议 / 线路状态**不走**这里，避免开关配错把自己锁死。
 */
@Composable
internal fun FeatureGate(flag: String, onBack: () -> Unit, content: @Composable () -> Unit) {
    if (com.aevis.android.data.Api.featureEnabled(flag)) content()
    else ComingSoonScreen(com.aevis.android.core.I18n.tr("该功能暂未开放"), onBack = onBack)
}

@Composable
private fun SubPageHost(
    route: String,
    go: (String?) -> Unit,
    back: () -> Unit,
    setBackTo: (String?) -> Unit,
    onSignOut: () -> Unit
) {
    // 125：每个二级页**自己铺背景**（不再是根容器垫一张、各页透出来）。
    // 切页时这层跟着该页重绘；图只解一次，走 `AppBackdropCache`。
    PageBackdrop {
    when {
        // 人设详情：下载 → 留在详情页（按钮变「开始聊天」）；
        //             已下载 → 进对话；「编辑这个角色」→ 本地编辑页
        // #3：返回进入前那一层（不是直接回主界面）
        route.startsWith("persona:") ->
            PersonaDetailScreen(
                pid = route.removePrefix("persona:"),
                onBack = back,
                onStartChat = { go("chat:" + it) },
                onEdit = { go("personaedit:" + it) }
            )
        // 2026-11-16 创建 / 编辑人设：同一个页面，用 existingId 区分。
        // 保存完直接进对话 —— 用户刚写完一个角色，下一步一定是想跟它说话。
        route == "personanew" ->
            PersonaEditScreen(existingId = null, onBack = back, onSaved = { go("chat:" + it) })
        // 角色设置（2026-11-16，88）：聊天页右上角 ⋯ 直接进这页
        route.startsWith("roleset:") -> {
            val rp = route.removePrefix("roleset:")
            RoleSetScreen(
                pid = rp,
                onBack = back,
                onOpenPersona = { go("personaedit:" + rp) },
                onOpenLibrary = { go("library") }
            )
        }
        route.startsWith("personaedit:") ->
            PersonaEditScreen(
                existingId = route.removePrefix("personaedit:"),
                onBack = back,
                onSaved = { go("chat:" + it) }
            )
        // 群聊（2026-11-16）：建群 / 群聊 / 加人。
        // `groupadd:` 放在 `group:` 前面判 —— 两个前缀目前互不包含，
        // 但先判"更长更像的"是稳的写法，以后再加 `groupxxx` 也不会踩。
        route == "groupnew" ->
            GroupCreateScreen(onBack = back, onCreate = { go("group:" + it) })
        route.startsWith("groupadd:") ->
            GroupAddMemberScreen(
                gid = route.removePrefix("groupadd:"),
                // 加完/返回都回到群聊页：进这页时 backTo 已经就是那个群，
                // 所以走 `back()` 即可 —— 115 起不再用 `go("group:…")`（那会把它记成新的一层）
                onBack = back,
                onDone = back
            )
        // 群资料（2026-11-16，95）：头像 + 群名。两个入口：
        //   · 聊天列表（点头像 / 长按「群资料」）→ 返回列表
        //   · 群聊里（顶栏群头像 / ⋯ 菜单）→ 返回**那个群**，不是回列表
        // 两个入口各自把 `backTo` 写好（列表那侧写 null），这里只认 `backTo`。
        route.startsWith("groupprofile:") ->
            GroupProfileScreen(
                gid = route.removePrefix("groupprofile:"),
                onBack = back
            )
        route.startsWith("group:") ->
            GroupChatScreen(
                gid = route.removePrefix("group:"),
                onBack = back,
                onAddMember = { go("groupadd:" + route.removePrefix("group:")) },
                onOpenPersona = { go("persona:" + it) },
                onOpenProfile = { gid ->
                    setBackTo("group:" + gid)
                    go("groupprofile:" + gid)
                }
            )
        // 同一个 MallScreen，两个入口用两个标题：从「商城」进来的叫商城，
        // 从「广场」进来的叫人设广场（用户得能对上自己点的是哪个）
        // 商城 / 广场（2026-11-16 起是**两套分段**，同一个 composable）：
        //   `mall`  = 商城：会员 / 音色包 / 墨点
        //   `mallpt`= 商城·墨点那一段（首页额度卡的「充值」直接落这儿）
        //   `plaza` = 广场：人设 / 表情包
        route == "mall" -> FeatureGate("shop", back) {
            MallScreen(
                onBack = back, onOpenPersona = { go("persona:" + it) },
                title = "商城", isPlaza = false
            )
        }
        route == "mallpt" -> FeatureGate("shop", back) {
            MallScreen(
                onBack = back, onOpenPersona = { go("persona:" + it) },
                title = "商城", isPlaza = false, startTab = 2
            )
        }
        route == "browser" -> BrowserScreen(onBack = back)
        route == "inbox" -> InboxScreen(onBack = back)
        route == "about" -> AboutScreen(
            onBack = back,
            onOpenChangelog = { go("changelog") },
            // 2026-11-25：线路状态基础入口永远可达，不受 serverStatus 开关影响
            onOpenServerStatus = { go("serverstatus") }
        )
        route == "changelog" -> ChangeLogScreen(onBack = back)
        route == "music" -> MusicScreen(onBack = back)
        route == "chatlook" ->
            ChatSettingsScreen(onBack = back, onOpenBackground = { go("chatbg") })
        // 聊天背景是从「聊天外观」进来的：返回走 back()，别再 go("chatlook") ——
        // 那会把 backTo 记成 chatbg 自己，于是 chatbg ⇄ chatlook 互相弹（115 修）
        route == "chatbg" -> ChatBgScreen(onBack = back)
        route == "diary" -> DiaryScreen(onBack = back)
        // 174：统一到**半窗**（有实时预览、按 pid 独立），整页版 ChatSettingsPage 不再挂路由
        route.startsWith("chatset:") -> {
            val cpid = route.removePrefix("chatset:")
            ChatSettingsSheet(
                pid = cpid,
                onOpenPersona = { go("personaedit:" + cpid) },
                onClose = { back() }
            )
        }
        route.startsWith("diary:") ->
            DiaryScreen(onBack = back, onlyPid = route.removePrefix("diary:"))
        route == "font" -> FontScreen(onBack = back)
        route == "models" -> FeatureGate("modelStatus", back) { ModelScreen(onBack = back) }
        route == "wxbind" -> WxBindScreen(onBack = back)
        route == "checkin" -> FeatureGate("growth", back) { CheckinScreen(onBack = back) }
        route == "recharge" -> FeatureGate("member", back) { RechargeScreen(onBack = back) }
        route.startsWith("chat:") -> FeatureGate("chat", back) {
            ChatScreen(
                pid = route.removePrefix("chat:"),
                onBack = back,
                onOpenRoleSet = { go("chatset:" + it) },
                onOpenPersona = { go("persona:" + it) },
                onOpenLook = { setBackTo("chat:" + it); go("chatlook") },
                onOpenDiary = { setBackTo("chat:" + it); go("diary:" + it) },
                onOpenModels = { setBackTo("chat:" + it); go("models") }
            )
        }
        // 个人账号页（2026-11-16，92）：头像+昵称点进来
        route == "account" -> AccountCardScreen(
            onBack = back,
            onOpenCloud = { go("cloud") },
            onOpenLang = { go("lang") },
            onSignOut = onSignOut
        )
        route == "lang" -> LangScreen(onBack = back)
        route == "permission" -> PermissionScreen(onBack = back)
        // 2026-11-15：这几条之前没有分支，点进去就是一片白
        route == "cloud" -> CloudScreen(onBack = back)
        route == "settingsmore" -> SettingsMoreScreen(
            onBack = back,
            onOpen = { go(it) }
        )
        // 2026-11-25：社区与活动（增长链接热更新 / 邀请码 / 活动 / 对话日志）
        route == "growth" -> FeatureGate("growth", back) { GrowthScreen(onBack = back) }
        // 线路状态属于基础入口：不受 serverStatus 开关隐藏，否则配错会把自己锁死
        route == "serverstatus" -> ServerStatusScreen(onBack = back)
        route == "settings2" -> FeatureGate("plugins", back) {
            Settings2Screen(onBack = back, onOpenPage = { go(it) })
        }
        route == "plaza" -> FeatureGate("plaza", back) {
            MallScreen(
                onBack = back, onOpenPersona = { go("persona:" + it) },
                // 2026-11-24「创建」入口：广场里能自己搓人设（本地创建）
                onCreatePersona = { go("personanew") },
                title = "广场", isPlaza = true
            )
        }
        // 2026-11-24：首页用量卡「按次计费」直接落到商城的按次 tab（index 3）
        route == "mallcall" -> FeatureGate("shop", back) {
            MallScreen(
                onBack = back, onOpenPersona = { go("persona:" + it) },
                title = "商城", isPlaza = false, startTab = 3
            )
        }
        route == "group" -> ComingSoonScreen(tr("群聊"), onBack = back)
        // 2026-11-16：表情包不再是「即将上线」，接的是能看的那一版
        route == "emoji" -> FeatureGate("stickers", back) { EmojiScreen(onBack = back) }
        // 资源库（2026-11-16，129）：本地消息里的照片 / 视频 / 文档
        route == "library" -> LibraryScreen(onBack = back)
        route == "moments" -> MomentsScreen(onBack = back)
        route == "settings" -> AnimScreen(onBack = back)
        // 兜底：路由写错 / 已下线，别留一张白屏
        else -> ComingSoonScreen(tr("这个页面"), onBack = back)
    }
    }
}

/**
 * 列表首屏入场（2026-11-16）：「整体动画」的另一半。
 *
 * 每行错峰 26ms 淡入 + 上浮 10dp，用 spring 而不是 tween，落下来才有重量感。
 *
 * ⚠️ key 用**条目 id**，不用 index：
 *   · 滚出屏幕再滚回来、数据刷新时不该重播；
 *   · 每次切 tab 都从头演一遍会让人以为界面在闪。
 * 前 12 行错峰，后面的跟第 12 行一起进 —— 长列表不该让人等 3 秒才看到全部。
 */
@Composable
internal fun EnterOnce(key: Any, index: Int, content: @Composable () -> Unit) {
    var shown by remember(key) { mutableStateOf(false) }
    LaunchedEffect(key) {
        kotlinx.coroutines.delay(index.coerceAtMost(12) * 26L)
        shown = true
    }
    val p by animateFloatAsState(
        targetValue = if (shown) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.85f, stiffness = 380f),
        label = "enterOnce"
    )
    Box(
        Modifier.graphicsLayer {
            alpha = p.coerceIn(0f, 1f)
            translationY = (1f - p) * 10.dp.toPx()
        }
    ) { content() }
}

/**
 * 本地图片地址 → 真实文件路径。
 *
 * 2026-11-16：用户自己创建/下载的角色，头像存在 `filesDir/personas/<id>.jpg`，
 * 记的是**绝对路径**（`/data/user/0/…`）。也可能有人给 `file://` 形态，
 * 两种都得能认。
 */
internal fun localImagePath(url: String): String =
    if (url.startsWith("file:")) android.net.Uri.parse(url).path.orEmpty() else url

/**
 * 这个地址是不是**本机文件**。
 *
 * ⚠️ 2026-11-16 回归 bug（用户真机截图：广场六个人设头像全是"沈/温/顾…"首字占位）：
 * 服务器返回的头像是**相对路径** `/v1/media/9f4c…jpg`，也以 `/` 开头。
 * 上一版只判 `url.startsWith("/")` 就当本地文件去 `decodeFile`，
 * 结果是 `/v1/media/x.jpg` 这种路径根本不存在 → 必然 null → 全站头像退回首字母。
 *
 * 所以这里只认**真·本地前缀**：
 *   · `file:`                                   —— 我们自己可能写成 file:// 形态
 *   · `/data/`   —— filesDir 真实路径 `/data/user/0/com.aevis.android/files/personas/x.jpg`
 *   · `/storage/`、`/sdcard/` —— 万一以后改成存外部目录
 * 其余（尤其 `/v1/media/...` 这种服务端相对路径）一律**走网络**。
 *
 * 新增本地图片目录时，记得往这里补前缀，别再图省事写 `startsWith("/")`。
 */
internal fun isLocalFile(url: String): Boolean =
    url.startsWith("file:") ||
        url.startsWith("/data/") ||
        url.startsWith("/storage/") ||
        url.startsWith("/sdcard/")

/**
 * 头像。有 URL 就真加载，没有/加载失败就用名字首字母 ——
 * 用户 2026-11-14：「这个账号的头像也不行」——之前永远是首字母，因为从来没拉过 avatar。
 */
@Composable
fun Avatar(url: String, name: String, size: Dp) {
    // 动图优先（2026-11-16，94）：本地文件 / 网络 URL 都支持 GIF、animated WebP。
    // 解码失败或不是动图就落回下面的静态位图路径（原逻辑不变）。
    val animated = rememberAnimatedAvatar(url)
    if (animated != null) {
        AvatarAnimated(animated, name, size)
        return
    }
    val appCtx = LocalContext.current.applicationContext
    var bmp by remember(url) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(url) {
        if (url.isEmpty()) { bmp = null; return@LaunchedEffect }
        // 2026-11-16：只有**真·本地路径**才读文件（用户在编辑页选的头像）。
        // ⚠️ 不能再简单判 `startsWith("/")` —— 服务端头像 `/v1/media/xxx.jpg`
        // 也以 / 开头，那样会被当成本地文件 decodeFile → null → 全站头像变首字母。
        if (isLocalFile(url)) {
            bmp = withContext(Dispatchers.IO) {
                val b = runCatching {
                    android.graphics.BitmapFactory.decodeFile(localImagePath(url))
                }.getOrNull()
                // 本地图坏了（文件被删、不是合法图片）要能一眼看出来 ——
                // 否则用户只看到首字母，分不清是"路径判错"还是"图没了"
                if (b == null) android.util.Log.w("AevisAvatar", "local decode null: $url")
                b
            }
            return@LaunchedEffect
        }
        bmp = withContext(Dispatchers.IO) {
            // 2026-11-14 用户：「你要缓存在本地…你不要每次都要拉取，要缓存在本地加密」
            // 先看加密缓存，没有再下载；下载到的转 JPEG 存回去。
            val ck = "img:" + url
            val cached = com.aevis.android.core.SecureCache.getBytes(appCtx, ck)
            if (cached != null) {
                android.graphics.BitmapFactory.decodeByteArray(cached, 0, cached.size)
            } else {
                val b = runCatching { Api.fetchImage(url) }
                    .onFailure { android.util.Log.e("AevisAvatar", "load fail: " + url, it) }
                    .getOrNull()
                if (b != null) {
                    runCatching {
                        val out = java.io.ByteArrayOutputStream()
                        b.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                        com.aevis.android.core.SecureCache.putBytes(appCtx, ck, out.toByteArray())
                    }
                }
                b
            }
        }
    }
    val f = bmp
    Box(
        Modifier.size(size).clip(CircleShape)
            .background(V2.accent.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center
    ) {
        if (f != null) {
            Image(
                bitmap = f.asImageBitmap(), contentDescription = name,
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(size).clip(CircleShape)
            )
        } else {
            // 只有真的没图、也没名字时才什么都不画（**不再固定显示 "A"**）
            val initial = name.take(1)
            if (initial.isNotBlank()) {
                Text(
                    initial, fontSize = (size.value * 0.40f).sp, color = V2.accent,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

/**
 * 页头 —— 对 iOS 的 `V2TopBar`。
 *
 * 2026-11-14 修：之前用 `V2.display`(28) + Bold 当页标题，而 iOS 是
 * `V2.title`(20) + semibold，光这一处就差 8pt，一进页面就"不是那个味"。
 * 副标题也从 14 收到 12（iOS 的 V2.tiny），透明度 0.42 对齐。
 */
@Composable
private fun Header(
    title: String,
    sub: String? = null,
    trailing: (@Composable () -> Unit)? = null
) {
    // 2026-11-16：从 Column 改成 Row —— 「聊天」页要在标题右边放一颗 ＋，
    // 原来纯 Column 的结构塞不进去，各处只能把按钮塞到下面的内容区里。
    Row(
        Modifier.fillMaxWidth().padding(
            // 2026-11-14 用户第二次说「顶部还是没有安全区」——
            // statusBarsPadding 是生效的（标题没被状态栏压住），但 Header 自己只留了 6dp，
            // 视觉上就是"贴着状态栏"。iOS 那边顶栏在 NavigationStack 的安全区之下、
            // 再叠 6pt，安卓这边没有那层，得自己补上。
            start = V2.gutter, end = V2.gutter, top = 16.dp, bottom = 10.dp
        ),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(tr(title), fontSize = V2.title, fontWeight = FontWeight.SemiBold)
            if (sub != null) {
                Spacer(Modifier.height(2.dp))
                Text(
                    tr(sub), fontSize = V2.tiny,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f)
                )
            }
        }
        if (trailing != null) trailing()
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        tr(text),
        fontSize = V2.sub, fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        modifier = Modifier.padding(
            start = V2.gutter, top = V2.sectionGap, bottom = 8.dp
        )
    )
}

/** 一行：图标 + 标题/副标题 + 右箭头。点不开的会如实说「正在接入」。*/
@Composable
private fun RowItem(
    @DrawableRes icon: Int,
    title: String,
    sub: String? = null,
    tint: Color = V2.accent,
    trailing: String? = null,
    onClick: (() -> Unit)? = null
) {
    val ctx = LocalContext.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = V2.rowHeight)
            .tapable {
                if (onClick != null) onClick()
                else Toast.makeText(ctx, "「$title」正在接入安卓版", Toast.LENGTH_SHORT).show()
            }
            // 🔴 2026-11-15 用户第三次说：「我小箭头点的这些按钮直接往右边移一点…
            //    你往右边移一点会死吗」——
            //    前两次我都以为是按钮形状的问题，实际上根因在这里：**RowItem 只有纵向
            //    内边距，横向是 0**，所以圆形图标直接贴着卡片左边缘。补上 gutter。
            .padding(horizontal = V2.gutter, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconBox(icon, tint)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Text(tr(title), fontSize = V2.body, fontWeight = FontWeight.Medium)
            if (sub != null) {
                Spacer(Modifier.height(2.dp))
                Text(tr(sub), fontSize = V2.tiny,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f))
            }
        }
        if (trailing != null) {
            Text(trailing, fontSize = V2.tiny,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.35f))
            Spacer(Modifier.width(6.dp))
        }
        Icon(
            painterResource(R.drawable.ic_row_chevron), null,
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.22f),
            modifier = Modifier.size(14.dp)
        )
    }
}

/** 一张卡里若干行，行间一条淡分割线。*/
@Composable
private fun CardGroup(content: @Composable ColumnScope.() -> Unit) {
    V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) { content() }
}

@Composable
private fun RowDivider() {
    HorizontalDivider(
        Modifier.padding(start = 66.dp),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    )
}

// ------------------------------------------------------------------ 主页

/**
 * 主页（2026-11-15，按忆伴的结构重做）。
 *
 * 用户给了 30 张截图，明确说「人家的 UI 其实做的是很完美的那种」。结构：
 *   问候头 → 用量额度卡（带进度条和折算次数）→ 服务网格 → 发现网格 → 好友横排
 *
 * 「用量额度」这块是用户反复提的「积分也看不了」——现在把墨点数和能聊几次都摊开写。
 */
@Composable
private fun HomeTab(
    onOpenPage: (String) -> Unit,
    onOpenChatList: () -> Unit,
    // 2026-11-25：chat 关时「好友」区块不渲染，避免 tab 下标错位
    chatTabOn: Boolean = true,
    // BUG-B：Dock 的实际高度（由 Shell 用 onGloballyPositioned 量出来传进来，不写死）
    bottomInset: androidx.compose.ui.unit.Dp = 0.dp
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val homeCtx = LocalContext.current
    var me by remember { mutableStateOf<Api.MeInfo?>(Api.cachedMe()) }
    // 2026-11-25：冷启动先读硬缓存立即显示，再联网刷新（对标 iOS HardCache）
    val cachedWallet = remember { com.aevis.android.core.ColdCache.loadWallet(homeCtx) }
    var points by remember { mutableIntStateOf(cachedWallet?.points ?: -1) }
    // 会员周额度（2026-11-16）：wallet 拿不到就是 null → 会员那块显示「—」，不显示 0
    var member by remember { mutableStateOf<Api.MemberQuota?>(cachedWallet?.member) }
    // 2026-11-24 用量卡：本周额度百分比（真实来自 /v1/quota/state，取不到为 null → 显示「—」）
    var quota by remember {
        mutableStateOf<Api.QuotaState?>(com.aevis.android.core.ColdCache.loadQuota(homeCtx))
    }
    var persons by remember { mutableStateOf<List<Api.Persona>>(emptyList()) }
    // 群聊入口的占位弹窗（2026-11-16，群号未给）
    var qqGroupAsk by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        runCatching { Api.me() }.getOrNull()?.let { m ->
            me = m
            Api.saveMe(m)
        }
        // 2026-11-24：额度百分比独立取，不串行等钱包（用户进主页第一眼要看到的是它）
        val freshQuota = withContext(Dispatchers.IO) { runCatching { Api.quotaState() }.getOrNull() }
        if (freshQuota != null) {
            quota = freshQuota
            withContext(Dispatchers.IO) {
                com.aevis.android.core.ColdCache.saveQuota(homeCtx, freshQuota)
            }
        }
        // 钱包：一次拿墨点 + 会员周额度。拿不到就退回 balance() 只显示墨点
        val w = withContext(Dispatchers.IO) { runCatching { Api.wallet() }.getOrNull() }
        if (w != null) {
            points = w.points
            member = w.member
            withContext(Dispatchers.IO) {
                com.aevis.android.core.ColdCache.saveWallet(homeCtx, w)
            }
        } else {
            points = withContext(Dispatchers.IO) {
                runCatching { Api.balance() }.getOrNull() ?: -1
            }
            member = null
        }
        // 2026-11-16：「好友」= 我的角色（本地下载的 + 我创建的），
        // 不再用 `Api.contacts()` —— 那是老口径，会把广场的人也带进来
        persons = withContext(Dispatchers.IO) {
            runCatching { PersonaLib.localList() }.getOrElse { emptyList() }
        }
    }

    val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    val greet = when {
        hour < 6 -> tr("夜深了")
        hour < 11 -> tr("早上好")
        hour < 14 -> tr("中午好")
        hour < 18 -> tr("下午好")
        else -> tr("晚上好")
    }

    // 底部留出 Dock 实际高度 + 16dp：否则最后一行（好友名字）被悬浮 Dock 压住
    Column(
        Modifier.fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = bottomInset + 28.dp)   // 180：16 → 28，最后一行与 Dock 至少留 20dp
    ) {

        // ---------- 顶部问候 ----------
        Row(
            Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Avatar(me?.avatar.orEmpty(), me?.nickname ?: "我", 46.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    greet, fontSize = 11.5.sp,
                    color = ink.copy(alpha = 0.42f)
                )
                Text(
                    me?.nickname?.ifBlank { tr("我") } ?: tr("我"),
                    fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 1
                )
            }
            Box(
                Modifier.size(38.dp).clip(CircleShape)
                    .background(ink.copy(alpha = 0.045f))
                    .tapable { onOpenPage("inbox") },
                contentAlignment = Alignment.Center
            ) {
                Icon(painterResource(R.drawable.ic_row_bell), null,
                    tint = ink.copy(alpha = 0.62f), modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier.size(38.dp).clip(CircleShape)
                    .background(ink.copy(alpha = 0.045f))
                    .tapable { onOpenPage("models") },
                contentAlignment = Alignment.Center
            ) {
                Icon(painterResource(R.drawable.ic_row_chart), null,
                    tint = ink.copy(alpha = 0.62f), modifier = Modifier.size(18.dp))
            }
        }

        // ---------- 用量额度卡（2026-11-24 对标参考图重做）----------
        // 大数字 = 剩余百分比；横条满时蓝色渐变、用掉部分变灰、猫头随剩余量滑动；
        // 免费用量条数 + 重置时间单独一行；墨点是独立单位，拆开显示、不参与本周额度。
        V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)) {
            // 标题行 + 两个入口胶囊
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(tr("用量额度"), fontSize = 13.sp, fontWeight = FontWeight.Medium,
                    color = ink.copy(alpha = 0.55f))
                Icon(
                    painterResource(R.drawable.ic_chevron), null,
                    tint = ink.copy(alpha = 0.35f), modifier = Modifier.size(14.dp)
                )
                Spacer(Modifier.weight(1f))
                // 2026-11-25：会员 / 商城入口按 flag 门禁（默认关）
                if (Api.featureEnabled("member")) {
                    // 用量提升：黄底猫头，跳会员 / 套餐页
                    Row(
                        Modifier.clip(squircle(9.dp))
                            .background(Color(0xFFFFD66B))
                            .tapable { onOpenPage("mall") }
                            .padding(horizontal = 8.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_cat_line), null,
                            tint = Color(0xFF6B4E00), modifier = Modifier.size(15.dp)
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(tr("用量提升"), fontSize = 10.5.sp,
                            fontWeight = FontWeight.SemiBold, color = Color(0xFF4A3600))
                    }
                    Spacer(Modifier.width(6.dp))
                }
                if (Api.featureEnabled("shop")) {
                    // 按次计费：黄底 + NEW 红标，跳商城「按次」tab
                    Box(
                        Modifier.clip(squircle(9.dp))
                            .background(Color(0xFFFFD66B))
                            .tapable { onOpenPage("mallcall") }
                            .padding(horizontal = 8.dp, vertical = 5.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(tr("按次计费"), fontSize = 10.5.sp,
                                fontWeight = FontWeight.SemiBold, color = Color(0xFF4A3600))
                            Spacer(Modifier.width(4.dp))
                            Text(
                                "NEW", fontSize = 7.5.sp, fontWeight = FontWeight.Bold,
                                color = Color.White,
                                modifier = Modifier.clip(squircle(4.dp))
                                    .background(Color(0xFFE5484D))
                                    .padding(horizontal = 3.dp, vertical = 1.dp)
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(12.dp))

            // 大数字：剩余百分比（真实来自 quota；取不到显示「—」）
            val q = quota
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Text(
                    if (q != null) "${q.leftPct}%" else "—",
                    fontSize = 40.sp, fontWeight = FontWeight.Bold,
                    color = ink, letterSpacing = (-2).sp
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    if (q != null) tr("已用 %d%%", q.percent) else tr("额度暂时取不到"),
                    fontSize = 11.5.sp, color = ink.copy(alpha = 0.45f),
                    modifier = Modifier.padding(bottom = 7.dp)
                )
            }
            Spacer(Modifier.height(12.dp))

            // 横条：满（剩余 100%）蓝色渐变满色；已用部分变灰；猫头末端随剩余量滑动
            val leftFrac = if (q != null) (q.leftPct.coerceIn(0, 100)) / 100f else 1f
            BoxWithConstraints(
                Modifier.fillMaxWidth().height(12.dp)
                    .clip(squircle(7.dp))
                    .background(ink.copy(alpha = 0.10f))
            ) {
                // 用掉的部分（右侧）灰色：整条是灰底，左侧覆盖蓝色渐变 = 剩余
                Box(
                    Modifier.fillMaxWidth(leftFrac).fillMaxHeight()
                        .clip(squircle(7.dp))
                        .background(
                            androidx.compose.ui.graphics.Brush.horizontalGradient(
                                listOf(Color(0xFF6FA8E8), Color(0xFF9B8AF0))
                            )
                        )
                )
                // 猫头终点：随剩余量滑动
                Icon(
                    painterResource(R.drawable.ic_cat_line), null,
                    tint = Color.White,
                    modifier = Modifier
                        .offset(x = with(LocalDensity.current) {
                            (maxWidth * leftFrac).toPx().toDp() - 14.dp
                        }.coerceAtLeast(0.dp))
                        .size(14.dp)
                        .align(Alignment.CenterStart)
                )
            }
            Spacer(Modifier.height(10.dp))

            // 底部：左 = 本周剩余额度折成的条数，右 = 重置时间（取不到不显示）
            // 口径照 iOS：① quota.est_messages（服务端，会员/免费都对）→
            //            ② 免费基线 15 × 剩余百分比 → ③ 断网也无基线时显示「—」
            val freeBaseline = 15
            val leftMessages = when {
                q != null && q.estMessages > 0 -> q.estMessages
                q != null -> (freeBaseline * q.leftPct / 100.0).let { n ->
                    if (n > 0) kotlin.math.round(n).toInt() else 0
                }
                else -> -1   // 没拿到额度，不写死条数
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (leftMessages >= 0) tr("您大约还有 %d 条消息额度", leftMessages)
                    else tr("您大约还有 — 条消息额度"),
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.62f)
                )
                Spacer(Modifier.weight(1f))
                val reset = q?.resetAt.orEmpty()
                if (reset.isNotEmpty()) {
                    Text(
                        tr("%s 重置", reset),
                        fontSize = V2.micro, color = ink.copy(alpha = 0.42f)
                    )
                }
            }

            // 墨点：独立单位，拆开显示，不参与本周额度计算
            HorizontalDivider(
                Modifier.padding(vertical = 10.dp),
                thickness = 0.5.dp, color = ink.copy(alpha = 0.08f)
            )
            if (Api.featureEnabled("shop")) {
                Row(
                    Modifier.fillMaxWidth().tapable { onOpenPage("mallpt") },
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        tr("墨点余额"), fontSize = V2.tiny, color = ink.copy(alpha = 0.55f)
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        if (points >= 0) "$points" else "—",
                        fontSize = V2.sub, fontWeight = FontWeight.SemiBold,
                        color = pointAccentColor()
                    )
                    Spacer(Modifier.width(4.dp))
                    Icon(
                        painterResource(R.drawable.ic_chevron_right), null,
                        tint = ink.copy(alpha = 0.3f), modifier = Modifier.size(14.dp)
                    )
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        // ---------- 服务 ----------
        SectionTitle(tr("服务"))
        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            // 7 格 = 4 + 3（「表情」2026-11-16 撤掉，表情包入口收进「广场」里了）。
            // 用 weight(1f) 保证**四列等宽**：第一行 4 个，第二行 3 个 + 1 个空位。
            // 8 格 = 4 + 4（2026-11-16 加「云空间」，用户：「服务这里加一个云服务」）。
            Row(Modifier.fillMaxWidth()) {
                // 路由口径：`mall` = 商城、`plaza` = 广场、`mallpt` = 商城·墨点那一段、
                // `cloud` = 云空间。判断"该跳哪个"看用户点的那颗按钮叫什么。
                // 2026-11-25：每个宫格按对应 flag 隐藏（默认全关是预期）
                if (Api.featureEnabled("shop"))
                    HomeIcon(tr("商城"), R.drawable.ic_tab_contacts, Modifier.weight(1f)) { onOpenPage("mall") }
                if (Api.featureEnabled("stickers"))
                    HomeIcon(tr("装扮"), R.drawable.ic_row_emoji, Modifier.weight(1f)) { onOpenPage("chatlook") }
                HomeIcon(tr("日记"), R.drawable.ic_row_diary, Modifier.weight(1f)) { onOpenPage("diary") }
                if (Api.featureEnabled("modelStatus"))
                    HomeIcon(tr("模型"), R.drawable.ic_row_chart, Modifier.weight(1f)) { onOpenPage("models") }
            }
            Spacer(Modifier.height(6.dp))
            Row(Modifier.fillMaxWidth()) {
                HomeIcon(tr("云空间"), R.drawable.ic_row_layers, Modifier.weight(1f)) { onOpenPage("cloud") }
                // 「会员」跟「商城」进同一个页面（商城第一段就是会员），标题都是「商城」
                if (Api.featureEnabled("member"))
                    HomeIcon(tr("会员"), R.drawable.ic_row_persona, Modifier.weight(1f)) { onOpenPage("mall") }
                HomeIcon(tr("字体"), R.drawable.ic_row_emoji, Modifier.weight(1f)) { onOpenPage("font") }
                // 「更多」是基础设置入口，保持可达（里面有线路状态）
                HomeIcon(tr("更多"), R.drawable.ic_row_status, Modifier.weight(1f)) { onOpenPage("settingsmore") }
            }
        }

        Spacer(Modifier.height(16.dp))

        // ---------- 发现 ----------
        SectionTitle(tr("发现"))
        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            Row(Modifier.fillMaxWidth()) {
                if (Api.featureEnabled("plaza"))
                    HomeIcon(tr("广场"), R.drawable.ic_tab_contacts, Modifier.weight(1f)) { onOpenPage("plaza") }
                HomeIcon(tr("朋友圈"), R.drawable.ic_tab_chat, Modifier.weight(1f)) { onOpenPage("moments") }
                if (Api.featureEnabled("growth"))
                    HomeIcon(tr("签到"), R.drawable.ic_row_bell, Modifier.weight(1f)) { onOpenPage("checkin") }
                // 群聊：2026-11-16 改成进 QQ 群（群号还没给，先弹说明，不编群号）
                HomeIcon(tr("群聊"), R.drawable.ic_tab_chat, Modifier.weight(1f)) { qqGroupAsk = true }
            }
        }

        Spacer(Modifier.height(16.dp))

        // ---------- 好友（2026-11-16 改成一行一个）----------
        // 用户：横排头像只看得见小字，认不出谁是谁 → 换成聊天列表那种行：
        // 44dp 头像 + 名字（15sp Medium）+ chevron，行高 60dp，卡内 0.5dp 分割线。
        // 最多 5 行，多的收成「查看全部 N 个 →」（跳到聊天 tab）。
        if (chatTabOn && persons.isNotEmpty()) {
            SectionTitle(tr("好友"))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                persons.take(5).forEachIndexed { i, p ->
                    if (i > 0) Box(
                        Modifier.fillMaxWidth().height(0.5.dp)
                            .background(ink.copy(alpha = 0.07f))
                    )
                    Row(
                        // 116：60dp 是"正常字号下的好看高度"，改成最小高度 + 上下留白，
                        // 系统字号拉满时两行字才不会被裁掉。
                        Modifier.fillMaxWidth().heightIn(min = 60.dp)
                            .tapable { onOpenPage("chat:" + p.id) }
                            .padding(horizontal = V2.gutter, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Avatar(p.avatar, p.name, 44.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(
                            p.name, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                            maxLines = 1, modifier = Modifier.weight(1f)
                        )
                        Icon(
                            painterResource(R.drawable.ic_row_chevron), null,
                            tint = ink.copy(alpha = 0.25f),
                            modifier = Modifier.size(14.dp).rotate(180f)
                        )
                    }
                }
                if (persons.size > 5) {
                    Box(
                        Modifier.fillMaxWidth().height(0.5.dp)
                            .background(ink.copy(alpha = 0.07f))
                    )
                    Row(
                        Modifier.fillMaxWidth()
                            .tapable { onOpenChatList() }
                            .padding(horizontal = V2.gutter, vertical = 13.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            tr("查看全部 %d 个 →", persons.size),
                            fontSize = V2.tiny, color = V2.accent,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(28.dp))
    }

    // ---------- 群聊入口（2026-11-16 先占位）----------
    // 用户要「发现 → 群聊」进 QQ 群。**群号和链接还没给**，所以这里只弹一句说明，
    // 绝不编一个群号 —— 编了用户点进去是个空群 / 错群，比没有入口更糟。
    // 拿到真实群号后把 `知道了` 换成 `Intent(ACTION_VIEW, Uri.parse("mqqapi://…"))` 即可。
    if (qqGroupAsk) {
        AlertDialog(
            onDismissRequest = { qqGroupAsk = false },
            title = { Text(tr("去 QQ 群聊？")) },
            text = {
                Text(
                    tr("群号和链接还在配，配好就放上来。"),
                    fontSize = V2.sub
                )
            },
            confirmButton = {
                TextButton(onClick = { qqGroupAsk = false }) { Text(tr("知道了")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }
}

/**
 * 首页九宫格里的一格（2026-11-16 改版）。
 *
 * 用户截图指出的问题：「一看就是安卓味」的来源之一是那排**彩色圆角底**图标
 * （商城黄 / 装扮紫 / 日记蓝…），八个颜色一起很花。现在改成：
 *   · **透明底**，只有一个线性单色图标 22dp；
 *   · 颜色用 `onSurface@0.82` —— 深色自动白、浅色自动黑，跟着主题走；
 *   · 整格 56dp 高、由外层 Row 用 `weight(1f)` 保证四列等宽。
 */
@Composable
private fun HomeIcon(
    label: String,
    icon: Int,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        // 四列等宽靠调用方传 `Modifier.weight(1f)`（`weight` 是 RowScope 的，
        // 这里拿不到，也不该在这里假设自己一定在 Row 里）
        // 116：最小高度而不是固定高度 —— 字号拉满时图标 + 一行字会超 56dp。
        modifier = modifier.heightIn(min = 56.dp).tapable { onClick() }
            .padding(vertical = 6.dp)
    ) {
        Icon(
            painterResource(icon), null,
            tint = ink.copy(alpha = 0.82f), modifier = Modifier.size(22.dp)
        )
        Spacer(Modifier.height(5.dp))
        Text(
            label, fontSize = 11.sp, color = ink.copy(alpha = 0.62f),
            maxLines = 1
        )
    }
}

// ------------------------------------------------------------------ 聊天

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun ChatTab(
    onFindMore: () -> Unit,
    onOpenChat: (String) -> Unit,
    onCreatePersona: () -> Unit,
    onCreateGroup: () -> Unit,
    onOpenGroup: (String) -> Unit,
    // 群资料（头像 / 群名）——2026-11-16，95
    onOpenGroupProfile: (String) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var list by remember { mutableStateOf<List<Api.Persona>?>(null) }
    // 群（2026-11-16）：纯本地数据，不用等网络
    var groups by remember { mutableStateOf<List<GroupStore.Group>>(emptyList()) }
    var q by remember { mutableStateOf("") }
    // 「＋」的下拉菜单（2026-11-16）
    var plusMenu by remember { mutableStateOf(false) }
    // 长按某行 → 动作菜单 / 二次确认（2026-11-16）
    var askDelete by remember { mutableStateOf<ChatListRow?>(null) }
    var rowConfirm by remember { mutableStateOf<ConfirmAsk?>(null) }
    // 清空后要重排列表：`mixed` 的 remember 靠它变化才会重算
    var sortTick by remember { mutableIntStateOf(0) }

    // 扫一扫：跟「我」页那一行同一个入口（扫电脑上的登录码，给网页授权）。
    // 这里复制一份 launcher 是刻意的 —— 它是 `remember` 出来的，没法跨 Composable 复用。
    val scanLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { res ->
        if (res.resultCode == Activity.RESULT_OK) {
            val raw = res.data?.getStringExtra("code").orEmpty()
            val ticket = parseScanTicket(raw)
            if (ticket.isEmpty()) {
                Toast.makeText(ctx, tr("这不是 Aevis 的登录码"), Toast.LENGTH_LONG).show()
            } else {
                (ctx as? com.aevis.android.MainActivity)?.handleScanTicket(ticket)
            }
        }
    }

    // 2026-11-15：以前这里是**一张空卡片**（"还没有会话"），点了没反应 ——
    // 整个聊天功能是断的。现在列「群 + 我的角色」，点进去就是对话。
    //
    // 2026-11-16：数据源从 `Api.contacts()` 换成 `PersonaLib.localList()` ——
    // 用户要求「广场只浏览，下载才进我的」，所以这里只该有
    // **下载到本地的 + 我自己创建的**，广场上没下载的一个都不该出现。
    LaunchedEffect(Unit) {
        groups = GroupStore.all()
        list = withContext(Dispatchers.IO) {
            runCatching { PersonaLib.localList() }.getOrElse { emptyList() }
        }
    }

    // 群资料页改完头像/群名返回时要能立刻看到（2026-11-16，95）：
    // 二级页关闭时这个 Composable 不会重建，只能靠 `GroupStore.version` 主动通知。
    val groupsVer = GroupStore.version
    LaunchedEffect(groupsVer) {
        groups = GroupStore.all()
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        // 右上角「＋」：新建群聊 / 创建人设 / 扫一扫。
        // 注意**没有**「加人」—— 加人必须有个群做上下文，列表页没有，
        // 放一个灰的选项只会让人点不动还不知道为什么。加人只在群聊页的 ⋯ 菜单里。
        Header("聊天", "点一个人就进对话", trailing = {
            Box {
                Box(
                    Modifier.size(38.dp).clip(CircleShape)
                        .background(ink.copy(alpha = 0.045f))
                        .tapable { plusMenu = true },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        painterResource(R.drawable.ic_tab_plus), null,
                        tint = ink.copy(alpha = 0.62f),
                        modifier = Modifier.size(18.dp)
                    )
                }
                DropdownMenu(expanded = plusMenu, onDismissRequest = { plusMenu = false }) {
                    DropdownMenuItem(
                        text = { Text(tr("新建群聊"), fontSize = V2.body) },
                        onClick = { plusMenu = false; onCreateGroup() }
                    )
                    DropdownMenuItem(
                        text = { Text(tr("创建人设"), fontSize = V2.body) },
                        onClick = { plusMenu = false; onCreatePersona() }
                    )
                    DropdownMenuItem(
                        text = { Text(tr("扫一扫"), fontSize = V2.body) },
                        onClick = {
                            plusMenu = false
                            scanLauncher.launch(
                                Intent(ctx, com.aevis.android.ui.CameraScanActivity::class.java)
                            )
                        }
                    )
                }
            }
        })

        // 搜索（95 起左侧带一颗放大镜 —— 只有一个灰框的输入框在真机上认不出是搜索）
        Row(
            Modifier.padding(horizontal = V2.gutter, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                Modifier.weight(1f).clip(squircle(12.dp))
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    painterResource(R.drawable.ic_search), null,
                    tint = ink.copy(alpha = 0.3f),
                    modifier = Modifier.size(16.dp)
                )
                Spacer(Modifier.width(8.dp))
                BasicTextField(
                    value = q, onValueChange = { q = it }, singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(
                        fontSize = 14.5.sp, color = ink
                    ),
                    decorationBox = { inner ->
                        if (q.isEmpty()) {
                            Text(tr("搜名字"), fontSize = 14.5.sp,
                                color = ink.copy(alpha = 0.32f))
                        }
                        inner()
                    },
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }

        // ---------- 会话列表（2026-11-16 改成微信那种混排）----------
        // 用户明确要求：群和人**混在一起**，按最后聊天时间倒序，不要分组标题。
        // 排序 key：有会话 → `Api.convAt(id)`（每次 saveConv 记一次）；
        //           没会话 → 群用 `group.updatedAt`、人用本地角色 `updatedAt`，垫在后面。
        val persons = list.orEmpty()
        val mixed = remember(persons, groups, q, sortTick) {
            val out = ArrayList<ChatListRow>()
            groups.forEach { g ->
                if (q.isNotBlank() && !g.name.contains(q, true)) return@forEach
                val conv = Api.convAt(g.id)
                out.add(ChatListRow(g.id, g, null, if (conv > 0) conv else g.updatedAt))
            }
            persons.forEach { p ->
                if (q.isNotBlank() && !p.name.contains(q, true)) return@forEach
                val conv = Api.convAt(p.id)
                val fallback = LocalPersonaStore.find(p.id)?.updatedAt ?: 0L
                out.add(ChatListRow(p.id, null, p, if (conv > 0) conv else fallback))
            }
            out.sortedByDescending { it.at }
        }

        when {
            list == null -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Text(tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.4f),
                    modifier = Modifier.padding(vertical = 20.dp))
            }

            // 群也没有、人也没有 —— 这才是真正的空（要给出去广场的引导）
            mixed.isEmpty() && q.isBlank() -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Column(
                    Modifier.fillMaxWidth().padding(vertical = 26.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(tr("还没有自己的角色"), fontSize = V2.body,
                        fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(6.dp))
                    // 2026-11-16 改了引导语：现在的流程是「广场下载 → 才进这里」，
                    // 让人先知道去哪儿、点什么，而不是停在一句没有出路的空话上
                    Text(tr("去广场挑一个，点「下载到本地」就出现在这里"),
                        fontSize = V2.tiny, color = ink.copy(alpha = 0.45f))
                    Spacer(Modifier.height(14.dp))
                    Text(
                        tr("去人设广场"),
                        fontSize = V2.sub, fontWeight = FontWeight.Medium,
                        color = V2.accent,
                        modifier = Modifier
                            .clip(squircle(14.dp))
                            .background(V2.accent.copy(alpha = 0.12f))
                            .tapable { onFindMore() }
                            .padding(horizontal = 18.dp, vertical = 9.dp)
                    )
                }
            }

            // 搜索没命中
            mixed.isEmpty() -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Text(tr("没搜到"), fontSize = V2.tiny, color = ink.copy(alpha = 0.45f),
                    modifier = Modifier.padding(vertical = 20.dp))
            }

            else -> V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                mixed.forEachIndexed { i, row ->
                    if (i > 0) Box(
                        Modifier.fillMaxWidth().height(0.5.dp)
                            .background(ink.copy(alpha = 0.07f))
                    )
                    // 首屏错峰淡入（2026-11-16）：key 用 id，滚动/刷新不重播
                    EnterOnce(row.id, i) {
                        val g = row.group
                        if (g != null) {
                            GroupRow(
                                g = g, persons = persons,
                                onOpen = { onOpenGroup(row.id) },
                                onLong = { askDelete = row },
                                onProfile = { onOpenGroupProfile(row.id) }
                            )
                        } else {
                            PersonRow(
                                p = row.person ?: return@EnterOnce,
                                onOpen = { onOpenChat(row.id) },
                                onLong = { askDelete = row }
                            )
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(24.dp))

        // ---------- 长按 → 小菜单（2026-11-16）----------
        // 用户原话：「删除好友要加」。所以不只清空聊天记录，还要能真删：
        //   群行：清空聊天记录 / 解散群聊
        //   人行：清空聊天记录 / 删除这个角色
        // 两个删除动作都再过一道 `AlertDialog` 二次确认（文案写清后果），
        // 因为这两件事都不可逆 —— 误触长按不该直接删掉东西。
        val menuRow = askDelete
        if (menuRow != null) {
            val isGroup = menuRow.group != null
            ModalBottomSheet(
                onDismissRequest = { askDelete = null },
                containerColor = frostedSheetColor(),
                scrimColor = frostedScrimColor()
            ) {
                Column(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = V2.gutter)
                        .navigationBarsPadding()
                ) {
                    Text(
                        menuRow.group?.name ?: menuRow.person?.name.orEmpty(),
                        fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 1
                    )
                    Spacer(Modifier.height(10.dp))
                    MenuAction(tr("清空聊天记录")) {
                        rowConfirm = ConfirmAsk(menuRow, RowAction.CLEAR)
                        askDelete = null
                    }
                    // 群资料（2026-11-16，95）：换群头像 / 改群名
                    if (isGroup) {
                        MenuAction(tr("群资料")) {
                            askDelete = null
                            onOpenGroupProfile(menuRow.id)
                        }
                    }
                    MenuAction(
                        if (isGroup) tr("解散群聊") else tr("删除这个角色"),
                        danger = true
                    ) {
                        rowConfirm = ConfirmAsk(
                            menuRow, if (isGroup) RowAction.DISSOLVE else RowAction.REMOVE
                        )
                        askDelete = null
                    }
                    MenuAction(tr("取消")) { askDelete = null }
                    Spacer(Modifier.height(14.dp))
                }
            }
        }

        // 二次确认
        val ask = rowConfirm
        if (ask != null) {
            val isGroup = ask.row.group != null
            AlertDialog(
                onDismissRequest = { rowConfirm = null },
                title = {
                    Text(
                        when (ask.action) {
                            RowAction.CLEAR ->
                                if (isGroup) tr("清空这个群聊？") else tr("清空这个对话？")
                            RowAction.DISSOLVE -> tr("解散这个群聊？")
                            RowAction.REMOVE -> tr("删除这个角色？")
                        }
                    )
                },
                text = {
                    Text(
                        when (ask.action) {
                            RowAction.CLEAR ->
                                tr("只删聊天记录，%s 还留在这里。",
                                    if (isGroup) tr("群") else tr("角色"))
                            RowAction.DISSOLVE ->
                                tr("群和里面的聊天记录都会删掉，删了就找不回来了。")
                            RowAction.REMOVE ->
                                tr("只删本地这份，广场上的人设还在；这个对话记录也一起删掉。")
                        },
                        fontSize = V2.sub
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        val id = ask.row.id
                        when (ask.action) {
                            RowAction.CLEAR -> Api.clearConv(id)
                            RowAction.DISSOLVE -> {
                                GroupStore.remove(id)
                                Api.clearConv(id)
                            }
                            RowAction.REMOVE -> {
                                LocalPersonaStore.remove(id)
                                Api.clearConv(id)
                                // 立刻从「我的角色」里拿掉，不等重新进页面
                                list = list?.filterNot { it.id == id }
                            }
                        }
                        rowConfirm = null
                        // 时间戳/条目变了 → 排序要重算
                        sortTick++
                        groups = GroupStore.all()
                    }) {
                        Text(
                            if (ask.action == RowAction.CLEAR) tr("清空") else tr("删除"),
                            color = V2.alert
                        )
                    }
                },
                dismissButton = {
                    TextButton(onClick = { rowConfirm = null }) { Text(tr("取消")) }
                },
                containerColor = MaterialTheme.colorScheme.surface
            )
        }
    }
}

/** 长按菜单里的一行（2026-11-16）。*/
@Composable
private fun MenuAction(label: String, danger: Boolean = false, onClick: () -> Unit) {
    Text(
        label, fontSize = V2.body,
        color = if (danger) V2.alert else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.fillMaxWidth()
            .clip(squircle(12.dp))
            .tapable { onClick() }
            .padding(horizontal = 12.dp, vertical = 14.dp)
    )
}

/** 长按菜单里的动作（2026-11-16）。*/
private enum class RowAction { CLEAR, DISSOLVE, REMOVE }

/** 「哪个会话 + 要做什么」——二次确认弹窗用。*/
private data class ConfirmAsk(val row: ChatListRow, val action: RowAction)

/**
 * 导入预检的统一载体（2026-11-16，124）。
 *
 * `full != null` = 整机搬家包（manifest.ver == 2，走 `FullBackup.apply`）；
 * 否则 `legacy` = 117 那版聊天 ZIP / 更老的 JSON（走 `ChatArchive.apply`）。
 */
private class PendingImport(
    val full: com.aevis.android.core.FullBackup.Plan?,
    val legacy: com.aevis.android.core.ChatArchive.Plan?,
    val roles: Int,
    val convs: Int,
    val msgs: Int,
    val images: Int,
    val bgs: Int,
    val note: String
)

/** 聊天列表的一行：群或人（2026-11-16 混排用，两者共用一套排序）。*/
private data class ChatListRow(
    val id: String,
    val group: GroupStore.Group?,
    val person: Api.Persona?,
    val at: Long
)

/**
 * 人设会话行（2026-11-16 从 ChatTab 里抽出来）：头像 + 名字 + 最后一句 + 箭头。
 * 长按 = 清空这个对话（跟群行同一个交互）。
 */
@Composable
private fun PersonRow(p: Api.Persona, onOpen: () -> Unit, onLong: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth()
            .tapable(onLongClick = onLong) { onOpen() }
            .padding(horizontal = V2.gutter, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Avatar(p.avatar, p.name, 46.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.name, fontSize = V2.body, fontWeight = FontWeight.Medium, maxLines = 1)
                // 123：恢复出来的「孤儿角色」（只有消息、没有人设）标一个浅色「待完善」，
                // 提示用户去补人设；不弹窗、不拦路。
                val needFill = remember(p.id) {
                    LocalPersonaStore.find(p.id)?.origin == "restore"
                }
                // 132：「TA 找你了」——主动唤醒投递过来还没看的那几条
                @Suppress("UNUSED_VARIABLE")
                val pv = com.aevis.android.core.ChatPrefs.proactiveVersion
                val hit = com.aevis.android.core.ChatPrefs.proactiveUnread(p.id)
                if (hit > 0) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        tr("TA 找你了"), fontSize = 9.5.sp, color = V2.accent,
                        maxLines = 1,
                        modifier = Modifier.clip(squircle(5.dp))
                            .background(V2.accent.copy(alpha = 0.12f))
                            .padding(horizontal = 5.dp, vertical = 1.5.dp)
                    )
                }
                if (needFill) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        tr("待完善"), fontSize = 9.5.sp, color = ink.copy(alpha = 0.55f),
                        maxLines = 1,
                        modifier = Modifier.clip(squircle(5.dp))
                            .background(ink.copy(alpha = 0.07f))
                            .padding(horizontal = 5.dp, vertical = 1.5.dp)
                    )
                }
            }
            val last = remember(p.id) {
                runCatching { Api.loadConv(p.id).lastOrNull() }.getOrNull()
            }
            Text(
                // 表情包消息 content 是空的，显示成「[表情]」比空白好。
                // ⚠️ 没有会话时**不要回落 tagline** —— 本地角色的 tagline 是人设提示词原文，
                //    显示在列表里就是把系统提示词漏给用户（2026-11-16 修）。
                when {
                    last == null -> tr("还没有聊过")
                    last.img.isNotEmpty() -> tr("[表情]")
                    else -> last.content
                },
                fontSize = V2.tiny, maxLines = 1,
                color = ink.copy(alpha = 0.45f)
            )
        }
        Icon(
            painterResource(R.drawable.ic_row_chevron), null,
            tint = ink.copy(alpha = 0.25f),
            modifier = Modifier.size(14.dp).rotate(180f)
        )
    }
}

/**
 * 群会话行（2026-11-16）。
 *
 * 结构跟人那行一致（左头像 / 中名字 + 副标题 / 右箭头）。
 *
 * 左边（95 起）：设过群头像就用群头像；没设过才退回「叠三个成员头像」的画法
 * —— 群没有单一形象时用成员拼出来最快认出是哪个群，但一旦用户自己设了头像，
 * 那个头像才是他认群的第一眼。点头像直接进群资料（改头像 / 名字）。
 *
 * 长按 = 清空这个群的会话 / 解散 / 进群资料（跟人那行同一个交互）。
 */
@Composable
private fun GroupRow(
    g: GroupStore.Group,
    persons: List<Api.Persona>,
    onOpen: () -> Unit,
    onLong: () -> Unit,
    onProfile: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val members = g.memberIds.mapNotNull { id -> persons.firstOrNull { it.id == id } }
    // 最后一条消息读一次就够（群被改过 `updatedAt` 才重读）
    val last = remember(g.id, g.updatedAt) {
        runCatching { Api.loadConv(g.id).lastOrNull() }.getOrNull()
    }
    val sub = if (last == null) {
        tr("%d 人 · 还没有聊过", g.memberIds.size)
    } else {
        // 「谁：说了什么」，截 20 字 —— 跟微信的会话列表一个读法。
        // 表情包消息 content 是空的，显示「[表情]」而不是一对空冒号。
        val who = if (last.role == "user") tr("我")
        else members.firstOrNull { it.id == last.who }?.name.orEmpty().ifEmpty { tr("有人") }
        val body = if (last.img.isNotEmpty()) tr("[表情]")
        else last.content.replace("\n", " ").take(20)
        "$who：$body"
    }

    Row(
        Modifier.fillMaxWidth()
            .tapable(onLongClick = onLong) { onOpen() }
            .padding(horizontal = V2.gutter, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.tapable { onProfile() }) {
            if (g.avatar.isNotEmpty()) {
                Avatar(g.avatar, g.name, 46.dp)
            } else {
                GroupStack(members)
            }
        }
        Spacer(Modifier.width(12.dp))

        Column(Modifier.weight(1f)) {
            Text(
                g.name, fontSize = V2.body, fontWeight = FontWeight.Medium, maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
            Text(
                sub, fontSize = V2.tiny, maxLines = 1,
                color = ink.copy(alpha = 0.45f),
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
        }
        Icon(
            painterResource(R.drawable.ic_row_chevron), null,
            tint = ink.copy(alpha = 0.25f),
            modifier = Modifier.size(14.dp).rotate(180f)
        )
    }
}

/** 群的头像拼贴：最多三个，压住 9dp；多出来的折成「+n」小方块。*/
@Composable
private fun GroupStack(members: List<Api.Persona>) {
    val ink = MaterialTheme.colorScheme.onSurface
    if (members.isEmpty()) {
        Box(
            Modifier.size(46.dp).clip(squircle(14.dp)).background(ink.copy(alpha = 0.07f)),
            contentAlignment = Alignment.Center
        ) { Text(tr("群"), fontSize = 14.sp, color = ink.copy(alpha = 0.5f)) }
        return
    }
    val shown = members.take(3)
    val size = 26.dp
    val step = 17.dp          // 26 - 9 = 每个压住 9dp
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(width = size + step * (shown.size - 1), height = size)) {
            shown.forEachIndexed { i, m ->
                Box(
                    Modifier.offset(x = step * i).size(size).clip(CircleShape)
                        .border(1.2.dp, MaterialTheme.colorScheme.surface, CircleShape)
                ) { Avatar(m.avatar, m.name, size) }
            }
        }
        if (members.size > shown.size) {
            Spacer(Modifier.width(5.dp))
            // 「+n」用小圆角方块而不是圆：一排圆头像后面再来一个圆，
            // 会被当成"第 4 个成员"，方形一眼就知道是计数
            Box(
                Modifier.size(24.dp).clip(squircle(8.dp)).background(ink.copy(alpha = 0.10f)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    "+${members.size - shown.size}", fontSize = 9.sp,
                    color = ink.copy(alpha = 0.6f), fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun ContactsTab(onFindMore: () -> Unit) {
    var list by remember { mutableStateOf<List<Api.Persona>?>(null) }
    val ink = MaterialTheme.colorScheme.onSurface

    LaunchedEffect(Unit) {
        // 2026-11-16：这页目前 Shell 没挂（`ContactsTab` 是死代码），
        // 但数据源也一并改成「我的角色」—— 留着 `Api.contacts()` 就是留个口径不一致的坑
        list = withContext(Dispatchers.IO) {
            runCatching { PersonaLib.localList() }.getOrElse { emptyList() }
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("通讯录", "你的 AI 伙伴")

        val items = list
        when {
            items == null -> {
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Text(tr("正在加载…"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f),
                        modifier = Modifier.padding(vertical = 18.dp))
                }
            }

            items.isEmpty() -> {
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Column(
                        Modifier.fillMaxWidth().padding(vertical = 26.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Box(
                            Modifier.size(56.dp).clip(CircleShape)
                                .background(V2.accent.copy(alpha = 0.10f)),
                            contentAlignment = Alignment.Center
                        ) { IcPeople(V2.accent, 24.dp) }
                        Spacer(Modifier.height(12.dp))
                        Text(tr("还没有 AI 伙伴"), fontSize = V2.body,
                            fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(5.dp))
                        Text(tr("去广场挑一个，领养后就在这儿"),
                            fontSize = V2.tiny, color = ink.copy(alpha = 0.45f))
                        Spacer(Modifier.height(14.dp))
                        Text(
                            "去人设广场",
                            fontSize = V2.sub, fontWeight = FontWeight.Medium,
                            color = V2.accent,
                            modifier = Modifier
                                .clip(squircle(14.dp))
                                .background(V2.accent.copy(alpha = 0.12f))
                                .tapable { onFindMore() }
                                .padding(horizontal = 18.dp, vertical = 9.dp)
                        )
                    }
                }
            }

            else -> {
                CardGroup {
                    items.forEachIndexed { i, p ->
                        if (i > 0) RowDivider()
                        PersonaRow(p) { }
                    }
                }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** 通讯录里的一行：头像 + 名字 + 一句话。 */
@Composable
private fun PersonaRow(p: Api.Persona, onClick: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Avatar(p.avatar, p.name, 44.dp)
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.name, fontSize = V2.body, fontWeight = FontWeight.Medium)
                if (p.official) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "官方",
                        fontSize = 9.5.sp, color = V2.accent,
                        modifier = Modifier
                            .clip(squircle(5.dp))
                            .background(V2.accent.copy(alpha = 0.13f))
                            .padding(horizontal = 5.dp, vertical = 1.5.dp)
                    )
                }
            }
            if (p.tagline.isNotEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(p.tagline, fontSize = V2.tiny, maxLines = 1,
                    color = ink.copy(alpha = 0.45f))
            }
        }
    }
}

// ------------------------------------------------------------------ 发现

/**
 * 发现。
 *
 * 2026-11-14 用户逐条点过：「商城正在接入安卓版，朋友圈打不开，情侣空间打不开，
 * 日记什么…浏览器打不开，实时通话也打不开」——**点哪儿都是弹提示**，这是最招骂的形态。
 *
 * 处置原则：**能真开的才留**。
 * - 商城 → 真人设/表情列表（`/v1/psquare/list`、`/v1/emoji/list`）
 * - 浏览器 → 真 WebView
 * - 网易云音乐 / 苹果音乐 → 用户点名「可以删掉」
 * - 朋友圈 / 情侣空间 / 日记 / 一起做的事 / 实时通话 → iOS 那边是纯本地功能，
 *   安卓没有对应实现，**先不摆出来**，做好再放回来。
 */
@Composable

private fun DiscoverTab(
    onOpenMall: () -> Unit,
    onOpenBrowser: () -> Unit,
    onOpenMusic: () -> Unit
) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("发现", "商城 · 网易云 · 浏览器")

        // 商城入口（对 iOS 的 ShopEntryCard）
        Row(
            Modifier.padding(horizontal = V2.gutter).fillMaxWidth()
                .clip(squircle(V2.cardRadius))
                .background(MaterialTheme.colorScheme.surface)
                .border(
                    0.5.dp,
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                    squircle(V2.cardRadius)
                )
                .tapable { onOpenMall() }
                .padding(horizontal = V2.gutter, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(46.dp).clip(squircle(13.dp))
                    .background(V2.accent.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center
            ) { IcBag(V2.accent, 19.dp) }
            Spacer(Modifier.width(13.dp))
            Column(Modifier.weight(1f)) {
                Text(tr("商城"), fontSize = V2.body, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(3.dp))
                Text(
                    "人设 · 表情包",
                    fontSize = V2.tiny,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f)
                )
            }
            Icon(
                painterResource(R.drawable.ic_row_chevron), null,
                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.28f),
                modifier = Modifier.size(14.dp)
            )
        }

        // 2026-11-14 用户：「发现页把网易云接上」（前一轮他说苹果音乐可以删，
        // 网易云要留）——这一条现在是真能搜、真能播。
        SectionTitle("听点东西")
        CardGroup {
            RowItem(R.drawable.ic_row_music, "网易云音乐", "搜歌、播放",
                Color(0xFFE05185),
                onClick = { onOpenMusic() })
        }

        SectionTitle("其它")
        CardGroup {
            RowItem(R.drawable.ic_row_globe, "浏览器", "打开网页", V2.accent,
                onClick = { onOpenBrowser() })
        }

        Spacer(Modifier.height(28.dp))
    }
}

// ------------------------------------------------------------------ 我

@Composable
private fun MeTab(
    onSignOut: () -> Unit,
    onOpenInbox: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenAccount: () -> Unit,
    onOpenPermission: () -> Unit,
    onOpenDiary: () -> Unit,
    onOpenFont: () -> Unit,
    onOpenModels: () -> Unit,
    // 「积分」那一行点进充值页（2026-11-16，95）
    onOpenRecharge: () -> Unit
) {
    // 「我」页自己的 Context（函数后面那个 `val ctx` 声明得太晚，这里要提前用）
    val mctx = androidx.compose.ui.platform.LocalContext.current.applicationContext
    var balance by remember { mutableStateOf<Int?>(null) }
    // 导入预检结果（117 起是"压缩包"，124 起多了「整机搬家 v2」这一种）
    var pendingArchive by remember { mutableStateOf<PendingImport?>(null) }
    // 清理云备份（2026-11-16）
    var clearCloud by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val holder = withContext(Dispatchers.IO) {
                runCatching {
                    // 124：先按「整机搬家」认（manifest.ver == 2）；认不出再回落到聊天 ZIP / JSON
                    val full = com.aevis.android.core.FullBackup.prepare(mctx, uri)
                    if (full != null) {
                        PendingImport(
                            full = full, legacy = null,
                            roles = full.roles, convs = full.convs, msgs = full.msgs,
                            images = full.images, bgs = full.bgs,
                            note = "整机搬家包（角色 + 聊天 + 设置 + 背景）"
                        )
                    } else {
                        com.aevis.android.core.ChatArchive.prepare(mctx, uri)?.let { l ->
                            PendingImport(
                                full = null, legacy = l,
                                roles = 0, convs = l.convs, msgs = l.msgs,
                                images = l.images, bgs = 0, note = l.note
                            )
                        }
                    }
                }.getOrNull()
            }
            if (holder == null) {
                android.widget.Toast.makeText(
                    mctx, "不是 Aevis 的备份文件", android.widget.Toast.LENGTH_SHORT
                ).show()
            } else {
                pendingArchive = holder
            }
        }
    }

    if (clearCloud) {
        AlertDialog(
            onDismissRequest = { clearCloud = false },
            title = { Text(tr("清理云端备份？")) },
            text = {
                Text(
                    tr("云端那份聊天记录会被删掉，这台设备上的记录不受影响。"),
                    fontSize = V2.sub, lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    clearCloud = false
                    scope.launch {
                        val ok = withContext(Dispatchers.IO) {
                            runCatching { Api.deleteBackup() }.getOrDefault(false)
                        }
                        android.widget.Toast.makeText(
                            mctx, if (ok) "已清理" else "清理失败",
                            android.widget.Toast.LENGTH_SHORT
                        ).show()
                    }
                }) { Text(tr("清理"), color = V2.alert) }
            },
            dismissButton = {
                TextButton(onClick = { clearCloud = false }) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }

    // 导入确认（117 / 124）：先报数量，再让用户选「合并 / 覆盖」——默认合并。
    val pend = pendingArchive
    if (pend != null) {
        /** 真正执行导入（v2 走 FullBackup，其它走 ChatArchive）。返回一句给人看的结果。*/
        fun runImport(merge: Boolean) {
            pendingArchive = null
            scope.launch {
                val msg = withContext(Dispatchers.IO) {
                    if (pend.full != null) {
                        val r = com.aevis.android.core.FullBackup.apply(mctx, pend.full, merge)
                        if (r.err.isNotBlank()) "导入失败：${r.err}"
                        else "导入完成（" + (if (merge) "合并" else "恢复") + "）：" +
                            "${r.roles} 个角色 · ${r.convs} 个会话 · " +
                            "本次写入 ${r.msgs} 条消息 · ${r.images} 张图片" +
                            if (r.bgs > 0) " · 背景 ${r.bgs} 张" else ""
                    } else if (pend.legacy != null) {
                        val r = com.aevis.android.core.ChatArchive.apply(mctx, pend.legacy, merge)
                        if (r.err.isNotBlank()) "导入失败：${r.err}"
                        else "导入完成（" + (if (merge) "合并" else "覆盖") + "）：" +
                            "${r.convs} 个会话 · 本次写入 ${r.msgs} 条消息 · ${r.images} 张图片"
                    } else "没有可导入的内容"
                }
                android.widget.Toast.makeText(mctx, msg, android.widget.Toast.LENGTH_LONG).show()
            }
        }

        AlertDialog(
            onDismissRequest = { pendingArchive = null },
            title = { Text(if (pend.full != null) tr("整机搬家，导入这份备份？") else tr("导入聊天记录？")) },
            text = {
                Column {
                    Text(
                        buildString {
                            if (pend.roles > 0) append(tr("%d 个角色", pend.roles)).append(" · ")
                            append(tr("%d 个会话", pend.convs)).append(" · ")
                            append(tr("%d 条消息", pend.msgs)).append(" · ")
                            append(tr("%d 张图片", pend.images))
                            if (pend.bgs > 0) append(" · " + tr("背景图 %d 张", pend.bgs))
                        },
                        fontSize = V2.body, fontWeight = FontWeight.Medium
                    )
                    if (pend.note.isNotBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            pend.note, fontSize = V2.micro,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f)
                        )
                    }
                    Spacer(Modifier.height(10.dp))
                    Text(
                        tr("默认合并：只补新消息，重复的会按内容去重，本地不会丢。"),
                        fontSize = V2.tiny, lineHeight = 18.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f)
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { runImport(true) }) {
                    Text(tr("合并导入"), fontWeight = FontWeight.Medium)
                }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { runImport(false) }) {
                        Text(tr("覆盖"), color = V2.alert)
                    }
                    TextButton(onClick = { pendingArchive = null }) {
                        Text(tr("取消"))
                    }
                }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }
    // 先上本地缓存（头像/名字立刻有），再后台刷新
    var me by remember { mutableStateOf<Api.MeInfo?>(Api.cachedMe()) }
    var unread by remember { mutableIntStateOf(0) }
    val ctx = LocalContext.current
    // 原生扫一扫（2026-11-13）：扫电脑上的登录码，回来给网页授权。
    // 用系统 Camera + zxing 解码，不依赖 CameraX / ML Kit。
    val scanLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { res ->
        if (res.resultCode == Activity.RESULT_OK) {
            val raw = res.data?.getStringExtra("code").orEmpty()
            val ticket = parseScanTicket(raw)
            if (ticket.isEmpty()) {
                Toast.makeText(ctx, tr("这不是 Aevis 的登录码"), Toast.LENGTH_LONG).show()
            } else {
                (ctx as? com.aevis.android.MainActivity)?.handleScanTicket(ticket)
            }
        }
    }
    LaunchedEffect(Unit) {
        // 2026-11-16（95）：导入聊天记录已经不限会员，「我」页不再需要 wallet() 那一跳，
        // 少一次网络请求（会员状态在「账号」页里看）。
        balance = withContext(Dispatchers.IO) { Api.balance() }
        // 2026-11-14：昵称/头像一直是首字母，因为从来没调过 /v1/me。
        me = withContext(Dispatchers.IO) {
            runCatching { Api.me() }.getOrNull()?.also { runCatching { Api.saveMe(it) } }
        }
        unread = withContext(Dispatchers.IO) {
            runCatching { Api.inbox().second }.getOrDefault(0)
        }
    }
    val ink = MaterialTheme.colorScheme.onSurface
    val displayName = me?.nickname?.takeIf { it.isNotBlank() }
        ?: Api.email().substringBefore("@").ifEmpty { "未登录" }
    // 第二行摘要：邮箱 + 平台 ID（`UID xxxx`）。两个都没有就如实说没登录。
    val accountSummary = run {
        val mail = me?.email?.takeIf { it.isNotBlank() } ?: Api.email()
        val uid = me?.uid?.takeIf { it.isNotBlank() } ?: Api.uid()
        val parts = ArrayList<String>(2)
        if (mail.isNotBlank()) parts.add(mail)
        if (uid.isNotBlank()) parts.add("UID " + uid.take(10))
        if (parts.isEmpty()) tr("未登录") else parts.joinToString(" · ")
    }
    // 2026-11-16 修：真机上头像 /「当前余额」被状态栏压掉 —— 这一页原来没吃状态栏 inset
    // （HomeTab / ChatTab 的 Header 自己处理了，MeTab 用的是同一套 Header 但外层漏了 padding）。
    //
    // 2026-11-16（95）重做：原来是一长条 11 行的平铺列表 + emoji 图标，
    // 现在按「账号 / 功能 / 聊天记录 / 其他」拆成四张分组卡片（圆角 18、组间 12），
    // 图标全部换成 24dp 线条矢量图（不再是彩色方块 + 图形字符）。
    Column(
        Modifier.fillMaxSize()
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
    ) {
        Header("我")

        // ---------- 组 1：账号 ----------
        MeGroupLabel("账号")
        MeCard {
            Row(
                Modifier.fillMaxWidth()
                    .tapable { onOpenAccount() }
                    .padding(horizontal = V2.gutter, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Avatar(me?.avatar.orEmpty(), displayName, 56.dp)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        displayName, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(
                        accountSummary,
                        fontSize = 11.5.sp, maxLines = 1,
                        color = ink.copy(alpha = 0.55f),
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                    )
                }
                Spacer(Modifier.width(8.dp))
                Icon(
                    painterResource(R.drawable.ic_chevron), null,
                    tint = ink.copy(alpha = 0.22f),
                    modifier = Modifier.size(15.dp)
                )
            }
            MeDivider()
            MeRow(
                R.drawable.ic_points, "积分",
                sub = if (balance == null) tr("正在读取…") else tr("当前余额"),
                value = NativeCore.formatPointsSafe(balance?.toLong()),
                onClick = { onOpenRecharge() }
            )
        }

        // ---------- 组 2：功能 ----------
        Spacer(Modifier.height(12.dp))
        MeGroupLabel("功能")
        MeCard {
            MeRow(R.drawable.ic_scan, "扫一扫", tr("扫电脑上的登录码，给网页授权")) {
                scanLauncher.launch(Intent(ctx, CameraScanActivity::class.java))
            }
            MeDivider()
            MeRow(
                R.drawable.ic_bell, "通知",
                // 未读条数写在副标题里就够，右侧只留 chevron（不然数字会重复两遍）
                if (unread > 0) tr("%d 条未读", unread) else tr("没有新消息"),
                onClick = { onOpenInbox() }
            )
            MeDivider()
            // 多语言（2026-11-14）：点一下在中文 / English 之间切，选完会记住
            MeRow(
                R.drawable.ic_globe, "语言", null,
                value = I18n.label(),
                onClick = { I18n.setLang(ctx, if (I18n.lang == "zh") "en" else "zh") }
            )
            MeDivider()
            MeRow(R.drawable.ic_shield, "账号与安全", tr("邮箱、设备、会员")) {
                onOpenAccount()
            }
            MeDivider()
            MeRow(R.drawable.ic_diary, "日记", tr("它每天自己写的那一篇")) { onOpenDiary() }
            // 2026-11-25：模型状态区按 flag 门禁
            if (Api.featureEnabled("modelStatus")) {
                MeDivider()
                MeRow(R.drawable.ic_cpu, "模型", tr("用哪个模型聊天，看在线状态")) { onOpenModels() }
            }
            MeDivider()
            MeRow(R.drawable.ic_font, "字体", tr("日记用哪个字体，可导入")) { onOpenFont() }
            MeDivider()
            MeRow(R.drawable.ic_permission, "权限", tr("通知、相机、麦克风、位置等")) {
                onOpenPermission()
            }
            MeDivider()
            MeRow(R.drawable.ic_info, "关于 Aevis", tr("版本与协议")) { onOpenAbout() }
        }

        // ---------- 组 3：聊天记录（2026-11-16）----------
        // 导出所有人都能用；导入**不限会员**（原来挂过会员标，现在放开了）。
        Spacer(Modifier.height(12.dp))
        MeGroupLabel("聊天记录")
        MeCard {
            MeRow(R.drawable.ic_export, "导出聊天记录", tr("打包成 zip，图片也一起带走")) {
                exportChats(mctx, scope)
            }
            MeDivider()
            MeRow(R.drawable.ic_import, "导入聊天记录", tr("支持 zip（含图片）与旧版 JSON")) {
                runCatching {
                    // 117：zip 优先；老用户手里的 .json 也还能选
                    importLauncher.launch(
                        arrayOf("application/zip", "application/json", "text/plain", "*/*")
                    )
                }
            }
            MeDivider()
            MeRow(R.drawable.ic_cloud_off, "清理云备份", tr("只删云端那份，这台设备上的记录不动")) {
                clearCloud = true
            }
        }

        // ---------- 组 4：其他 ----------
        // 退出登录原来是卡片里的一行红字，被底部 Dock 压住了 —— 现在放进列表内容里，
        // 并在整页末尾补 96dp 内边距，任何机型都不会再被 Dock 盖住。
        Spacer(Modifier.height(12.dp))
        MeGroupLabel("其他")
        MeCard {
            Row(
                Modifier.fillMaxWidth()
                    .tapable { Api.signOut(); onSignOut() }
                    .padding(horizontal = V2.gutter, vertical = 16.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    painterResource(R.drawable.ic_logout), null,
                    tint = V2.alert, modifier = Modifier.size(19.dp)
                )
                Spacer(Modifier.width(8.dp))
                Text(tr("退出登录"), fontSize = 15.sp, color = V2.alert)
            }
        }

        // 版本号常驻在底部 —— 用户 2026-11-13：「APK 的版本呢？」
        // 2026-11-16（112）：只显示 `1.1.02` 这种版本名，**不再拼 build 号**。
        Spacer(Modifier.height(22.dp))
        Text(
            "Aevis Android ${BuildConfig.VERSION_NAME}" +
                " · core ${runCatching { NativeCore.version() }.getOrElse { "—" }}",
            fontSize = V2.micro,
            color = ink.copy(alpha = 0.32f),
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )
        // 底部悬浮 Dock 的保险垫 —— 比 Dock 实际高度（66 + 上下 10 + 系统栏）再宽一点
        Spacer(Modifier.height(96.dp))
    }
}

/** 「我」页的分组标题：11sp、onSurface 45%、字距 .04em（跟聊天设置半窗一套）。*/
@Composable
private fun MeGroupLabel(text: String) {
    Text(
        tr(text), fontSize = 11.sp, fontWeight = FontWeight.Medium,
        letterSpacing = 0.44.sp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
        modifier = Modifier.padding(
            start = V2.gutter, end = V2.gutter, top = 4.dp, bottom = 7.dp
        )
    )
}

/** 分组卡片：跟 `V2Card` 同材质，只有圆角按「我」页的规格收到 18dp。*/
@Composable
private fun MeCard(content: @Composable ColumnScope.() -> Unit) {
    val shape = squircle(18.dp)
    val skin = appSkin()
    Column(
        Modifier.fillMaxWidth()
            .padding(horizontal = V2.gutter)
            .clip(shape)
            .background(skin?.cardFill ?: MaterialTheme.colorScheme.surface)
            .border(
                if (skin == null) 0.5.dp else 1.dp,
                skin?.cardStroke
                    ?: MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                shape
            ),
        content = content
    )
}

/** 卡片内的分割线：从文字左边起（24 图标 + 14 间距 + 18 gutter）。*/
@Composable
private fun MeDivider() {
    HorizontalDivider(
        Modifier.padding(start = 56.dp),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    )
}

/**
 * 「我」页的一行：24dp 线条图标 + 标题/副标题 + 右值 + chevron，行高 56dp。
 *
 * 跟老的 `RowItem` 不是一回事：那个左侧是彩色圆形图标底（`IconBox`），
 * 是「一眼安卓」的观感；这一版图标没有底色，靠线条本身表达。
 */
@Composable
private fun MeRow(
    @DrawableRes icon: Int,
    title: String,
    sub: String? = null,
    value: String? = null,
    onClick: (() -> Unit)? = null
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .tapable(enabled = onClick != null) { onClick?.invoke() }
            .padding(horizontal = V2.gutter),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            painterResource(icon), null,
            tint = ink.copy(alpha = 0.72f),
            modifier = Modifier.size(24.dp)
        )
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(tr(title), fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
            if (sub != null) {
                Spacer(Modifier.height(2.dp))
                Text(
                    sub, fontSize = 11.5.sp, maxLines = 1,
                    color = ink.copy(alpha = 0.55f),
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                )
            }
        }
        if (value != null) {
            Spacer(Modifier.width(10.dp))
            Text(
                value, fontSize = 13.sp,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                color = ink.copy(alpha = 0.7f), maxLines = 1
            )
        }
        if (onClick != null) {
            Spacer(Modifier.width(4.dp))
            Icon(
                painterResource(R.drawable.ic_chevron), null,
                tint = ink.copy(alpha = 0.22f),
                modifier = Modifier.size(15.dp)
            )
        }
    }
}

/**
 * 还没做的页面先用它顶着。
 *
 * 2026-11-15 用户连续点了三个入口全是白屏 —— 白屏比"还没做"更难受，
 * 至少这里能看出来是哪儿、能返回。
 */
@Composable
fun ComingSoonScreen(title: String, onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    BackHandler { onBack() }
    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        Row(
            Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(44.dp).clip(CircleShape).tapable { onBack() },
                contentAlignment = Alignment.Center
            ) {
                Text("‹", fontSize = 26.sp, color = ink.copy(alpha = 0.75f))
            }
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(tr("这一页还在做"), fontSize = 15.sp, color = ink.copy(alpha = 0.55f))
                Spacer(Modifier.height(6.dp))
                Text(tr("功能接好就会出现在这里"), fontSize = 12.sp,
                    color = ink.copy(alpha = 0.32f))
            }
        }
    }
}

/**
 * 导出聊天记录（2026-11-16，117：改成 **ZIP**，图片一起打进去）。
 *
 * 写 `cacheDir/exports/aevis-chat-YYYYMMDD-HHmm.zip`，再通过系统分享发出去 ——
 * 只弹个 Toast 说"已导出"等于没给用户文件（用户根本拿不到）。
 * FileProvider authority 用 `${applicationId}.fileprovider`，
 * `file_paths.xml` 里 `cache-path path="."` 已经覆盖 `exports/`。
 *
 * 图片取不到（网络失败 / 本地文件被删）不中断整包，只提示「N 张没取到」。
 */
internal fun exportChats(ctx: android.content.Context, scope: kotlinx.coroutines.CoroutineScope) {
    scope.launch {
        // 117：打包要下载图片，可能几秒到几十秒 —— 先给一句，别让人以为点了没反应
        android.widget.Toast.makeText(
            ctx, "正在打包（含图片）…", android.widget.Toast.LENGTH_SHORT
        ).show()
        // 124：改成「整机搬家」——角色 / 我的资料 / 聊天 / 图片 / 设置 / 背景原图一起打
        val res = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.aevis.android.core.FullBackup.export(ctx)
        }
        val file = res.file
        if (file == null) {
            android.widget.Toast.makeText(
                ctx, "导出失败：${res.err.ifBlank { "未知错误" }}",
                android.widget.Toast.LENGTH_LONG
            ).show()
            return@launch
        }
        val extra = if (res.missing > 0) "，${res.missing} 张图片没取到" else ""
        android.widget.Toast.makeText(
            ctx,
            "已导出 ${res.roles} 个角色 · ${res.convs} 个会话 · ${res.images} 张图片$extra",
            android.widget.Toast.LENGTH_LONG
        ).show()
        runCatching {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                ctx, ctx.packageName + ".fileprovider", file
            )
            val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                // 117：zip
                type = "application/zip"
                putExtra(android.content.Intent.EXTRA_STREAM, uri)
                putExtra(android.content.Intent.EXTRA_SUBJECT, "Aevis 聊天记录")
                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            ctx.startActivity(
                android.content.Intent.createChooser(send, "导出聊天记录")
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure {
            android.widget.Toast.makeText(
                ctx, "没有可用的分享方式", android.widget.Toast.LENGTH_SHORT
            ).show()
        }
    }
}

/** 版本号比较（2026-11-16）： "1.10" > "1.9"，逐段按数字比，非数字段按字符串。 */
internal fun cmpVersion(a: String, b: String): Int {
    if (a.isBlank()) return -1
    if (b.isBlank()) return 1
    val pa = a.split(".")
    val pb = b.split(".")
    for (i in 0 until maxOf(pa.size, pb.size)) {
        val x = pa.getOrNull(i).orEmpty()
        val y = pb.getOrNull(i).orEmpty()
        val nx = x.toIntOrNull()
        val ny = y.toIntOrNull()
        val c = if (nx != null && ny != null) nx.compareTo(ny) else x.compareTo(y)
        if (c != 0) return c
    }
    return 0
}

/**
 * 解码"动图头像"（2026-11-16，94）。
 *
 * 只认真的动图（`AnimatedImageDrawable`）：GIF / animated WebP。
 * 静态图返回 null，让原来的位图路径去处理（保留加密缓存那条优化）。
 * API < 28 没有 ImageDecoder，直接返回 null。
 */
@Composable
private fun rememberAnimatedAvatar(url: String): android.graphics.drawable.Drawable? {
    if (android.os.Build.VERSION.SDK_INT < 28) return null
    if (url.isBlank()) return null
    var d by remember(url) { mutableStateOf<android.graphics.drawable.Drawable?>(null) }
    LaunchedEffect(url) {
        d = withContext(Dispatchers.IO) {
            runCatching {
                val src = if (isLocalFile(url)) {
                    val f = java.io.File(localImagePath(url))
                    if (!f.exists()) return@runCatching null
                    android.graphics.ImageDecoder.createSource(f)
                } else {
                    val bytes = com.aevis.android.data.Api.fetchImageRaw(url)
                        ?: return@runCatching null
                    android.graphics.ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes))
                }
                android.graphics.ImageDecoder.decodeDrawable(src)
            }.getOrNull()?.takeIf {
                it is android.graphics.drawable.AnimatedImageDrawable
            }
        }
    }
    return d
}

/**
 * 把动图按帧画在圆里（2026-11-16，94）。
 * Compose 没有现成的 animated-drawable 支持，这里用 Canvas + 33ms 的 tick 驱动重绘，
 * `clip(CircleShape)` 在外面，确保动图不会溢出圆形。
 */
@Composable
private fun AvatarAnimated(
    d: android.graphics.drawable.Drawable,
    name: String,
    size: Dp
) {
    var tick by remember(d) { mutableIntStateOf(0) }
    LaunchedEffect(d) {
        // R-01：静态图**一次循环都不跑**（以前所有头像都在 30fps 空转，列表里 5 个静态头像
        // 就是 5 条 33ms 的重绘循环 → 掉帧 + 耗电）
        val anim = d as? android.graphics.drawable.Animatable ?: return@LaunchedEffect
        anim.start()
        while (kotlin.coroutines.coroutineContext[kotlinx.coroutines.Job]?.isActive != false) {
            kotlinx.coroutines.delay(33)
            tick++
        }
    }
    Box(
        Modifier.size(size).clip(CircleShape)
            .background(V2.accent.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center
    ) {
        val t = tick   // 读一下，保证 tick 变化会触发重组重绘
        androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
            val px = size.toPx().toInt()
            d.setBounds(0, 0, px, px)
            d.draw(drawContext.canvas.nativeCanvas)
            if (t < 0) { /* 占位，避免 unused 警告 */ }
        }
    }
}
