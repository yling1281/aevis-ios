package com.aevis.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.produceState
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.border
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import com.aevis.android.core.ChatPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/*
 * 主背景 + 毛玻璃 + 文字自适应（2026-11-16，112）。
 *
 * 数据在 `ChatPrefs.appBgType / appBgValue / appTint`（111 那批建好但没人读，R8 直接裁掉了）。
 * 这里补渲染，规矩只有三条：
 *
 *   1. **背景只画一次** —— `Shell` 最外层一张，各页面不再自己铺底色
 *      （做法是玻璃模式下把主题的 `background` 换成透明，见 `AevisTheme`）。
 *   2. **不对整页做 `Modifier.blur`** —— 那是逐帧重采样，低端机滚动必掉帧。
 *      毛玻璃一律用「半透明 + 1dp 亮边」近似；`Blur` 只留在聊天背景那一处
 *      （`BackgroundStore`，单独一层，且用户自己调 0 就不加）。
 *   3. 容器给了对比基底（不透明/半透明底），字用主题前景色；
 *      直接铺在背景上的字用 `onColorFor(实际背景色)` —— 两个值在玻璃模式下是同一支，
 *      所以不会出现「深色玻璃 + 深色字」。
 */

/** `#RRGGBB` / `#AARRGGBB` → Color；解析不了返回 null。*/
fun parseBgColor(raw: String): Color? {
    val s = raw.trim().removePrefix("#")
    return runCatching {
        when (s.length) {
            6 -> Color(0xFF000000L.toInt() or s.toLong(16).toInt())
            8 -> Color(s.toLong(16).toInt())
            else -> null
        }
    }.getOrNull()
}

/** 主背景图的本地文件（`files/bg/app.jpg`）——跟聊天背景分开放，互不覆盖。*/
object AppBgStore {
    private var ctxRef: android.content.Context? = null

    fun init(ctx: android.content.Context) {
        ctxRef = ctx.applicationContext
    }

    private fun file(): File {
        val d = File(ctxRef!!.filesDir, "bg")
        if (!d.exists()) d.mkdirs()
        return File(d, "app.jpg")
    }

    /** 相册选图 → 压到 1440 宽存本地 → 返回绝对路径（存进 `appBgValue`）。*/
    fun import(ctx: android.content.Context, uri: Uri): String? = runCatching {
        // R-04：先按屏幕宽采样（原来直接解 4K 原图，30–50MB）
        val (sw0, sh0) = com.aevis.android.data.screenSize(ctx)
        val src = ctx.contentResolver.openInputStream(uri)?.use {
            com.aevis.android.data.decodeSampled(it, sw0, sh0)
        } ?: return null
        val w = 1440
        val h = (src.height * (w.toFloat() / src.width)).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(src, w, h, true)
        val tmp = File(file().parentFile, "app.tmp")
        tmp.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 86, it) }
        val dst = file()
        if (dst.exists()) dst.delete()
        if (!tmp.renameTo(dst)) {
            tmp.copyTo(dst, overwrite = true)
            tmp.delete()
        }
        dst.absolutePath
    }.getOrNull()

    fun clear() {
        runCatching { file().delete() }
    }

    fun has(): Boolean = runCatching { file().exists() }.getOrDefault(false)
}

/**
 * 「背景到底多亮」的唯一来源。
 *
 * `AppBackdrop` 算完写进来（纯色直接算、图片取平均色再叠蒙层），
 * `AevisTheme` / `V2Card` / dock 读它 —— 这样文字颜色和玻璃底色永远配对。
 * 写成 Compose 状态是为了让「图片算完了」能触发一次重组（只触发一次，值相同不再传播）。
 */
internal object AppBackdropState {
    var effective by mutableStateOf(Color.Transparent)
}

/** 毛玻璃/文字的一套取值。`default` 模式下不用它（沿用原来的不透明观感）。*/
class AppSkin(
    val text: Color,
    val cardFill: Color,
    val cardStroke: Color,
    val barFill: Color
)

/** 深色主题？**不能用 `background`** —— 玻璃模式下它是透明的（亮度 0，会永远判成深色）。*/
@Composable
fun isDarkTheme(): Boolean = MaterialTheme.colorScheme.surface.luminance() < 0.5f

/** 叠蒙层之后的有效底色（图片平均色 → 压暗/提亮）。*/
private fun tinted(base: Color, tint: Boolean, dark: Boolean): Color {
    if (!tint) return base
    val over = if (dark) Color.Black else Color.White
    val a = if (dark) 0.42f else 0.30f
    return Color(
        red = base.red * (1 - a) + over.red * a,
        green = base.green * (1 - a) + over.green * a,
        blue = base.blue * (1 - a) + over.blue * a,
        alpha = 1f
    )
}

/**
 * 按「实际背景色」给出一整套玻璃取值。
 *
 * 明底：卡片 `White@0.62` + 边框 `Black@0.06` + 字 `#1B1D22`
 * 暗底：卡片 `Black@0.52` + 边框 `White@0.18` + 字 `#F5F6F8`
 * 顶栏 / 输入栏 / dock 比卡片再实一点（0.72），那三处上面压着可点的字，糊不得。
 */
fun appSkinFor(dark: Boolean): AppSkin {
    val bg = AppBackdropState.effective
    // 还没算出来（图片还在解码）时按主题走，别闪一下黑底白字
    val base = if (bg == Color.Transparent) {
        if (dark) Color(0xFF16151A) else Color(0xFFFAF7F1)
    } else bg
    // 131：玻璃底色**跟主题走，不跟背景亮度翻转**。
    // 背景亮度只做 ±10% 的微调（暗背景让浅色玻璃更实一点），绝不把浅色主题变成黑卡。
    val luma = base.luminance()
    val adj = when {
        luma < 0.25f -> 0.10f      // 背景很暗 → 白玻璃更实
        luma > 0.80f -> -0.06f     // 背景很亮 → 白玻璃略透
        else -> 0f
    }
    // 文字色也跟主题（不再按背景亮度反转）
    val text = if (dark) OnDarkBg else OnLightBg
    // 120：卡片/条目/输入栏的 alpha 走用户设置（默认 85%，下限 40%）。
    val a = (ChatPrefs.glassAlpha / 100f + if (dark) 0f else adj).coerceIn(0.4f, 1f)
    val barA = (a + 0.06f).coerceAtMost(1f)
    return if (text == OnDarkBg) {
        AppSkin(
            text = OnDarkBg,
            cardFill = Color.Black.copy(alpha = a),
            cardStroke = Color.White.copy(alpha = 0.18f),
            barFill = Color.Black.copy(alpha = barA)
        )
    } else {
        AppSkin(
            text = OnLightBg,
            cardFill = Color.White.copy(alpha = a),
            cardStroke = Color.Black.copy(alpha = 0.06f),
            barFill = Color.White.copy(alpha = barA)
        )
    }
}

/**
 * 当前是否处于「玻璃」模式（`appBgType != default`）。`null` = 老的不透明观感。
 *
 * 所有容器（`V2Card` / dock / 输入栏 / 半窗）都读它；读 `bgVersion` 是为了
 * 在设置里改完立刻生效（这几个字段是普通 prefs getter，不会自己触发重组）。
 */
@Composable
fun appSkin(): AppSkin? {
    val ver = ChatPrefs.bgVersion
    if (ChatPrefs.appBgType == "default") return null
    return appSkinFor(isDarkTheme())
}

/**
 * 背景解码的**进程级缓存**（2026-11-16，125）。
 *
 * 现在每个页面各自铺背景，但图**只解一次**：key（路径/蒙层/透明度/主题）没变就直接复用，
 * 切 tab、进二级页都只是引用同一个 `Bitmap`。日志 `AevisBackdrop: 解码背景一次` 可验。
 */
internal object AppBackdropCache {
    @Volatile var key: String = ""
    @Volatile var bitmap: Bitmap? = null
    /** 预模糊过的一份（1/8 缩 → 放大），给卡片做「背后那块背景」用（130）。*/
    @Volatile var blurred: Bitmap? = null
}

/**
 * 一页的背景层（2026-11-16，125）。
 *
 * 用户明确否掉了「根容器透明化 + 垫一张」的做法：要**每个页面自己的背景**。
 * 所以 `PageBackdrop` 在每个页面根部画一次（各页独立渲染，切页跟着重绘），
 * 但解码结果走 [AppBackdropCache]，不会 8 个页面解 8 次。
 */
@Composable
private fun BackdropLayer(modifier: Modifier, dark: Boolean) {
    val type = ChatPrefs.appBgType
    if (type == "default") return
    val bgPath = ChatPrefs.appBgValue
    val tint = ChatPrefs.appTint
    val ver = ChatPrefs.bgVersion
    val opacity = ChatPrefs.bgOpacity.coerceIn(0, 100) / 100f
    val base = if (dark) Color(0xFF16151A) else Color(0xFFFAF7F1)
    val ctx = LocalContext.current

    // 纯色：直接铺，不用等任何异步
    if (type == "solid") {
        val c = parseBgColor(bgPath) ?: base
        LaunchedEffect(c) { AppBackdropState.effective = c }
        Box(modifier.background(c))
        return
    }

    // 图片：每页都调用，但只有 key 变了才真解码
    val key = "$bgPath|$tint|$opacity|$dark|$ver"
    val bmp by produceState<Bitmap?>(
        initialValue = if (AppBackdropCache.key == key) AppBackdropCache.bitmap else null,
        key
    ) {
        val cached = AppBackdropCache.bitmap
        if (AppBackdropCache.key == key && cached != null) {
            value = cached
            return@produceState
        }
        val loaded = withContext(Dispatchers.IO) { loadAppBg(ctx, bgPath) }
        val avg = loaded?.let { withContext(Dispatchers.IO) { averageColor(it) } }
            ?: (if (dark) Color(0xFF2A2733) else Color(0xFFEDE6D9))
        AppBackdropCache.bitmap = loaded
        AppBackdropCache.blurred = loaded?.let { withContext(Dispatchers.IO) { frost(it) } }
        AppBackdropCache.key = key
        AppBackdropState.effective = blend(base, tinted(avg, tint, dark), opacity)
        android.util.Log.i("AevisBackdrop", "解码背景一次（${if (loaded != null) "成功" else "失败"}）")
        value = loaded
    }
    // 缓存命中时 effective 可能还是上一页算的（同 key 其实一致），这里补一次，保证首帧字色正确
    LaunchedEffect(bmp, key) {
        if (bmp != null && AppBackdropState.effective == Color.Transparent) {
            val avg = withContext(Dispatchers.IO) { averageColor(bmp!!) }
            AppBackdropState.effective = blend(base, tinted(avg, tint, dark), opacity)
        }
    }

    Box(modifier.background(base)) {
        bmp?.let { b ->
            Image(
                bitmap = b.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize().alpha(opacity.coerceIn(0f, 1f))
            )
        }
        if (tint) {
            Box(
                Modifier.fillMaxSize().background(
                    if (dark) Color.Black.copy(alpha = 0.42f)
                    else Color.White.copy(alpha = 0.30f)
                )
            )
        }
    }
}

/**
 * 页面级背景容器（2026-11-16，125）。
 *
 * 用法：把页面根节点包进来 —— `PageBackdrop { Column(...) { ... } }`。
 * `default` 模式下它就是一层主题底色（跟原来的观感一致，什么都不多画）。
 */
@Composable
fun PageBackdrop(
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.BoxScope.() -> Unit
) {
    val dark = isDarkTheme()
    Box(
        modifier.fillMaxSize()
            .background(if (dark) Color(0xFF16151A) else Color(0xFFFAF7F1))
    ) {
        BackdropLayer(Modifier.fillMaxSize(), dark)
        content()
    }
}

/**
 * 老接口：只在根容器画一次（112 的做法）。125 起改用 [PageBackdrop]，
 * 这个函数保留给还没接的调用点，行为等价于"画一层背景"。
 */
@Composable
fun AppBackdrop(modifier: Modifier = Modifier) {
    val dark = isDarkTheme()
    Box(modifier) { BackdropLayer(Modifier.fillMaxSize(), dark) }
}

/** 线性混合：`a × (1-t) + b × t`。背景不透明度用的就是它。*/
private fun blend(a: Color, b: Color, t: Float): Color {
    val k = t.coerceIn(0f, 1f)
    return Color(
        red = a.red * (1 - k) + b.red * k,
        green = a.green * (1 - k) + b.green * k,
        blue = a.blue * (1 - k) + b.blue * k,
        alpha = 1f
    )
}

/** 本地路径直接解码；`/v1/media/…` 这种服务端相对路径走网络（跟 `Avatar()` 一个口径）。*/
private suspend fun loadAppBg(ctx: android.content.Context, value: String): Bitmap? {
    if (value.isBlank()) return null
    return withContext(Dispatchers.IO) {
        runCatching {
            if (isLocalFile(value)) {
                // R-04：背景按屏幕尺寸采样
                val (sw, sh) = com.aevis.android.data.screenSize(ctx)
                com.aevis.android.data.decodeSampledFile(localImagePath(value), sw, sh)
            } else {
                com.aevis.android.data.Api.fetchImage(value)
            }
        }.getOrNull()
    }
}

/** 图片平均色：缩到 1×1 再读那一个像素，几十微秒的事。*/
private fun averageColor(bmp: Bitmap): Color {
    val one = Bitmap.createScaledBitmap(bmp, 1, 1, true)
    val p = one.getPixel(0, 0)
    if (one !== bmp) runCatching { one.recycle() }
    return Color(0xFF000000L.toInt() or (p and 0x00FFFFFF))
}


/**
 * 预模糊一份（2026-11-16，130）：缩到 1/8 再放大回来。
 *
 * 不用 `Modifier.blur`（逐帧重采样，滚动就掉帧），也不依赖 `RenderEffect`（31+ 才有）。
 * 缩小-放大是"离线一次 + 静态复用"，API 26 上也很便宜，观感就是磨砂。
 */
private fun frost(src: Bitmap): Bitmap? = runCatching {
    val w = (src.width / 8).coerceAtLeast(8)
    val h = (src.height / 8).coerceAtLeast(8)
    val small = Bitmap.createScaledBitmap(src, w, h, true)
    val out = Bitmap.createScaledBitmap(small, src.width, src.height, true)
    if (small !== src && small !== out) runCatching { small.recycle() }
    out
}.getOrNull()

/**
 * 真·磨砂卡片（2026-11-16，130）：卡片里透出的是**它背后那块背景的模糊版本**。
 *
 * 做法：把预模糊图按卡片在屏幕上的位置偏移绘制，再裁成卡片形状 ——
 * 不用整页模糊、不用抓实时快照，滚动时是纯静态绘制。
 * 覆盖层颜色**跟主题走**（131）：浅色白 55%、深色黑 45%；背景明暗只微调不翻转。
 */
@Composable
fun GlassSurface(
    dark: Boolean,
    modifier: Modifier = Modifier,
    corner: androidx.compose.ui.unit.Dp = 18.dp,
    content: @Composable androidx.compose.foundation.layout.BoxScope.() -> Unit
) {
    var pos by androidx.compose.runtime.remember {
        androidx.compose.runtime.mutableStateOf(Offset.Zero)
    }
    val conf = androidx.compose.ui.platform.LocalConfiguration.current
    val density = androidx.compose.ui.platform.LocalDensity.current
    val screenW = with(density) { conf.screenWidthDp.dp.toPx() }
    val screenH = with(density) { conf.screenHeightDp.dp.toPx() }
    val overlay = if (dark) Color.Black.copy(alpha = 0.45f) else Color.White.copy(alpha = 0.55f)
    val border = if (dark) Color.White.copy(alpha = 0.14f) else Color.Black.copy(alpha = 0.06f)

    androidx.compose.foundation.layout.Box(
        modifier
            .onGloballyPositioned { pos = it.positionInWindow() }
            .clip(squircle(corner))
            .drawBehind {
                val b = AppBackdropCache.blurred
                if (b != null && screenW > 0f && screenH > 0f) {
                    val sx = b.width / screenW
                    val sy = b.height / screenH
                    drawImage(
                        image = b.asImageBitmap(),
                        srcOffset = IntOffset(
                            (pos.x * sx).toInt().coerceAtLeast(0),
                            (pos.y * sy).toInt().coerceAtLeast(0)
                        ),
                        srcSize = IntSize(
                            (size.width.toFloat() * sx).toInt().coerceAtLeast(1),
                            (size.height.toFloat() * sy).toInt().coerceAtLeast(1)
                        ),
                        dstOffset = androidx.compose.ui.unit.IntOffset.Zero,
                        dstSize = IntSize(
                            size.width.toInt(), size.height.toInt()
                        )
                    )
                }
                drawRect(overlay)
            }
            .border(1.dp, border, squircle(corner))
    ) { content() }
}
