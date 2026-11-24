package com.aevis.android.ui

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.BuildConfig
import com.aevis.android.R
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.I18n.tr
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 主背景可选的纯色（都是低饱和，白字黑字都压得住）。*/
private val bgSwatches = listOf(
    "#FAF7F1", "#F2EDE3", "#1B1D22", "#9B8AF0",
    "#6FA8E8", "#21A394", "#E05185", "#EB8C2E", "#669E33"
)

/**
 * 通用设置（2026-11-16，路由 `settings2`，从「更多」进）。
 *
 * 只放**真的会生效**的项，不做空壳：
 *   1. 主背景（默认 / 纯色 / 相册）—— 112 起真的铺到 `Shell` 最外层
 *   2. 背景蒙层 —— 图片当背景时压一层，字才看得清
 *   3. 提示音（收到 AI 回复且不在那个会话页时响一声）
 *   4. 聊天背景（跳 `chatbg`）
 *   5. 气泡与配色（跳 `chatlook`）
 *   6. 弹窗背景（跟随主题 / 深色玻璃，真的改半窗颜色）
 */
@Composable
fun Settings2Screen(onBack: () -> Unit, onOpenPage: (String) -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var sound by remember { mutableStateOf(ChatPrefs.soundOn) }
    var dialogStyle by remember { mutableIntStateOf(ChatPrefs.dialogStyle) }
    // 自动恢复（2026-11-16，116）：默认开
    var autoRestore by remember { mutableStateOf(ChatPrefs.autoRestore) }
    // 133：新消息弹窗
    var bannerOn by remember { mutableStateOf(ChatPrefs.msgBanner) }
    // 主题（120）：默认跟随系统
    var themeMode by remember {
        mutableIntStateOf(com.aevis.android.core.ThemePrefs.mode)
    }
    // 背景 / 卡片不透明度（120）
    var bgOpacity by remember { mutableIntStateOf(ChatPrefs.bgOpacity) }
    var glassAlpha by remember { mutableIntStateOf(ChatPrefs.glassAlpha) }
    // 手动恢复人设（121）
    var confirmRoleRestore by remember { mutableStateOf(false) }
    var roleBusy by remember { mutableStateOf(false) }

    if (confirmRoleRestore) {
        AlertDialog(
            onDismissRequest = { if (!roleBusy) confirmRoleRestore = false },
            title = { Text(tr("从云端恢复人设？")) },
            text = {
                Text(
                    tr("会把服务端「我的角色」写回本地；同 id 的按云端那份更新，本地新建的角色保留。"),
                    fontSize = V2.sub, lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    roleBusy = true
                    scope.launch {
                        val (n, err) = withContext(Dispatchers.IO) {
                            com.aevis.android.core.PersonaLib.restoreFromCloud(force = true)
                        }
                        roleBusy = false
                        confirmRoleRestore = false
                        Toast.makeText(
                            ctx,
                            when {
                                err.isNotBlank() -> "恢复失败：$err"
                                n > 0 -> "已恢复 $n 个角色"
                                else -> "云端没有角色可恢复"
                            },
                            Toast.LENGTH_LONG
                        ).show()
                    }
                }) { Text(tr("恢复"), color = V2.accent) }
            },
            dismissButton = {
                TextButton(onClick = { confirmRoleRestore = false }) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }
    // 主背景（2026-11-16，112）
    var bgType by remember { mutableStateOf(ChatPrefs.appBgType) }
    var bgValue by remember { mutableStateOf(ChatPrefs.appBgValue) }
    var tintOn by remember { mutableStateOf(ChatPrefs.appTint) }
    var importing by remember { mutableStateOf(false) }

    /**
     * 相册选图 → 压到 1440 宽存 `files/bg/app.jpg`，路径写进 `appBgValue`。
     * 解码/压缩都在 IO 上做（原图几千万像素，主线程会卡）。
     */
    val bgPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            importing = true
            val path = withContext(Dispatchers.IO) { AppBgStore.import(ctx, uri) }
            importing = false
            if (path.isNullOrBlank()) {
                Toast.makeText(ctx, tr("这张图读不出来，换一张试试"), Toast.LENGTH_SHORT).show()
            } else {
                bgValue = path
                bgType = "image"
                // 先写 value 再写 type：两个 setter 都会 ++bgVersion，
                // 只改 type 的话会有一帧「type=image 但 value 还是旧色值」
                ChatPrefs.appBgValue = path
                ChatPrefs.appBgType = "image"
            }
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = tr("通用"), onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            Spacer(Modifier.height(6.dp))

            // 180：删掉「更多设置」这一行 —— 它的目标是 `settingsmore`（就是「更多」页本身），
            // 而「更多」页里的「通用配置」又指向本页，两边互相指 → 用户点下去像"退回上一级"。
            // 「更多」在首页「服务」区已有入口（Screens.kt 的 HomeIcon），不需要在这里重复。

            // ---------- 提示音 ----------
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("提示音"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("收到回复时响一声（正在看这个会话时不响）"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    Switch(
                        checked = sound,
                        onCheckedChange = {
                            sound = it
                            ChatPrefs.soundOn = it
                        }
                    )
                }
            }

            // ---------- 自动恢复（2026-11-16，116）----------
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            tr("自动恢复聊天记录"), fontSize = V2.body,
                            fontWeight = FontWeight.Medium
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("重装或换机后，登录就把云端记录拉回来"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    Switch(
                        checked = autoRestore,
                        onCheckedChange = {
                            autoRestore = it
                            ChatPrefs.autoRestore = it
                        }
                    )
                }
                ThinDivider2()
                // 133：新消息弹窗（跟「显示回复状态」分开，两项互不影响）
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("新消息弹窗"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("TA 主动找你时，顶部弹一条横幅"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    Switch(
                        checked = bannerOn,
                        onCheckedChange = {
                            bannerOn = it
                            ChatPrefs.msgBanner = it
                        }
                    )
                }
                ThinDivider2()
                // 手动恢复人设（2026-11-16，121）：本地已有角色时**不自动覆盖**，
                // 想从云端再拉一遍就点这里，问一句再动。
                SettingRow(
                    tr("从云端恢复人设"),
                    tr("本地已有的角色不会丢，同 id 的按云端那份更新")
                ) { confirmRoleRestore = true }
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 主题（2026-11-16，120）----------
            // 用户要「默认跟随系统」：系统是浅色的人第一次打开就该是浅色，不用先来设置里找开关。
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("主题"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("默认跟随系统"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StyleChip(tr("跟随"), themeMode == com.aevis.android.core.ThemePrefs.FOLLOW_SYSTEM) {
                            themeMode = com.aevis.android.core.ThemePrefs.FOLLOW_SYSTEM
                            com.aevis.android.core.ThemePrefs.mode = themeMode
                        }
                        Spacer(Modifier.width(6.dp))
                        StyleChip(tr("浅色"), themeMode == com.aevis.android.core.ThemePrefs.LIGHT) {
                            themeMode = com.aevis.android.core.ThemePrefs.LIGHT
                            com.aevis.android.core.ThemePrefs.mode = themeMode
                        }
                        Spacer(Modifier.width(6.dp))
                        StyleChip(tr("深色"), themeMode == com.aevis.android.core.ThemePrefs.DARK) {
                            themeMode = com.aevis.android.core.ThemePrefs.DARK
                            com.aevis.android.core.ThemePrefs.mode = themeMode
                        }
                    }
                }
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 外观 ----------
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                // 主背景（2026-11-16，112）：默认 / 纯色 / 相册。
                // 选完立刻生效 —— 不用退出页面重进（`ChatPrefs.bgVersion` 会通知整棵树）。
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("主背景"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            when {
                                importing -> tr("正在导入…")
                                bgType == "image" -> tr("图片已设置")
                                bgType == "solid" -> tr("纯色")
                                else -> tr("跟随主题的米白 / 深灰")
                            },
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StyleChip(tr("默认"), bgType == "default") {
                            bgType = "default"
                            ChatPrefs.appBgType = "default"
                        }
                        Spacer(Modifier.width(6.dp))
                        StyleChip(tr("纯色"), bgType == "solid") {
                            if (bgValue.startsWith("#")) {
                                bgType = "solid"
                                ChatPrefs.appBgType = "solid"
                            } else {
                                // 第一次点「纯色」给一支能看的默认色，别让背景突然变透明
                                bgValue = "#FAF7F1"
                                bgType = "solid"
                                ChatPrefs.appBgValue = "#FAF7F1"
                                ChatPrefs.appBgType = "solid"
                            }
                        }
                        Spacer(Modifier.width(6.dp))
                        StyleChip(tr("相册"), bgType == "image") {
                            runCatching {
                                bgPicker.launch(
                                    androidx.activity.result.PickVisualMediaRequest(
                                        ActivityResultContracts.PickVisualMedia.ImageOnly
                                    )
                                )
                            }
                        }
                    }
                }

                // 纯色：一排色板
                if (bgType == "solid") {
                    Row(
                        Modifier.fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = V2.gutter)
                            .padding(bottom = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        bgSwatches.forEach { hex ->
                            val on = bgValue.equals(hex, true)
                            val c = parseBgColor(hex) ?: V2.bgLight
                            Box(
                                Modifier.size(30.dp).clip(CircleShape)
                                    .background(c)
                                    .then(
                                        if (on) Modifier.border(2.dp, V2.accent, CircleShape)
                                        else Modifier.border(
                                            0.5.dp, ink.copy(alpha = 0.18f), CircleShape
                                        )
                                    )
                                    .tapable {
                                        bgValue = hex
                                        ChatPrefs.appBgValue = hex
                                        ChatPrefs.appBgType = "solid"
                                    }
                            )
                        }
                    }
                }

                // 图片：换一张 / 去掉
                if (bgType == "image") {
                    Row(
                        Modifier.fillMaxWidth().padding(
                            start = V2.gutter, end = V2.gutter, bottom = 12.dp
                        ),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            tr("换一张"),
                            fontSize = 12.sp, color = V2.accent,
                            modifier = Modifier.tapable {
                                runCatching {
                                    bgPicker.launch(
                                        androidx.activity.result.PickVisualMediaRequest(
                                            ActivityResultContracts.PickVisualMedia.ImageOnly
                                        )
                                    )
                                }
                            }.padding(vertical = 4.dp, horizontal = 2.dp)
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            tr("去掉图片"),
                            fontSize = 12.sp, color = V2.alert,
                            modifier = Modifier.tapable {
                                AppBgStore.clear()
                                bgValue = ""
                                bgType = "default"
                                ChatPrefs.appBgValue = ""
                                ChatPrefs.appBgType = "default"
                            }.padding(vertical = 4.dp, horizontal = 2.dp)
                        )
                    }
                }

                ThinDivider2()

                SettingRow(tr("聊天背景"), tr("换一张背景图 / 纯色 / 渐变")) {
                    onOpenPage("chatbg")
                }
                ThinDivider2()
                SettingRow(tr("气泡与配色"), tr("头像大小、圆角、气泡颜色")) {
                    onOpenPage("chatlook")
                }
                ThinDivider2()
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            tr("弹窗背景"), fontSize = V2.body,
                            fontWeight = FontWeight.Medium
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("半窗和弹窗的底色"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StyleChip(tr("跟随主题"), dialogStyle == 0) {
                            dialogStyle = 0
                            ChatPrefs.dialogStyle = 0
                        }
                        Spacer(Modifier.width(8.dp))
                        StyleChip(tr("深色玻璃"), dialogStyle == 1) {
                            dialogStyle = 1
                            ChatPrefs.dialogStyle = 1
                        }
                    }
                }
                ThinDivider2()
                // 背景蒙层（2026-11-16，112）：图片当主背景时压一层，字才看得清
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            tr("背景蒙层"), fontSize = V2.body,
                            fontWeight = FontWeight.Medium
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            tr("给背景图压一层，文字更清楚"),
                            fontSize = V2.micro, color = ink.copy(alpha = 0.45f)
                        )
                    }
                    Switch(
                        checked = tintOn,
                        onCheckedChange = {
                            tintOn = it
                            ChatPrefs.appTint = it
                        }
                    )
                }

                // 不透明度（2026-11-16，120）：只有设了主背景才有意义，`default` 下不显示
                if (bgType != "default") {
                    ThinDivider2()
                    PctSlider(
                        title = tr("背景不透明度"),
                        sub = tr("100% = 背景完全实，不跟主题底色混"),
                        value = bgOpacity,
                        range = 0..100
                    ) {
                        bgOpacity = it
                        ChatPrefs.bgOpacity = it
                    }
                    ThinDivider2()
                    PctSlider(
                        title = tr("卡片不透明度"),
                        sub = tr("正文要看得清就别低于 85%"),
                        value = glassAlpha,
                        range = 40..100
                    ) {
                        glassAlpha = it
                        ChatPrefs.glassAlpha = it
                    }
                }
            }

            Spacer(Modifier.height(20.dp))
            Text(
                // 112：只显示版本名（`1.1.02`），不拼 build 号
                "Aevis Android ${BuildConfig.VERSION_NAME}",
                fontSize = V2.micro, color = ink.copy(alpha = 0.3f),
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(30.dp))
        }
    }
}

@Composable
private fun SettingRow(title: String, sub: String, onClick: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = V2.body, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(2.dp))
            Text(sub, fontSize = V2.micro, color = ink.copy(alpha = 0.45f))
        }
        Icon(
            painterResource(R.drawable.ic_chevron), null,
            tint = ink.copy(alpha = 0.25f), modifier = Modifier.size(15.dp)
        )
    }
}

@Composable
private fun StyleChip(label: String, on: Boolean, onClick: () -> Unit) {    val ink = MaterialTheme.colorScheme.onSurface
    Text(
        label, fontSize = 11.5.sp,
        color = if (on) V2.accent else ink.copy(alpha = 0.55f),
        modifier = Modifier.clip(squircle(9.dp))
            .background(
                if (on) V2.accent.copy(alpha = 0.13f) else ink.copy(alpha = 0.05f)
            )
            .tapable { onClick() }
            .padding(horizontal = 9.dp, vertical = 5.dp)
    )
}

/** 0.5dp 分割线（本文件私有，不抢 Screens 里的 private 版本）。*/
@Composable
private fun ThinDivider2() {
    Box(
        Modifier.fillMaxWidth().height(0.5.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f))
    )
}

/**
 * 百分比滑块（2026-11-16，120）：标题 + 说明 + 右侧当前值 + 一条 34dp 的滑杆。
 *
 * 只用于「背景不透明度 / 卡片不透明度」这两项 —— 都是 10 档跳的整数百分比，
 * 拖起来有一点阻尼感，不至于因为 1% 的抖动一直重组整棵树。
 */
@Composable
private fun PctSlider(
    title: String,
    sub: String,
    value: Int,
    range: IntRange,
    onChange: (Int) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontSize = V2.body, fontWeight = FontWeight.Medium)
            Spacer(Modifier.weight(1f))
            Text(
                "$value%", fontSize = V2.tiny, fontWeight = FontWeight.Medium,
                color = V2.accent
            )
        }
        Spacer(Modifier.height(1.dp))
        Text(sub, fontSize = V2.micro, color = ink.copy(alpha = 0.42f))
        androidx.compose.material3.Slider(
            value = value.toFloat(),
            onValueChange = { onChange(((it / 5).toInt() * 5).coerceIn(range.first, range.last)) },
            valueRange = range.first.toFloat()..range.last.toFloat(),
            colors = androidx.compose.material3.SliderDefaults.colors(
                thumbColor = V2.accent,
                activeTrackColor = V2.accent,
                inactiveTrackColor = ink.copy(alpha = 0.10f)
            ),
            modifier = Modifier.fillMaxWidth().height(34.dp)
        )
    }
}
