package com.aevis.android.ui

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.ui.unit.IntOffset

/**
 * 统一动效约定（2026-11-29 全量向 iOS 靠齐）。
 *
 * 逐条对标 iOS `ios-rewrite/AevisApp/Views/Motion.swift` 的 `AEMotion`：
 * - 页面切换「翻页感」：新页从右进、旧页往左出 + 淡入淡出，**短、跟手、不弹跳**
 *   （iOS `.easeInOut(0.22)`；整屏位移上做 spring 弹跳会晕）→ Compose 用
 *   `FastOutSlowInEasing` + 220ms tween 逼近 easeInOut。
 * - 反向切页：新页从左进、旧页往右出。
 * - 元素依次上跳：`spring(response 0.5, dampingFraction 0.86)` → Compose 用
 *   `Spring.DampingRatioNoBouncy` + `StiffnessMedium` 逼近（0.86 高阻尼，几乎不弹）。
 * - stagger 每级 0.05s、位移 14dp。
 *
 * ⚠️ 这里只放**固定**的转场/上跳参数。用户在「外观与动效」页可调的那三个
 * （按压缩放 / 上浮位移 / 回弹力度，见 AnimPrefs）是另一套，不要混。
 */
object AEMotion {
    /** iOS pageAnimation = easeInOut(0.22)。整页位移不做弹跳。*/
    const val PAGE_DURATION_MS = 220

    /** slide 的 spec 是位移（IntOffset）；fade 的 spec 是透明度（Float），类型不同不能共用。*/
    fun slideSpec() = tween<IntOffset>(
        durationMillis = PAGE_DURATION_MS, easing = FastOutSlowInEasing
    )
    fun fadeSpec() = tween<Float>(durationMillis = PAGE_DURATION_MS)

    /** 正向：新页从右进（+整页宽）、旧页往左出（-整页宽）。`it` = 组件宽度。*/
    val enterForward: EnterTransition
        get() = slideInHorizontally(animationSpec = slideSpec()) { it } + fadeIn(fadeSpec())
    val exitForward: ExitTransition
        get() = slideOutHorizontally(animationSpec = slideSpec()) { -it } + fadeOut(fadeSpec())

    /** 反向：新页从左进（-整页宽）、旧页往右出（+整页宽）。*/
    val enterBackward: EnterTransition
        get() = slideInHorizontally(animationSpec = slideSpec()) { -it } + fadeIn(fadeSpec())
    val exitBackward: ExitTransition
        get() = slideOutHorizontally(animationSpec = slideSpec()) { it } + fadeOut(fadeSpec())

    /** iOS riseAnimation = spring(response 0.5, dampingFraction 0.86)。*/
    val riseSpec = spring<Float>(
        dampingRatio = Spring.DampingRatioNoBouncy,  // ≈ 0.86，几乎不弹
        stiffness = Spring.StiffnessMedium           // ≈ response 0.5
    )
    /** 开屏元素依次上跳：每级延迟毫秒（iOS staggerDelay step 0.05s）。*/
    const val STAGGER_STEP_MS = 50
    /** 上跳位移 dp（iOS StaggerIn.distance = 14pt）。*/
    const val RISE_DISTANCE_DP = 14
}
