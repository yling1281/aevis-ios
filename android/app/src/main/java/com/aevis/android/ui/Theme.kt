package com.aevis.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 设计 token —— **逐条抄 iOS 的 `DesignSystem/V2.swift`**。
 *
 * 用户 2026-11-13：「安卓照搬 iOS，完全模拟 iOS 的 UI，动效我不管」。
 * 所以这里的数值不是"看着差不多"，而是跟 iOS 一行一行对得上：
 * 卡片圆角 22、行圆角 18、左右留白 18、字号 26/20/15/13.5/12/11。
 */
object V2 {
    val bgLight = Color(0xFFF7F6FB)
    val bgDark = Color(0xFF14131A)
    val cardLight = Color(0xFFFFFFFF)
    val cardDark = Color(0xFF1E1D26)
    val wellLight = Color(0xFFF1F0F8)
    val wellDark = Color(0xFF272530)
    val alert = Color(0xFFE5484D)

    /** 主色 —— 跟 iOS `AppSettings.accentPalette[0]` 同一个值（#9B8AF0）。*/
    val accent = Color(0xFF9B8AF0)

    /** 六支主题色，顺序与 iOS 完全一致，以后加换色直接用。*/
    val accentPalette = listOf(
        Color(0xFF9B8AF0), // 淡紫
        Color(0xFF6FA8E8), // 淡蓝
        Color(0xFF21A394), // 青
        Color(0xFFE05185), // 玫红
        Color(0xFFEB8C2E), // 橙
        Color(0xFF669E33)  // 绿
    )

    val cardRadius = 22.dp
    val rowRadius = 18.dp
    val gutter = 18.dp
    val iconBox = 38.dp
    val iconRadius = 13.dp

    val display = 26.sp
    val title = 20.sp
    val body = 15.sp
    val sub = 13.5.sp
    val tiny = 12.sp
    val micro = 11.sp
}

@Composable
fun AevisTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) {
        darkColorScheme(
            primary = V2.accent, background = V2.bgDark, surface = V2.cardDark,
            onBackground = Color(0xFFF3F2F8), onSurface = Color(0xFFF3F2F8),
            surfaceVariant = V2.wellDark
        )
    } else {
        lightColorScheme(
            primary = V2.accent, background = V2.bgLight, surface = V2.cardLight,
            onBackground = Color(0xFF17161C), onSurface = Color(0xFF17161C),
            surfaceVariant = V2.wellLight
        )
    }
    MaterialTheme(colorScheme = scheme, typography = MaterialTheme.typography) {
        content()
    }
}

/** 标题字重统一走这里，别各处手写 FontWeight。*/
val TitleStyle = TextStyle(fontSize = V2.title, fontWeight = FontWeight.SemiBold)
val DisplayStyle = TextStyle(fontSize = V2.display, fontWeight = FontWeight.Bold)
