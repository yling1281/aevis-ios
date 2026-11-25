package com.aevis.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import java.util.Locale

/**
 * 数字翻动（2026-11-24，对标 iOS `AnimatedNumber`）。
 *
 * 会员切换套餐档位时，用量数字要"翻着变"而不是硬切 —— 用户明确要的动效。
 * 两种用法：
 * - [AnimatedNumber]：整数翻动（用量数字 / 天数 / 百分比），位变化时纵向滑入滑出；
 * - [AnimatedDecimal]：一位小数翻动（价格 14.9 这种），内部用 `animateFloatAsState`
 *   平滑过渡，避免逐帧跳字。
 *
 * 都是纯展示组件，不持有状态；`value` 变了就动，没变不重绘。
 */
@Composable
fun AnimatedNumber(
    value: Int,
    modifier: Modifier = Modifier,
    style: TextStyle,
    color: Color = Color.Unspecified,
    suffix: String = ""
) {
    AnimatedContent(
        targetState = value,
        transitionSpec = {
            (slideInVertically(animationSpec = tween(260)) { it / 2 } + fadeIn(tween(260)))
                .togetherWith(
                    slideOutVertically(animationSpec = tween(200)) { -it / 2 } +
                        fadeOut(tween(160))
                )
                .using(androidx.compose.animation.SizeTransform(clip = false))
        },
        label = "animatedNumber"
    ) { v ->
        Text(
            text = String.format(Locale.getDefault(), "%d%s", v, suffix),
            modifier = modifier,
            style = color.let { if (it == Color.Unspecified) style else style.copy(color = it) }
        )
    }
}

/** 带一位小数的翻动数字（价格用）。*/
@Composable
fun AnimatedDecimal(
    value: Double,
    modifier: Modifier = Modifier,
    style: TextStyle,
    color: Color = Color.Unspecified,
    prefix: String = "",
    suffix: String = ""
) {
    val shown by animateFloatAsState(
        targetValue = value.toFloat(),
        animationSpec = tween(380),
        label = "animatedDecimal"
    )
    Text(
        text = String.format(Locale.getDefault(), "%s%.1f%s", prefix, shown, suffix),
        modifier = modifier,
        style = color.let { if (it == Color.Unspecified) style else style.copy(color = it) }
    )
}
