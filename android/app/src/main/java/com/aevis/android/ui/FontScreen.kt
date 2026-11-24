package com.aevis.android.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.FontStore
import com.aevis.android.core.I18n.tr

/**
 * 字体（2026-11-15 起，2026-11-16 重画）。
 *
 * 用户：「字体的话…你可以去找一点开源的网站，点击就直接跳转到别人的网站，
 * 然后给他们教程让他们去下」；后来又补一句「字体页要单独重新画一下」。
 *
 * 所以逻辑**一点没改**（还是不内置字体、只推 SIL OFL 可商用的、下载完回来导入），
 * 只重排视觉：
 *   ① 顶部一张**预览卡** —— 直接用当前字体渲染一句话，好不好看当场知道；
 *   ② 中间列表 —— 默认字体 / 推荐（去下载）/ 已导入（用它自己的字体渲染，右侧打勾）；
 *   ③ 底部主按钮「应用」—— accent 实心，点完立刻重生一遍预览。
 *
 * `FontStore` 的读写完全沿用（`import` / `reset` / `currentName` / `currentFile`）。
 */
@Composable
fun FontScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    var current by remember { mutableStateOf(FontStore.currentName()) }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf("") }
    // `tick` 一变就重读字体文件：导入完 / 点「应用」都走它（文件可能刚被替换）
    var tick by remember { mutableIntStateOf(0) }
    val family: FontFamily? = remember(tick) { customFamily() }

    // 从系统文件选择器拿字体文件
    val pick = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        msg = ""
        // 复制到私有目录 + 校验是不是字体（FontStore 原逻辑，没动）
        val ok = FontStore.import(ctx, uri)
        busy = false
        msg = if (ok) tr("导入成功，日记页已经用上了") else tr("这个文件读不了，换一个 ttf/otf 试试")
        current = FontStore.currentName()
        tick++              // 让预览卡也换上刚导入的字体
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "字体", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            // ---------- 预览卡 ----------
            Text(
                tr("预览"), fontSize = V2.micro, color = ink.copy(alpha = 0.42f),
                modifier = Modifier.padding(start = V2.gutter, top = 4.dp, bottom = 7.dp)
            )
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Text(
                    tr("今天也想和你说说话。"),
                    fontSize = 19.sp, lineHeight = 30.sp,
                    color = ink, fontFamily = family
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    tr("日记里的字会变成这样：字是慢慢写下来的，话是慢慢说出来的。"),
                    fontSize = 12.sp, lineHeight = 20.sp,
                    color = ink.copy(alpha = 0.45f), fontFamily = family
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    tr("当前：%s", current), fontSize = V2.micro,
                    color = V2.accent.copy(alpha = 0.8f)
                )
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 字体列表 ----------
            Text(
                tr("可选字体"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
            )
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                // 默认字体（没导入任何文件时才是"使用中"）
                FontRow(
                    name = tr("默认字体"),
                    note = tr("系统自带，不用下载"),
                    selected = family == null,
                    family = null
                ) {
                    // 选中默认 = 把已导入的删掉（跟原来的「恢复默认字体」等价，
                    // 只是从一行灰字改成列表里可选的一项）
                    if (family != null) {
                        FontStore.reset(ctx)
                        current = FontStore.currentName()
                        tick++
                        msg = tr("已恢复默认")
                    }
                }

                FONTS.forEach { f ->
                    RowDividerThin(ink)
                    Row(
                        Modifier.fillMaxWidth()
                            .padding(horizontal = V2.gutter, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(Modifier.weight(1f)) {
                            // 推荐的这几个字体文件不在 APK 里，**没法用它自己的字渲染**（能预览就预览，
                            // 预览不了就用系统字体显示名字 —— 总比编一个假字形好）
                            Text(
                                f.name, fontSize = V2.body, fontWeight = FontWeight.Medium,
                                maxLines = 1
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                f.note, fontSize = V2.micro,
                                color = ink.copy(alpha = 0.42f), lineHeight = 15.sp
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        Text(
                            tr("去下载"), fontSize = 12.5.sp, color = V2.accent,
                            modifier = Modifier.clip(squircle(9.dp))
                                .background(V2.accent.copy(alpha = 0.12f))
                                .tapable {
                                    runCatching {
                                        ctx.startActivity(
                                            Intent(Intent.ACTION_VIEW, Uri.parse(f.url))
                                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        )
                                    }
                                }
                                .padding(horizontal = 11.dp, vertical = 6.dp)
                        )
                    }
                }

                // 已导入的自定义字体：**用它自己的字体渲染名字**（这是唯一能真预览的一行）
                val fam = family
                if (fam != null) {
                    RowDividerThin(ink)
                    FontRow(
                        name = current,
                        note = tr("已导入，正在使用"),
                        selected = true,
                        family = fam
                    ) { /* 已选中，点了不做事 */ }
                }
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 导入（次按钮）----------
            Box(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .clip(squircle(14.dp))
                    .background(ink.copy(alpha = 0.06f))
                    .tapable {
                        if (!busy) pick.launch(
                            arrayOf("font/*", "application/octet-stream", "*/*")
                        )
                    }
                    .padding(vertical = 13.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    if (busy) tr("正在导入…") else tr("导入已下载的字体"),
                    fontSize = V2.body, fontWeight = FontWeight.Medium,
                    color = ink.copy(alpha = 0.8f)
                )
            }

            Spacer(Modifier.height(10.dp))

            // ---------- 应用（主按钮）----------
            // 真应用在导入那一刻就完成了，这个按钮是"确认 + 立刻重生一遍预览"，
            // 顺便给用户一个明确的收尾动作（不然导完不知道有没有生效）。
            val canApply = family != null && !busy
            Box(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .clip(squircle(14.dp))
                    .background(if (canApply) V2.accent else ink.copy(alpha = 0.06f))
                    .tapable(enabled = canApply) {
                        tick++
                        current = FontStore.currentName()
                        msg = tr("已应用，日记页已换成这个字体")
                    }
                    .padding(vertical = 14.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    tr("应用"), fontSize = 15.sp, fontWeight = FontWeight.Medium,
                    color = if (canApply) Color.White else ink.copy(alpha = 0.32f)
                )
            }

            if (msg.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                Text(
                    msg, fontSize = V2.micro, color = V2.accent,
                    modifier = Modifier.padding(horizontal = V2.gutter)
                )
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 教程 ----------
            Text(
                tr("怎么装"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
            )
            Text(
                tr("1. 点上面任一「去下载」，会用浏览器打开官网\n"
                    + "2. 下那个 .ttf 或 .otf 文件（通常在下「完整版」，几百 KB 到十几 MB）\n"
                    + "3. 回到这里点「导入已下载的字体」，从「下载」文件夹里选刚下的文件\n"
                    + "4. 导入后日记页立刻换成新字体"),
                fontSize = 13.sp, lineHeight = 22.sp, color = ink.copy(alpha = 0.7f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
            )

            Spacer(Modifier.height(34.dp))
        }
    }
}

/** 列表里的一行：名字（可指定字体渲染）+ 说明 + 右侧选中勾。*/
@Composable
private fun FontRow(
    name: String,
    note: String,
    selected: Boolean,
    family: FontFamily?,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth()
            .tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                name, fontSize = 16.sp, fontWeight = FontWeight.Medium,
                maxLines = 1, fontFamily = family
            )
            Spacer(Modifier.height(2.dp))
            Text(note, fontSize = V2.micro, color = ink.copy(alpha = 0.42f))
        }
        if (selected) {
            Icon(
                painterResource(R.drawable.ic_login_check), null,
                tint = V2.accent, modifier = Modifier.size(16.dp)
            )
        }
    }
}

/** 0.5dp 分割线（这个文件自己的小工具，别去抢 Screens 里的 private 版本）。*/
@Composable
private fun RowDividerThin(ink: Color) {
    Box(Modifier.fillMaxWidth().height(0.5.dp).background(ink.copy(alpha = 0.07f)))
}

/**
 * 已导入的字体文件 → FontFamily。没有文件返回 null（用系统字体）。
 *
 * **不是** `@Composable`：它只是读文件 + 建 FontFamily，调用方放在 `remember(tick)` 里，
 * 与 DiaryScreen 同一套写法（那里也是 `remember { FontFamily(Font(file)) }`）。
 */
private fun customFamily(): FontFamily? {
    val f = FontStore.currentFile()
    if (!f.exists()) return null
    return runCatching { FontFamily(androidx.compose.ui.text.font.Font(f)) }.getOrNull()
}

private data class FontPick(
    val name: String,
    val note: String,
    val url: String
)

/** 只放**明确可商用**的（SIL OFL / Apache）。 */
private val FONTS = listOf(
    FontPick(
        "霞鹜文楷 LXGW WenKai",
        "最适合日记，楷体带手写感，SIL OFL 可商用。下 lxgw-wenkai-*.ttf",
        "https://github.com/lxgw/LxgwWenKai/releases"
    ),
    FontPick(
        "得意黑 Smiley Sans",
        "标题好看，倾斜的现代黑体，SIL OFL 可商用",
        "https://github.com/atelier-anchor/smiley-sans/releases"
    ),
    FontPick(
        "思源宋体 Noto Serif SC",
        "正经书卷气，Google 官方，OFL 可商用",
        "https://fonts.google.com/noto/specimen/Noto+Serif+SC"
    ),
    FontPick(
        "马善政毛笔楷书",
        "毛笔手写感强，OFL 可商用，日记很有味道",
        "https://fonts.google.com/specimen/Ma+Shan+Zheng"
    )
)
