package com.aevis.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr

/**
 * 二级页统一顶栏（2026-11-16）。
 *
 * 起因：工程里每个二级页的顶栏都是**各自手写一遍** —— `PersonaDetailScreen`、
 * `AccountScreen`、`ComingSoonScreen`… 有的返回箭头 34dp、有的 44dp，
 * 有的用「‹」字符、有的用 `ic_row_chevron` 旋转 180°，标题字号也不一样。
 * 用户连着几轮说「视觉要统一」，所以先把这套**最常用的结构**抽出来：
 *
 *   返回区（34 圆） + 标题/副标题（可带一行小字） + 右侧自定义区（可选）
 *
 * 这一轮只让**新写的页面**和 `PersonaDetailScreen` 用它，其余页面下一轮统一替换 ——
 * 一次性全改太容易碰坏别处，先让新页面天生就是对的。
 */
@Composable
fun SubPageHeader(
    title: String,
    onBack: () -> Unit,
    subtitle: String? = null,
    trailing: (@Composable () -> Unit)? = null
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 返回区做 34dp：跟 `V2.iconBox` 同宽，跟标题的视觉基线最贴
        Box(
            Modifier.size(34.dp).clip(CircleShape).tapable { onBack() },
            contentAlignment = Alignment.Center
        ) {
            Icon(
                painterResource(R.drawable.ic_row_chevron), null,
                tint = ink.copy(alpha = 0.7f),
                modifier = Modifier.size(18.dp).rotate(180f)
            )
        }
        Spacer(Modifier.width(6.dp))
        // weight(1f) 让标题吃掉中间的空位，右侧 trailing 才会真的贴右
        Column(Modifier.weight(1f)) {
            Text(
                tr(title), fontSize = V2.title, fontWeight = FontWeight.SemiBold,
                maxLines = 1
            )
            if (subtitle != null) {
                Spacer(Modifier.height(1.dp))
                Text(
                    tr(subtitle), fontSize = V2.micro,
                    color = ink.copy(alpha = 0.42f), maxLines = 1
                )
            }
        }
        if (trailing != null) {
            Spacer(Modifier.width(8.dp))
            trailing()
        }
    }
}
