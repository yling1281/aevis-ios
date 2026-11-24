package com.aevis.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.aevis.android.core.ChatPrefs
import com.aevis.android.core.I18n.tr
import kotlinx.coroutines.delay

/** 一条待展示的横幅（2026-11-16，133）。*/
data class BannerItem(val pid: String, val name: String, val avatar: String, val text: String)

/**
 * 应用内「新消息」横幅（2026-11-16，133）。
 *
 * 用户改口了：主动消息到达时要弹，但**只弹应用内横幅**（不是系统通知、不是 Toast）。
 * 规矩：
 *   · 一次只显示一条，最多排队 3 条（多的只更新角标）；
 *   · 停留 4 秒自动消失；点它进对应会话；上滑可以手动划走；
 *   · 主题跟 131 的口径（浅色白玻璃 / 深色黑玻璃），`statusBarsPadding` 不挡状态栏；
 *   · **不抢焦点**：只是一个浮层，不加 focusable。
 */
@Composable
fun MessageBannerHost(
    queue: MutableList<BannerItem>,
    onOpen: (String) -> Unit
) {
    if (queue.isEmpty()) return
    val item = queue.first()
    val dark = isDarkTheme()
    val ink = MaterialTheme.colorScheme.onSurface
    var shown by remember(item.pid, item.text) { mutableStateOf(false) }
    var drag by remember(item.pid, item.text) { mutableFloatStateOf(0f) }

    LaunchedEffect(item.pid, item.text) {
        shown = true
        delay(4000)
        shown = false
        delay(240)
        if (queue.isNotEmpty()) queue.removeAt(0)
    }

    Box(
        Modifier.fillMaxSize().zIndex(10f),
        contentAlignment = Alignment.TopCenter
    ) {
        AnimatedVisibility(
            visible = shown,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut()
        ) {
            Row(
                Modifier
                    .padding(horizontal = 12.dp)
                    .statusBarsPadding()
                    .offset(y = drag.dp)
                    .pointerInput(item.pid, item.text) {
                        detectVerticalDragGestures(
                            onDragEnd = {
                                if (drag < -28f) {
                                    shown = false
                                    drag = 0f
                                } else drag = 0f
                            }
                        ) { _, dy -> if (dy < 0) drag += dy / 3f }
                    }
                    .fillMaxWidth()
                    .clip(squircle(16.dp))
                    .background(
                        if (dark) Color.Black.copy(alpha = 0.62f)
                        else Color.White.copy(alpha = 0.86f)
                    )
                    .border(
                        1.dp,
                        if (dark) Color.White.copy(alpha = 0.14f)
                        else Color.Black.copy(alpha = 0.06f),
                        squircle(16.dp)
                    )
                    .tapable {
                        // 点一下：进会话 + 从队列摘掉 + 清角标
                        ChatPrefs.clearProactiveUnread(item.pid)
                        if (queue.isNotEmpty()) queue.removeAt(0)
                        onOpen(item.pid)
                    }
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Avatar(item.avatar, item.name, 34.dp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        item.name, fontSize = 13.sp, fontWeight = FontWeight.Medium,
                        color = ink, maxLines = 1
                    )
                    Text(
                        item.text.take(40), fontSize = 12.sp,
                        color = ink.copy(alpha = 0.62f), maxLines = 1
                    )
                }
                Spacer(Modifier.width(8.dp))
                Text(
                    java.text.SimpleDateFormat("HH:mm", java.util.Locale.US)
                        .format(java.util.Date()),
                    fontSize = 10.5.sp, color = ink.copy(alpha = 0.4f)
                )
            }
        }
    }
}
