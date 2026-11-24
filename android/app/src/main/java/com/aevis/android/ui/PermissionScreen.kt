package com.aevis.android.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.aevis.android.R
import com.aevis.android.core.I18n.tr

/**
 * 权限中心（2026-11-15）。
 *
 * 用户点名的八项：通知、忽略电池优化、相册、位置、麦克风、相机、使用情况访问、悬浮窗。
 *
 * 分两类，**交互方式完全不同**，这里必须分开处理，否则用户点了没反应：
 *  - **运行时权限**（通知/相册/位置/麦克风/相机）：能弹系统框，一次就完
 *  - **特殊权限**（电池优化/使用情况/悬浮窗）：系统不给弹窗，只能跳设置页让用户自己拨开关，
 *    跳过去以后**回来要重新查一次状态**（所以下面用 ON_RESUME 刷新）
 *
 * 设计上不做「一进来就全部索要」——那样会被系统和用户同时反感。
 * 这里是**用户主动来看、主动去开**的入口。
 */
private data class PermItem(
    val key: String,
    val title: String,
    val desc: String,
    val icon: Int,
    /** null = 特殊权限，走系统设置页 */
    val runtime: String?,
    val check: (Context) -> Boolean,
    val open: ((Context) -> Unit)? = null
)

@Composable
fun PermissionScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val ink = MaterialTheme.colorScheme.onSurface

    // 从系统设置页回来要重新读状态，否则勾了还是显示"未开启"
    var tick by remember { mutableIntStateOf(0) }
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_RESUME) tick++
        }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    // 运行时权限申请器：一次一个，回来就刷新
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { tick++ }

    val items = remember(tick) { buildItems(ctx) }
    val grantedCount = items.count { it.check(ctx) }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 顶栏（2026-11-16）：公共 SubPageHeader，右侧的「已给 N 项」搬到 trailing
        SubPageHeader(
            title = "权限",
            onBack = onBack,
            trailing = {
                Text(
                    "$grantedCount / ${items.size}",
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.4f)
                )
            }
        )

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Text(
                "这些都是 App 里具体功能要用的。不给也能用，只是对应功能不可用 —— "
                    + "点了没反应的那种情况，来这儿看一眼就知道差哪一项。",
                fontSize = V2.micro, color = ink.copy(alpha = 0.45f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
            )

            Spacer(Modifier.height(6.dp))

            // 后台陪伴（2026-11-15）：前台服务开关 + 电池优化状态
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("后台陪伴"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("开启后它在后台也会主动找你，40–90 分钟随机一次。"
                                + "关掉就只在打开 App 时出现。"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f),
                            lineHeight = 15.sp
                        )
                        if (!com.aevis.android.core.ProactiveService.isIgnoringBattery(ctx)) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                tr("建议同时开启上面的「忽略电池优化」，否则会被系统杀掉"),
                                fontSize = 10.5.sp, color = V2.alert.copy(alpha = 0.8f)
                            )
                        }
                    }
                    Spacer(Modifier.width(10.dp))
                    androidx.compose.material3.Switch(
                        checked = com.aevis.android.core.ProactiveService.isOn(ctx),
                        onCheckedChange = {
                            com.aevis.android.core.ProactiveService.setOn(ctx, it)
                            tick++
                        },
                        colors = androidx.compose.material3.SwitchDefaults.colors(
                            checkedThumbColor = androidx.compose.ui.graphics.Color.White,
                            checkedTrackColor = V2.accent
                        )
                    )
                }
            }

            Spacer(Modifier.height(10.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                items.forEachIndexed { i, it ->
                    if (i > 0) {
                        Box(
                            Modifier.fillMaxWidth().height(0.5.dp)
                                .background(ink.copy(alpha = 0.07f))
                        )
                    }
                    val on = it.check(ctx)
                    Row(
                        Modifier.fillMaxWidth()
                            .tapable {
                                if (on) return@tapable
                                if (it.runtime != null) {
                                    runCatching { launcher.launch(it.runtime) }
                                } else {
                                    runCatching { it.open?.invoke(ctx) }
                                }
                            }
                            .padding(horizontal = V2.gutter, vertical = 13.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            Modifier.size(34.dp).clip(RoundedCornerShape(11.dp))
                                .background(
                                    if (on) V2.accent.copy(alpha = 0.13f)
                                    else ink.copy(alpha = 0.055f)
                                ),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                painterResource(it.icon), null,
                                tint = if (on) V2.accent else ink.copy(alpha = 0.4f),
                                modifier = Modifier.size(17.dp)
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(it.title, fontSize = V2.body, fontWeight = FontWeight.Medium)
                            Spacer(Modifier.height(2.dp))
                            Text(
                                it.desc, fontSize = V2.micro,
                                color = ink.copy(alpha = 0.42f)
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        Text(
                            if (on) tr("已开启") else tr("去开启"),
                            fontSize = V2.tiny,
                            color = if (on) ink.copy(alpha = 0.35f) else V2.accent,
                            modifier = if (on) Modifier else Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(V2.accent.copy(alpha = 0.12f))
                                .padding(horizontal = 10.dp, vertical = 5.dp)
                        )
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            Text(
                "电池优化和使用情况访问没有弹窗，点进去要自己拨开关，回来这里会自动刷新。",
                fontSize = V2.micro, color = ink.copy(alpha = 0.32f),
                modifier = Modifier.padding(horizontal = V2.gutter)
            )
            Spacer(Modifier.height(30.dp))
        }
    }
}

private fun buildItems(ctx: Context): List<PermItem> {
    val pkg = ctx.packageName
    val sdk = Build.VERSION.SDK_INT

    // 相册：13+ 用 READ_MEDIA_IMAGES，12 及以下用读存储
    val mediaPerm = if (sdk >= 33) Manifest.permission.READ_MEDIA_IMAGES
    else Manifest.permission.READ_EXTERNAL_STORAGE

    fun has(p: String) =
        ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED

    return listOf(
        PermItem(
            "notify", "通知", "消息提醒、状态栏胶囊。不给就收不到推送",
            R.drawable.ic_row_bell,
            if (sdk >= 33) Manifest.permission.POST_NOTIFICATIONS else null,
            { c -> runCatching { NotificationManagerCompat.from(c).areNotificationsEnabled() }
                .getOrDefault(false) },
            { c ->
                if (Build.VERSION.SDK_INT >= 26) {
                    runCatching {
                        c.startActivity(
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, c.packageName)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                }
            }
        ),
        PermItem(
            "battery", "忽略电池优化", "锁屏后还能收消息、通话不断线",
            R.drawable.ic_row_bolt,
            null,
            { c ->
                runCatching {
                    (c.getSystemService(Context.POWER_SERVICE) as PowerManager)
                        .isIgnoringBatteryOptimizations(c.packageName)
                }.getOrDefault(false)
            },
            { c ->
                runCatching {
                    c.startActivity(
                        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            .setData(Uri.parse("package:" + c.packageName))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                }
            }
        ),
        PermItem(
            "media", "相册", "换头像、发图片时读取你选中的照片",
            R.drawable.ic_row_image,
            mediaPerm,
            { c -> has(mediaPerm) },
        ),
        PermItem(
            "location", "位置", "问天气、问「附近」这类问题时用，不做后台定位",
            R.drawable.ic_row_place,
            Manifest.permission.ACCESS_FINE_LOCATION,
            { c -> has(Manifest.permission.ACCESS_FINE_LOCATION) },
        ),
        PermItem(
            "mic", "麦克风", "按住说话、语音通话",
            R.drawable.ic_row_mic,
            Manifest.permission.RECORD_AUDIO,
            { c -> has(Manifest.permission.RECORD_AUDIO) },
        ),
        PermItem(
            "camera", "相机", "扫一扫登录网页、拍头像",
            R.drawable.ic_row_camera,
            Manifest.permission.CAMERA,
            { c -> has(Manifest.permission.CAMERA) },
        ),
        PermItem(
            "usage", "使用情况访问", "统计你每天用了哪些 App（只在本地算，不上传）",
            R.drawable.ic_row_chart,
            null,
            { c ->
                runCatching {
                    val appOps = c.getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
                    appOps.checkOpNoThrow(
                        android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                        Process.myUid(), c.packageName
                    ) == android.app.AppOpsManager.MODE_ALLOWED
                }.getOrDefault(false)
            },
            { c ->
                runCatching {
                    c.startActivity(
                        Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                }
            }
        ),
        PermItem(
            "overlay", "悬浮窗", "通话、一起听时的小窗",
            R.drawable.ic_row_layers,
            null,
            { c -> runCatching { Settings.canDrawOverlays(c) }.getOrDefault(false) },
            { c ->
                runCatching {
                    c.startActivity(
                        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                               Uri.parse("package:" + pkg))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                }
            }
        )
    )
}
