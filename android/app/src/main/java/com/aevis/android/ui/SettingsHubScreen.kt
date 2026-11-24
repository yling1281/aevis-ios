package com.aevis.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr

/**
 * 设置中心（2026-11-17）。
 *
 * 对标用户给的参考图：三组卡片
 *   偏好设置：通知管理 / 通用配置
 *   数据管理：权限控制 / 存储设置 / 个人信息
 *   软件设置：服务器状态 / 关于
 *
 * 刻意**只放能真正点进去的入口** —— 用户明确讨厌"点了没反应"的假项。
 * 还没做的页面（权限控制）置灰不可点，但保留位置让人知道"以后会有"。
 */
@Composable
fun SettingsHubScreen(
    onBack: () -> Unit,
    onOpenNotify: () -> Unit,
    onOpenGeneral: () -> Unit,
    onOpenStorage: () -> Unit,
    onOpenAccount: () -> Unit,
    onOpenServers: () -> Unit,
    onOpenAbout: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            // 116：补状态栏 inset（漏了会被刘海压住）
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp)
    ) {
        SubPageHeader(title = tr("设置"), onBack = onBack)

        HubGroup(tr("偏好设置"))
        V2Card {
            HubRow(R.drawable.ic_set_bell, tr("通知管理"), tr("使用通知 · 后台常驻"), onOpenNotify)
            HubSep()
            HubRow(R.drawable.ic_set_sliders, tr("通用配置"), tr("背景 · 聊天 · 动画"), onOpenGeneral)
        }

        HubGroup(tr("数据管理"))
        V2Card {
            HubRow(R.drawable.ic_set_shield, tr("权限控制"), tr("通知、相机、麦克风"), null)
            HubSep()
            HubRow(R.drawable.ic_set_layers, tr("存储设置"), tr("导出 / 导入聊天记录"), onOpenStorage)
            HubSep()
            HubRow(R.drawable.ic_set_person, tr("个人信息"), tr("昵称 · 头像 · Aevis 号"), onOpenAccount)
        }

        HubGroup(tr("软件设置"))
        V2Card {
            HubRow(R.drawable.ic_set_monitor, tr("服务器状态"), tr("线路与响应"), onOpenServers)
            HubSep()
            HubRow(R.drawable.ic_set_info, tr("关于"), tr("版本与协议"), onOpenAbout)
        }

        Spacer(Modifier.height(28.dp))
    }
}

/** 组标题：11sp、半透明、字距略开 —— 和参考图一致，不抢内容。 */
@Composable
internal fun HubGroup(text: String) {
    Text(
        text,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
        fontSize = 11.sp,
        letterSpacing = 0.5.sp,
        modifier = Modifier.padding(start = 4.dp, top = 16.dp, bottom = 8.dp)
    )
}

/**
 * 一行设置：左矢量图标 + 标题/副标题 + 右侧 chevron。
 * `onClick == null` 时整行置灰且不可点（表示"还没做"，但仍给用户一个交代）。
 */
@Composable
internal fun HubRow(
    iconRes: Int,
    title: String,
    sub: String,
    onClick: (() -> Unit)?,
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val enabled = onClick != null
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (enabled) Modifier.clickable { onClick?.invoke() } else Modifier)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            painter = painterResource(iconRes),
            contentDescription = null,
            tint = if (enabled) ink else ink.copy(alpha = 0.3f),
            modifier = Modifier.size(20.dp)
        )
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                color = if (enabled) ink else ink.copy(alpha = 0.4f),
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium
            )
            if (sub.isNotEmpty()) {
                Text(
                    sub,
                    color = ink.copy(alpha = if (enabled) 0.5f else 0.25f),
                    fontSize = 11.5.sp,
                    modifier = Modifier.padding(top = 2.dp)
                )
            }
        }
        if (enabled) {
            Icon(
                painter = painterResource(R.drawable.ic_chevron_right),
                contentDescription = null,
                tint = ink.copy(alpha = 0.3f),
                modifier = Modifier.size(16.dp)
            )
        }
    }
}

/** 行间分隔：从图标后面开始，和 iOS 那种"缩进分隔线"一致。 */
@Composable
internal fun HubSep() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(start = 50.dp)
            .height(1.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f))
    )
}
