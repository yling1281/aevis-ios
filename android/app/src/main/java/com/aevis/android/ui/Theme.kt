package com.aevis.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.TextStyle
import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 设计 token —— **逐条对 iOS 的 `DesignSystem/V2.swift`**。
 *
 * 用户 2026-11-13：「安卓照搬 iOS，完全模拟 iOS 的 UI」「东西放大一点点、空一点点、
 * 不要那么密」—— 所以这一版整体把留白和字号都抬了一档，底色换成**米白**。
 */
object V2 {
    // ─────────────────────────────────────────────────────────────────────
    // 2026-11-29 全量向 iOS 靠齐。iOS 在 11-22/11-25 做过两次视觉重做，
    // 权威 token 在 ios-rewrite/AevisApp/Models/Models.swift 的 `AE`
    // 和 Views/GlassComponents.swift 的 `AEGlass`（本文件旧注释引用的
    // `DesignSystem/V2.swift` 并不存在）。逐条对齐这两处，别再写魔法数。
    // ─────────────────────────────────────────────────────────────────────
    /** 底色：对齐 iOS AE.bgLight #F7F5F0 / bgDark #141416（旧值偏黄偏灰）。*/
    val bgLight = Color(0xFFF7F5F0)
    val bgDark = Color(0xFF141416)
    val cardLight = Color(0xFFFFFFFF)
    val cardDark = Color(0xFF1E2028)     // = iOS AE.card 深色
    val wellLight = Color(0xFFEAEDF4)    // = iOS AE.accentSoft 浅色
    val wellDark = Color(0xFF2B3346)     // = iOS AE.accentSoft 深色
    /** 米白底上的细分割线 */
    val lineLight = Color(0xFFEDE6D9)
    val lineDark = Color(0xFF3A404E)     // = iOS AE.cardStroke 深色
    val alert = Color(0xFFE5484D)

    /** 主强调色：对齐 iOS AE.accent —— 深墨靛蓝（浅）/ 提亮蓝（深），2026-11-22「去掉旧紫」。*/
    val accent = Color(0xFF2F3A56)          // = iOS AE.accent 浅色 / accentDeep 实底
    val accentDark = Color(0xFFA9B7D8)      // = iOS AE.accent 深色提亮
    val accentLift = Color(0xFF4A5676)      // = iOS AE.accentLift 高光
    /** 白字按钮固定深底（iOS AE.accentDeep：改浅会毁掉对比度）。*/
    val accentDeep = Color(0xFF2F3A56)

    /** 登录页品牌紫：iOS AE.brandPurple 刻意保留，登录页专用，不随全局去紫。*/
    val brandPurple = Color(0xFF9B8AF0)

    /** 六支气泡预设色，顺序与 iOS 完全一致（气泡是可换色功能，保留）。*/
    val accentPalette = listOf(
        Color(0xFF9B8AF0), // 淡紫
        Color(0xFF6FA8E8), // 淡蓝
        Color(0xFF21A394), // 青
        Color(0xFFE05185), // 玫红
        Color(0xFFEB8C2E), // 橙
        Color(0xFF669E33)  // 绿
    )

    // 圆角分档：对齐 iOS AE + AEGlass（28 大卡 / 20 常规卡+气泡 / 14 按钮）
    val cardRadius = 20.dp       // = iOS AE.cardRadius（常规卡）
    val heroCardRadius = 28.dp   // = iOS AEGlass.cardRadius（用量卡/大卡）
    val bubbleRadius = 20.dp     // = iOS AEGlass.bubbleRadius
    val buttonRadius = 14.dp     // = iOS AE.buttonRadius
    val rowRadius = 18.dp
    /** 卡片描边：iOS AEGlass.strokeOpacity=0（参考图无描边，靠材质+极淡阴影分离）。*/
    val strokeLight = Color(0x00000000)
    val strokeDark = Color(0x00000000)
    val gutter = 18.dp
    val cardPad = 18.dp
    val rowHeight = 64.dp
    val iconBox = 38.dp
    val iconRadius = 13.dp
    val sectionGap = 14.dp

    // 字号：对齐 iOS AE（title17 / body15 / caption11 / sectionTitle16 / heroTitle34）
    val display = 34.sp          // = iOS AE.heroTitle（页面大标题）
    val title = 17.sp            // = iOS AE.title（旧 20 偏大，安卓观感的来源之一）
    val sectionTitle = 16.sp     // = iOS AE.sectionTitle
    val body = 15.sp             // = iOS AE.body（已对齐）
    val sub = 13.5.sp
    val tiny = 12.sp
    val micro = 11.sp            // = iOS AE.caption
}

@Composable
fun AevisTheme(content: @Composable () -> Unit) {
    // 主题（2026-11-16）：从写死深色改成可切换。
    // ⚠️ 这里**必须**读一次 `ThemePrefs.version`：`mode` 是普通 getter，
    //    改了不会自己触发重组 —— 把它当 `remember` 的 key 读，就同时完成了
    //    "订阅变化"和"拿到新值"两件事（不用再写一个没人用的局部变量）。
    val mode = remember(com.aevis.android.core.ThemePrefs.version) {
        com.aevis.android.core.ThemePrefs.mode
    }
    // 跟随系统时要读系统的值；另外两档固定。读 `isSystemInDarkTheme()` 放在外面，
    // 这样系统在后台切深/浅时，「跟随系统」这一档也会跟着变。
    val systemDark = isSystemInDarkTheme()
    val dark = when (mode) {
        com.aevis.android.core.ThemePrefs.LIGHT -> false
        com.aevis.android.core.ThemePrefs.DARK -> true
        else -> systemDark
    }
    val scheme0 = if (dark) {
        // 深色主色用提亮蓝（iOS AE.accent dark=#A9B7D8），否则深墨蓝在深底上看不清
        darkColorScheme(
            primary = V2.accentDark, background = V2.bgDark, surface = V2.cardDark,
            onBackground = Color(0xFFF2F1EC), onSurface = Color(0xFFF2F1EC),
            surfaceVariant = V2.wellDark, outline = V2.lineDark
        )
    } else {
        // 浅色：米白底 + 纯白卡片 + 深墨字（对齐 iOS AE.textPrimary #1C2231）
        lightColorScheme(
            primary = V2.accent, background = V2.bgLight, surface = V2.cardLight,
            onBackground = Color(0xFF1C2231), onSurface = Color(0xFF1C2231),
            surfaceVariant = V2.wellLight, outline = V2.lineLight
        )
    }

    // 主背景（2026-11-16，112；125 改成"每页各画一张"）：
    // 玻璃模式下 `background` 仍然给透明 —— 但**不再靠根容器垫图**，
    // 改成每个页面根部包一层 `PageBackdrop {}`（见 AppBackdrop.kt）。
    // 这样各页自己的 `.background(colorScheme.background)` 变成"透出本页背景"，
    // 切页时背景跟着该页重绘（解码结果走进程级缓存，不会每页解一次）。
    // 前景色跟着实际背景主色走：卡片里的字和直接铺在背景上的字用同一支色。
    val bgVer = com.aevis.android.core.ChatPrefs.bgVersion
    val skin = if (com.aevis.android.core.ChatPrefs.appBgType == "default") null else appSkinFor(dark)
    val scheme = if (skin == null) scheme0 else scheme0.copy(
        background = Color.Transparent,
        onBackground = skin.text,
        onSurface = skin.text
    )
    MaterialTheme(colorScheme = scheme, typography = zeroSpacing()) {
        content()
    }
}

/**
 * Material 默认给每段文字加了 0.25~0.5sp 的**字距**，那是安卓很典型的观感。
 * iOS 的 SF Pro 几乎没有字距 —— 全部压成 0，两边的字看起来才是同一套。
 */
@Composable
private fun zeroSpacing(): Typography {
    val t = Typography()
    return t.copy(
        displayLarge = t.displayLarge.copy(letterSpacing = 0.sp),
        displayMedium = t.displayMedium.copy(letterSpacing = 0.sp),
        displaySmall = t.displaySmall.copy(letterSpacing = 0.sp),
        headlineLarge = t.headlineLarge.copy(letterSpacing = 0.sp),
        headlineMedium = t.headlineMedium.copy(letterSpacing = 0.sp),
        headlineSmall = t.headlineSmall.copy(letterSpacing = 0.sp),
        titleLarge = t.titleLarge.copy(letterSpacing = 0.sp),
        titleMedium = t.titleMedium.copy(letterSpacing = 0.sp),
        titleSmall = t.titleSmall.copy(letterSpacing = 0.sp),
        bodyLarge = t.bodyLarge.copy(letterSpacing = 0.sp),
        bodyMedium = t.bodyMedium.copy(letterSpacing = 0.sp),
        bodySmall = t.bodySmall.copy(letterSpacing = 0.sp),
        labelLarge = t.labelLarge.copy(letterSpacing = 0.sp),
        labelMedium = t.labelMedium.copy(letterSpacing = 0.sp),
        labelSmall = t.labelSmall.copy(letterSpacing = 0.sp)
    )
}

/** 标题字重统一走这里，别各处手写 FontWeight。*/
val TitleStyle = TextStyle(fontSize = V2.title, fontWeight = FontWeight.SemiBold)
val DisplayStyle = TextStyle(fontSize = V2.display, fontWeight = FontWeight.Bold)

/**
 * iOS 的 `.continuous` 圆角（superellipse / squircle）。
 *
 * 用户 2026-11-14：「该圆润的地方没圆润起来……就是纯安卓，不对，
 * 纯苹果那种味道」—— 原因就在这儿：`RoundedCornerShape` 是**正圆弧**，
 * 同样半径下四角看着更"方"；iOS 的连续圆角把过渡拉长，所以显润。
 *
 * 这里用三次贝塞尔近似：控制点系数取 0.62（正圆是 0.5523），
 * 圆角到直边的过渡更长，视觉上就是 iOS 那个手感。
 */
class SquircleShape(private val radius: Dp) : Shape {
    override fun createOutline(
        size: Size,
        layoutDirection: LayoutDirection,
        density: Density
    ): Outline {
        val w = size.width
        val h = size.height
        val r = with(density) { radius.toPx() }.coerceIn(0f, minOf(w, h) / 2f)
        if (r <= 0f) {
            return Outline.Rectangle(androidx.compose.ui.geometry.Rect(0f, 0f, w, h))
        }
        val c = r * 0.62f
        val path = Path().apply {
            moveTo(r, 0f)
            lineTo(w - r, 0f)
            cubicTo(w - r + c, 0f, w, r - c, w, r)
            lineTo(w, h - r)
            cubicTo(w, h - r + c, w - r + c, h, w - r, h)
            lineTo(r, h)
            cubicTo(r - c, h, 0f, h - r + c, 0f, h - r)
            lineTo(0f, r)
            cubicTo(0f, r - c, r - c, 0f, r, 0f)
            close()
        }
        return Outline.Generic(path)
    }
}

/** 随手用：`clip(squircle(26.dp))`。*/
fun squircle(radius: Dp): Shape = SquircleShape(radius)

/**
 * 背景色 → 可读的前景色（2026-11-16，112）。
 *
 * 用**线性化**之后的相对亮度：`0.2126R + 0.7152G + 0.0722B`。
 * ⚠️ 直接用 sRGB 分量加权会低估深色（0.5 灰的实际观感比数值亮），
 *    所以先做 gamma 还原（`c<=0.03928 ? c/12.92 : ((c+0.055)/1.055)^2.4`）再加权，
 *    这也是 WCAG 里那套算法。
 *
 * 深底（>0.5）返回 #F5F6F8，浅底返回 #1B1D22。
 */
fun onColorFor(bg: Color): Color {
    fun lin(c: Float): Float =
        if (c <= 0.03928f) c / 12.92f
        else Math.pow(((c + 0.055f) / 1.055f).toDouble(), 2.4).toFloat()

    // Compose 的 `Color.r/g/b` 就是 sRGB 编码的 0–1 分量，先 gamma 还原再加权
    val r = lin(bg.red.coerceIn(0f, 1f))
    val g = lin(bg.green.coerceIn(0f, 1f))
    val b = lin(bg.blue.coerceIn(0f, 1f))
    val l = 0.2126f * r + 0.7152f * g + 0.0722f * b
    return if (l > 0.5f) Color(0xFF1B1D22) else Color(0xFFF5F6F8)
}

/** `onColorFor` 返回的那两个前景色，单独拎出来方便比较。*/
val OnLightBg = Color(0xFF1B1D22)
val OnDarkBg = Color(0xFFF5F6F8)

// ------------------------------------------------------------------ 磨砂玻璃（2026-11-24，对标 iOS `.glassSheetBackground()`）
//
// 用户：「所有半屏/底部弹窗背后要磨砂玻璃，别是透明的，明色偏白、暗色偏暗」。
// 统一走语义色：从**当前主题**取明暗，不跟着背景亮度翻转（跟 AppSkin 同一口径）。
// 半透明（alpha < 1）是为了透出底下那一层已模糊的 PageBackdrop —— 这样才是"磨砂"，
// 而不是一块死白 / 死黑。alpha 给得高（0.9+）保证弹窗上的字始终有足够对比。

/** 半窗 / 底部弹窗的容器色：明色偏白、暗色偏暗。*/
@Composable
fun frostedSheetColor(): Color {
    val dark = isSystemInDarkTheme() ||
        MaterialTheme.colorScheme.surface.luminance() < 0.5f
    return if (dark) Color(0xFF1E1D24).copy(alpha = 0.94f)
    else Color(0xFFFFFFFF).copy(alpha = 0.93f)
}

/** 弹窗背后的遮罩：磨砂感（半透明），同样跟主题明暗。*/
@Composable
fun frostedScrimColor(): Color {
    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    return if (dark) Color(0xFF000000).copy(alpha = 0.42f)
    else Color(0xFF1B1A24).copy(alpha = 0.28f)
}

/** 商城"墨点"卡片的语义色（2026-11-24，夜间修复）。
 *  以前写死浅色 highlight，夜间一片糊；现在按主题给一支够亮的紫 + 相应的弱底。*/
@Composable
fun pointAccentColor(): Color {
    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    return if (dark) Color(0xFFB9A9FF) else V2.accent
}

@Composable
fun pointTintColor(): Color = pointAccentColor().copy(alpha = 0.14f)
