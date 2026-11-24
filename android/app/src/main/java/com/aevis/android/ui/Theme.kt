package com.aevis.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
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
    /** 米白底（2026-11-13 用户：「背景可以米白色」）。iOS / 小程序同一支色。*/
    val bgLight = Color(0xFFFAF7F1)
    val bgDark = Color(0xFF16151A)
    val cardLight = Color(0xFFFFFFFF)
    val cardDark = Color(0xFF201E26)
    val wellLight = Color(0xFFF2EDE3)
    val wellDark = Color(0xFF2A2733)
    /** 米白底上的细分割线 */
    val lineLight = Color(0xFFEDE6D9)
    val lineDark = Color(0xFF2E2B38)
    val alert = Color(0xFFE5484D)

    /** 主色 —— 跟 iOS `AppSettings.accentPalette[0]` 同一个值（#9B8AF0）。*/
    val accent = Color(0xFF9B8AF0)

    /** 六支主题色，顺序与 iOS 完全一致。*/
    val accentPalette = listOf(
        Color(0xFF9B8AF0), // 淡紫
        Color(0xFF6FA8E8), // 淡蓝
        Color(0xFF21A394), // 青
        Color(0xFFE05185), // 玫红
        Color(0xFFEB8C2E), // 橙
        Color(0xFF669E33)  // 绿
    )

    // 圆角 / 间距：比上一版都大一号，别挤
    val cardRadius = 22.dp   // = iOS V2.cardRadius
    val rowRadius = 18.dp
    /** 卡片描边：极淡一层，iOS 那张卡就是靠它"立起来"的（不是靠阴影）。*/
    val strokeLight = Color(0x14000000)
    val strokeDark = Color(0x1FFFFFFF)
    val gutter = 18.dp       // = iOS V2.gutter
    val cardPad = 18.dp
    val rowHeight = 64.dp
    val iconBox = 38.dp      // = iOS V2.iconBox
    val iconRadius = 13.dp
    val sectionGap = 14.dp   // iOS: 卡片与下一节标题之间 14

    // 字号：**逐条对齐 iOS `V2.swift`**（26 / 20 / 15 / 13.5 / 12 / 11）。
    // 2026-11-14 用户：「就是纯安卓，不对，纯苹果那种味道」——
    // 上一版整体比 iOS 大 1~2pt（body 16 vs 15、标题 28 vs 20），
    // 加起来就成了"安卓那种撑开的观感"。
    val display = 26.sp
    val title = 20.sp
    val body = 15.sp
    val sub = 13.5.sp
    val tiny = 12.sp
    val micro = 11.sp
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
        darkColorScheme(
            primary = V2.accent, background = V2.bgDark, surface = V2.cardDark,
            onBackground = Color(0xFFF3F1EE), onSurface = Color(0xFFF3F1EE),
            surfaceVariant = V2.wellDark, outline = V2.lineDark
        )
    } else {
        // 浅色：米白底 + 纯白卡片 + 近黑的字。三个值都在 `V2` 里定死了，
        // 别在这儿另调 —— iOS / 小程序用的是同一支米白。
        lightColorScheme(
            primary = V2.accent, background = V2.bgLight, surface = V2.cardLight,
            onBackground = Color(0xFF1D1B17), onSurface = Color(0xFF1D1B17),
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
