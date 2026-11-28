package com.aevis.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.abs

/**
 * 分段控件 + 内容切换动画（2026-11-16）。
 *
 * 用户：「分段切换要有动画」。以前每处都是硬切、各写一份胶囊按钮 ——
 * 商城/广场、聊天外观的气泡形状…七八份`.tapable { tab = i }`，
 * 改一次样式要跑遍全工程。这里抽成一份，**全工程只留这一个实现**。
 *
 * 视觉照 Dock 那套「流动指示器」：一块底色在两个格子之间滑过去，
 * 滑动时横向拉长、纵向压扁（squash & stretch），停下时 spring 回弹。
 */
@Composable
internal fun SegmentedTabs(
    tabs: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val ink = MaterialTheme.colorScheme.onSurface
    if (tabs.isEmpty()) return

    BoxWithConstraints(
        modifier
            .padding(horizontal = V2.gutter)
            .clip(squircle(13.dp))
            .background(ink.copy(alpha = 0.05f))
            .padding(4.dp)
            // 🔴 2026-11-16 必须有固定高度：
            //    里面那个指示块是 `fillMaxHeight()`，如果这里没有高度约束，
            //    它会按父级给的 maxHeight（= 整列剩余高度）把自己撑成一条**通到屏幕底的白条**，
            //    内容区被挤没 —— 用户看到的就是「直接全屏了，会员什么都看不到」。
            .height(38.dp)
    ) {
        val itemW = maxWidth / tabs.size

        // 指示块位置：spring 走位，`lag` 用来做 squash & stretch
        val pos by animateFloatAsState(
            targetValue = selected.toFloat(),
            animationSpec = spring(dampingRatio = 0.75f, stiffness = 380f),
            label = "segPos"
        )
        val lag = abs(selected - pos).coerceAtMost(1f)
        val sx = 1f + lag * 0.10f
        val sy = 1f - lag * 0.06f

        // 底下的滑动指示块
        Box(
            Modifier
                .offset { androidx.compose.ui.unit.IntOffset((itemW * pos).roundToPx(), 0) }
                .width(itemW)
                .fillMaxHeight()
                .graphicsLayer {
                    scaleX = sx
                    scaleY = sy
                }
                .clip(squircle(10.dp))
                .background(MaterialTheme.colorScheme.surface)
        )

        Row(Modifier.fillMaxWidth().fillMaxHeight()) {
            tabs.forEachIndexed { i, name ->
                val on = selected == i
                Box(
                    Modifier.weight(1f).fillMaxHeight()
                        .clip(squircle(10.dp))
                        .tapable { if (!on) onSelect(i) },
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        name, fontSize = V2.sub, maxLines = 1,
                        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (on) ink else ink.copy(alpha = 0.5f)
                    )
                }
            }
        }
    }
}

/**
 * 分段内容区：切换时**按方向**淡入 + 轻微横移。
 *
 * 方向由 `targetState > initialState` 判断，跟指示块滑动的方向一致 ——
 * 手指往右边切，内容从右边进来，这个一致性比动画本身更重要。
 */
@Composable
internal fun SegmentedContent(
    selected: Int,
    modifier: Modifier = Modifier,
    content: @Composable (Int) -> Unit
) {
    AnimatedContent(
        targetState = selected,
        modifier = modifier,
        transitionSpec = {
            val forward = targetState > initialState
            // 2026-11-29 对齐 iOS AEMotion：统一 220ms 翻页曲线（原 tween 220 数值相同，
            // 这里只是收敛到同一处 token，方向保持左右、位移 w/12 不变）
            (
                fadeIn(tween(180)) +
                    slideInHorizontally(
                        animationSpec = AEMotion.slideSpec(),
                        initialOffsetX = { w -> if (forward) w / 12 else -w / 12 }
                    )
                )
                .togetherWith(fadeOut(tween(120)))
                // 切换时**不要裁切**：内容高度不一样时（会员卡 vs 六行套餐）
                // 默认的 clip 会在过渡中把内容切掉一截，看着像闪了一下
                .using(androidx.compose.animation.SizeTransform(clip = false))
        },
        label = "segContent"
    ) { i -> content(i) }
}
