package com.aevis.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.FontWeight
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
    val cardRadius = 24.dp
    val rowRadius = 18.dp
    val gutter = 20.dp
    val cardPad = 18.dp
    val rowHeight = 58.dp
    val iconBox = 40.dp
    val iconRadius = 13.dp
    val sectionGap = 22.dp

    // 字号：display 28 / title 21 / body 16 / sub 14 / tiny 12.5 / micro 11.5
    val display = 28.sp
    val title = 21.sp
    val body = 16.sp
    val sub = 14.sp
    val tiny = 12.5.sp
    val micro = 11.5.sp
}

@Composable
fun AevisTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) {
        darkColorScheme(
            primary = V2.accent, background = V2.bgDark, surface = V2.cardDark,
            onBackground = Color(0xFFF3F1EE), onSurface = Color(0xFFF3F1EE),
            surfaceVariant = V2.wellDark, outline = V2.lineDark
        )
    } else {
        lightColorScheme(
            primary = V2.accent, background = V2.bgLight, surface = V2.cardLight,
            onBackground = Color(0xFF1D1B17), onSurface = Color(0xFF1D1B17),
            surfaceVariant = V2.wellLight, outline = V2.lineLight
        )
    }
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
