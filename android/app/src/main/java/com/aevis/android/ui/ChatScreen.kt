package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.TextButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.*
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.annotation.DrawableRes
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import android.widget.Toast
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.PersonaLib
import com.aevis.android.data.Api
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 聊天详情页（2026-11-15 第一版）。
 *
 * ⚠️ 安卓以前**根本没有这个页面** ——「聊天」tab 展开只有一张空卡片，
 * 点了没反应。用户一直在说「聊天里面其实就是一个会话」，指的就是这里。
 *
 * 结构按用户要求：
 *   · 进页面直接是对话，**不再先选人**
 *   · 顶部是对方头像 + 名字，**点头像就地换人**（横向一排可滑）
 *   · 气泡：AI 在左、我在右；同一方连续多条时只在第一条显示头像
 *
 * 预留了三个外观参数（[avatarSize] / [bubbleRadius] / [gap]），
 * 后面做「自定义外观」时直接接设置项，不用再改结构。
 */
/**
 * 把一段回复拆成「一条一条」的消息。
 *
 * 规则（宁少勿碎）：
 *   · 按换行拆 —— 模型（deepseek）分段用的是单个换行，不是空行；
 *     早先按空行拆等于没拆，用户看到的是一大块挤在一个气泡里。
 *   · 太碎的段（不到 12 字）跟前一段合并，避免「嗯。」单独成一条。
 *   · 最多 3 条，多出来的并到最后一条。
 *   · 只有一段但超过 120 字时，中间找句号切一刀。
 *
 * 2026-11-16：从 `private` 改成 `internal` —— 群聊页（GroupChatScreen）要用同一份，
 * 抄第二份的话两边拆法迟早会不一致。
 */
/**
 * 把模型回复切成"一条条消息"（2026-11-16，90 重写）。
 *
 * 用户：「AI 现在都是全部的输出，不一条条弹出来」——
 * 根因不是客户端拆得不够，是模型把整段写成一大坨，光靠标点硬拆还是长条。
 *
 * 现在的顺序：
 *   1. **先按行拆**（`\n`）—— 提示词要求它一条一行，行就是天然的边界；
 *   2. 去掉空行、纯符号行；
 *   3. 单行**超过 60 字且含分段标点**时才按标点继续拆（短句不动，避免把一句话劈两半）；
 *   4. 条数 > 6 时**合并相邻最短的两条**，最多 6 条（防模型每句一行把界面刷屏）。
 *
 * `puncts` / `stripTrailing` 由调用方按用户设置传入。
 */
internal fun splitReply(
    text: String,
    puncts: String = "。！？～",
    stripTrailing: Boolean = true
): List<String> {
    val t = text.replace("\r\n", "\n").trim()
    if (t.isEmpty()) return emptyList()

    // 1) 按行，去掉空行/纯符号行
    val lines = t.split("\n").map { it.trim() }
        .filter { line ->
            line.isNotEmpty() && line.any { ch ->
                ch.isLetterOrDigit() || ch in "，。！？～…、；：,.!?~"
            }
        }

    // 2) 单行太长才按标点继续拆
    val pieces = ArrayList<String>()
    lines.forEach { line ->
        val plainLen = line.count { it.isLetterOrDigit() }
        if (plainLen > 60 && line.any { it in puncts }) {
            pieces.addAll(splitByPunct(line, puncts))
        } else {
            pieces.add(line)
        }
    }

    // 3) 太多就合并最相邻的短条，最多 6 条
    var out: MutableList<String> = pieces.toMutableList()
    while (out.size > 6) {
        var bestIdx = 0
        var bestLen = Int.MAX_VALUE
        for (i in 0 until out.size - 1) {
            val l = out[i].length + out[i + 1].length
            if (l < bestLen) { bestLen = l; bestIdx = i }
        }
        out[bestIdx] = out[bestIdx] + " " + out[bestIdx + 1]
        out.removeAt(bestIdx + 1)
    }

    return out.map { piece ->
        if (stripTrailing) piece.trimEnd(*puncts.toCharArray()).trim() else piece
    }.filter { it.isNotEmpty() }
}

/** 按句末标点拆（只在单行过长时用）。*/
internal fun splitByPunct(text: String, puncts: String): List<String> {
    val out = ArrayList<String>()
    val buf = StringBuilder()
    for (ch in text) {
        buf.append(ch)
        if (puncts.indexOf(ch) >= 0) {
            val piece = buf.toString().trim()
            if (piece.isNotEmpty()) out.add(piece)
            buf.clear()
        }
    }
    val rest = buf.toString().trim()
    if (rest.isNotEmpty()) out.add(rest)
    return out
}

private fun contextLabelOf(msgs: List<Api.Msg>): String {
    val t = msgs.sumOf { it.content.length } / 2
    return when {
        // 174：既显示**设置的上限条数**，也显示已用量 —— 只显示已用量用户看不明白
        else -> {
            val limit = com.aevis.android.core.ChatPrefs.ctxWindow
            val used = when {
                t <= 0 -> "0"
                t < 1000 -> "$t"
                else -> String.format(java.util.Locale.US, "%.1f", t / 1000f) + "K"
            }
            "上下文 $limit 条 · $used"
        }
    }
}

/**
 * 去掉消息里 `（）` 包住的描写，只留说出口的话（2026-11-16）。
 * TTS 不该把「（他在笑）」念出来；消息原文一个字都不改。
 */
internal fun stripParens(s: String): String {
    val sb = StringBuilder()
    var depth = 0
    for (ch in s) {
        if (ch == '\uFF08' || ch == '(') { depth++; continue }
        if (ch == '\uFF09' || ch == ')') { depth = (depth - 1).coerceAtLeast(0); continue }
        if (depth == 0) sb.append(ch)
    }
    return sb.toString().trim().ifEmpty { s.trim() }
}

/**
 * 取这条语音的本地 mp3（2026-11-16）。
 *
 * 缓存键 = 文本的 md5：同一句话再点播放不会重复请求 TTS（省钱也省时间）。
 * 合成失败返回 null（调用方 Toast「语音暂时没开通」）。
 */
internal fun ttsFile(ctx: android.content.Context, text: String): java.io.File? {
    if (text.isBlank()) return null
    val dir = java.io.File(ctx.cacheDir, "tts").apply { if (!exists()) mkdirs() }
    val md5 = try {
        val d = java.security.MessageDigest.getInstance("MD5")
        d.digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    } catch (e: Exception) {
        text.hashCode().toString()
    }
    val f = java.io.File(dir, "$md5.mp3")
    if (f.exists() && f.length() > 0) return f
    val voice = com.aevis.android.data.Api.defaultVoice()
    val bytes = com.aevis.android.data.Api.ttsSpeech(text, voice) ?: return null
    return runCatching {
        f.writeBytes(bytes)
        f
    }.getOrNull()
}

/**
 * 气泡底部的「物品 / 状态说明」折叠条（2026-11-16）。
 *
 * 模型偶尔会吐 `[物品：…]` + `状态：… 颜色：…` 这种字段清单，直接铺在气泡里很丑。
 * 这里把它收成一条小胶囊：默认折叠，点开才在气泡里显示原文（浅色 11sp）。
 * 正文全被摘完时（只剩块），气泡里就只显示这条 —— 不留空白气泡。
 */
@Composable
internal fun FormatBlockStrip(blocks: List<String>, dim: Color) {
    var open by remember { mutableStateOf(false) }
    Column(Modifier.padding(top = 6.dp)) {
        Row(
            Modifier.clip(squircle(8.dp))
                .background(dim.copy(alpha = 0.16f))
                .tapable { open = !open }
                .padding(horizontal = 8.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(tr("物品 / 状态说明"), fontSize = 11.sp, color = dim)
            Spacer(Modifier.width(5.dp))
            Text(
                if (open) tr("收起") else tr("展开"),
                fontSize = 11.sp, color = V2.accent
            )
        }
        if (open) {
            Spacer(Modifier.height(5.dp))
            blocks.forEach { b ->
                Text(b, fontSize = 11.sp, lineHeight = 16.sp, color = dim)
                Spacer(Modifier.height(3.dp))
            }
        }
    }
}

/**
 * 折叠条**展开后**给人看的那几行，渲染前洗一遍（2026-11-16）。
 *
 * 1. `$\text{xxx}$` / `\text{xxx}` → `xxx`
 * 2. 其它 LaTeX 命令 `\foo{xxx}` → `xxx`
 * 3. markdown 记号 `**` / `__` / 反引号 全去掉（气泡里是说明文字，不该出现记号）
 */
internal fun cleanBlockLine(raw: String): String {
    var t = raw
    t = Regex("\\$?\\s*\\\\text\\{([^}]*)\\}\\s*\\$?").replace(t, "$1")
    t = Regex("\\\\[a-zA-Z]+\\{([^}]*)\\}").replace(t, "$1")
    t = t.replace("**", "").replace("__", "").replace("`", "")
    return t.trim()
}

/**
 * 渲染前洗掉"画不出来的字符"（2026-11-16）。
 *
 * 真机气泡里出现过幽灵方框（缺字形），排查结果：
 *   · **不是**自定义字体 —— `FontStore` 只在日记页用，聊天气泡走系统字体；
 *   · **不是**切片丢字 —— `chatAnnotated` 是逐字符 append，`visibleLen` 只控制范围；
 *   · 是**消息原文里带了 PUA / 变体选择符 / ZWJ / U+FFFD**，系统字体没有对应字形 → 渲染成方框。
 * 这些字符对语义没贡献（都是表情变体或私有区占位），直接丢弃最干净。
 */
internal fun sanitizeGlyphs(s: String): String {
    if (s.isEmpty()) return s
    val sb = StringBuilder(s.length)
    for (ch in s) {
        val c = ch.code
        if (c in 0xE000..0xF8FF) continue      // 私有使用区
        if (c in 0xFE00..0xFE0F) continue      // 变体选择符
        if (c == 0x200D || c == 0x200B) continue // ZWJ / 零宽空格
        if (c == 0xFFFD) continue              // 替换符
        sb.append(ch)
    }
    return sb.toString()
}

/** 复制到剪贴板（2026-11-16）。*/
internal fun copyToClipboard(ctx: android.content.Context, text: String) {
    runCatching {
        val cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
            as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("Aevis", text))
    }
}

/** 消息菜单的一行（2026-11-16）。`danger` = 红色（删除/回退）。 */
@Composable
private fun MsgMenuItem(
    label: String,
    hint: String = "",
    danger: Boolean = false,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(
        Modifier.fillMaxWidth()
            .clip(squircle(12.dp))
            .tapable { onClick() }
            .padding(horizontal = 10.dp, vertical = 11.dp)
    ) {
        Text(
            label, fontSize = V2.body, fontWeight = FontWeight.Medium,
            color = if (danger) V2.alert else ink
        )
        if (hint.isNotEmpty()) {
            Spacer(Modifier.height(2.dp))
            Text(hint, fontSize = 11.sp, color = ink.copy(alpha = 0.42f))
        }
    }
}

/** "当前正在看哪个会话"（2026-11-16）：提示音靠它判断"要不要响"。*/
internal object Presence {
    @Volatile
    var chatPid: String = ""
}

/**
 * 弹窗/半窗底色（2026-11-16）。
 * `ChatPrefs.dialogStyle`：0 跟随主题 / 1 深色玻璃 —— 用户能一眼看出区别才算数。
 * 112：设了主背景时，跟随主题那一档也用同一套玻璃底（半窗浮在照片上不该是一块死白）。
 */
@Composable
internal fun dialogSurfaceColor(): androidx.compose.ui.graphics.Color =
    // 2026-11-24：半窗/弹窗统一磨砂（用户：「背后要磨砂玻璃，别是透明的」）。
    // dialogStyle==1 仍是用户可钉住的"深色玻璃"档；其余走语义磨砂色，
    // 明色偏白、暗色偏暗，不再是一块死实色或透底。
    if (com.aevis.android.core.ChatPrefs.dialogStyle == 1)
        androidx.compose.ui.graphics.Color(0xFF1B1A20).copy(alpha = 0.94f)
    else frostedSheetColor()

/**
 * 三个点依次动（2026-11-16，89）。
 *
 * `rememberInfiniteTransition` + 每个点 `StartOffset(i * 160)`，周期 1000ms（500ms 去 + 500ms 回），
 * `alpha 0.35→1`、`scale 0.8→1`。**不是 `...` 字符**，是真的三个圆点 Box。
 * 注意：这个组件只放在顶栏和列表里的输入中气泡里 —— 列表项滚出屏幕后
 * 组合会被回收，`InfiniteTransition` 跟着停，不会在屏幕外空转。
 */
@Composable
internal fun TypingDots(
    tint: androidx.compose.ui.graphics.Color,
    dot: androidx.compose.ui.unit.Dp = 3.dp,
    gap: androidx.compose.ui.unit.Dp = 1.5.dp
) {
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "typing")
    Row(verticalAlignment = Alignment.CenterVertically) {
        repeat(3) { i ->
            val a by t.animateFloat(
                initialValue = 0.35f,
                targetValue = 1f,
                animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                    animation = androidx.compose.animation.core.tween(
                        durationMillis = 500,
                        easing = androidx.compose.animation.core.FastOutSlowInEasing
                    ),
                    repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
                    initialStartOffset = androidx.compose.animation.core.StartOffset(i * 160)
                ),
                label = "dotA$i"
            )
            Box(
                Modifier.padding(horizontal = gap)
                    .size(dot)
                    .graphicsLayer {
                        scaleX = 0.8f + 0.2f * a
                        scaleY = 0.8f + 0.2f * a
                        alpha = a
                    }
                    .clip(androidx.compose.foundation.shape.CircleShape)
                    .background(tint)
            )
        }
    }
}


/**
 * 附件面板（2026-11-16，128）。
 *
 * 用户要的是微信那种：点＋收起键盘、面板从下面升起来，四格「相册 / 拍照 / 文件 / 位置」，
 * 下面再挂一条「最近图片」。位置那一格**没接地图就只提示"暂不支持"**，不做假的。
 */
@Composable
private fun AttachmentPanel(
    recent: List<android.net.Uri>,
    onAlbum: () -> Unit,
    onCamera: () -> Unit,
    onFile: () -> Unit,
    onLocation: () -> Unit,
    onEmoji: () -> Unit,
    onPickRecent: (android.net.Uri) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(
        Modifier.fillMaxWidth()
            .heightIn(min = 260.dp)
            .background(MaterialTheme.colorScheme.surface)
            .navigationBarsPadding()
            .padding(horizontal = 10.dp, vertical = 14.dp)
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            AttCell(R.drawable.ic_att_album, tr("相册"), onAlbum, Modifier.weight(1f))
            AttCell(R.drawable.ic_att_camera, tr("拍照"), onCamera, Modifier.weight(1f))
            AttCell(R.drawable.ic_att_file, tr("文件"), onFile, Modifier.weight(1f))
            AttCell(R.drawable.ic_att_location, tr("位置"), onLocation, Modifier.weight(1f))
        }

        Spacer(Modifier.height(14.dp))
        Row(
            Modifier.fillMaxWidth().clip(squircle(12.dp))
                .tapable { onEmoji() }
                .padding(horizontal = 6.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                painterResource(R.drawable.ic_set_layers), null,
                tint = ink.copy(alpha = 0.6f), modifier = Modifier.size(20.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text(tr("表情包"), fontSize = 13.sp, color = ink.copy(alpha = 0.75f))
            Spacer(Modifier.weight(1f))
            Icon(
                painterResource(R.drawable.ic_chevron), null,
                tint = ink.copy(alpha = 0.25f), modifier = Modifier.size(14.dp)
            )
        }

        if (recent.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(
                tr("最近图片"), fontSize = 11.sp,
                color = ink.copy(alpha = 0.45f),
                modifier = Modifier.padding(start = 6.dp, bottom = 6.dp)
            )
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                recent.take(8).forEach { u ->
                    RecentShot(u) { onPickRecent(u) }
                }
            }
        }
    }
}

@Composable
private fun AttCell(@DrawableRes icon: Int, label: String, onClick: () -> Unit, modifier: Modifier) {
    Column(
        modifier.tapable { onClick() }.padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            Modifier.size(52.dp).clip(squircle(16.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                painterResource(icon), null,
                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f),
                modifier = Modifier.size(24.dp)
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(label, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
    }
}

/** 最近图片缩略图（IO 解码，失败就画个占位，不抛）。*/
@Composable
private fun RecentShot(uri: android.net.Uri, onClick: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current.applicationContext
    val bmp by androidx.compose.runtime.produceState<android.graphics.Bitmap?>(
        initialValue = null, uri
    ) {
            value = withContext(Dispatchers.IO) {
                runCatching {
                    ctx.contentResolver.openInputStream(uri)?.use { ins ->
                        val o = android.graphics.BitmapFactory.Options().apply { inSampleSize = 8 }
                        android.graphics.BitmapFactory.decodeStream(ins, null, o)
                    }
                }.getOrNull()
            }
    }
    Box(
        Modifier.size(58.dp).clip(squircle(9.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f))
            .tapable { onClick() }
    ) {
        bmp?.let {
            androidx.compose.foundation.Image(
                bitmap = it.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}
