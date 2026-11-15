package com.aevis.android.ui

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * 微信扫码登录（2026-11-14）。
 *
 * 用户：「安卓微信登录还在接入」这条不能一直挂着。
 * 流程：`/v1/auth/wx/qr/create` 出小程序码 → 用户微信扫 → 小程序里授权 →
 * App 轮 `/v1/auth/wx/qr/poll` 拿到 token，直接登录。
 *
 * 码 3 分钟过期。过期不装作「稍后再试」，给一个「换一张」。
 *
 * 2026-11-14 用户：「微信的话它不是可以跳转的吗？iOS 都可以跳转，凭什么这个不可以」
 * → 后端 `/create` 本来就返回 `jump_url`（weixin://dl/business/…），
 *   安卓之前**拿到了却没用**，只让用户自己拿另一台手机扫。现在拿到就直接拉起微信，
 *   跳不动（没装微信 / 系统拦了）才退回扫码，跟 iOS `WXLoginSheet.openInWeChat` 一致。
 */
@Composable
fun WeChatLoginDialog(
    onClose: () -> Unit,
    onLoggedIn: () -> Unit,
) {
    var qr by remember { mutableStateOf<Bitmap?>(null) }
    var err by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(true) }
    var round by remember { mutableIntStateOf(0) }
    var jumpUrl by remember { mutableStateOf("") }
    var jumpErr by remember { mutableStateOf("") }
    val ctx = LocalContext.current

    /** 拉起微信小程序。失败不装作成功 —— 如实说「没跳起来，扫码也行」。*/
    fun openWeChat() {
        if (jumpUrl.isEmpty()) { jumpErr = "还没拿到跳转地址，稍等一下"; return }
        jumpErr = ""
        try {
            ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(jumpUrl)))
        } catch (e: Exception) {
            jumpErr = "没跳起来（可能没装微信），用下面的码扫一下"
        }
    }

    val ink = MaterialTheme.colorScheme.onSurface
    val secondary = ink.copy(alpha = 0.55f)

    LaunchedEffect(round) {
        err = ""
        qr = null
        loading = true
        val r = withContext(Dispatchers.IO) { Api.wxQrCreate() }
        if (r.err.isNotEmpty()) {
            err = r.err
            loading = false
            return@LaunchedEffect
        }
        jumpUrl = r.jumpUrl
        jumpErr = ""
        // 跟 iOS 一样：拿到跳转地址就自动拉起微信，用户不用先看码再扫
        if (jumpUrl.isNotEmpty()) openWeChat()
        qr = withContext(Dispatchers.IO) { Api.loadQrBitmap(r.imageUrl) }
        if (qr == null) {
            err = "二维码没加载出来，换一张试试"
            loading = false
            return@LaunchedEffect
        }
        loading = false

        // 90 × 2s = 3 分钟（和后端 expires_in=180 对齐）
        repeat(90) {
            delay(2000)
            val p = withContext(Dispatchers.IO) { Api.wxQrPoll(r.ticket) }
            when (p.status) {
                "ok" -> {
                    Api.save(p.token, p.email, p.uid)
                    onLoggedIn()
                    return@LaunchedEffect
                }
                "expired" -> {
                    err = "二维码已过期"
                    return@LaunchedEffect
                }
                "err" -> {
                    err = p.msg.ifEmpty { "登录失败，换一张试试" }
                    return@LaunchedEffect
                }
            }
        }
        err = "二维码已过期"
    }

    Dialog(onDismissRequest = onClose) {
        Column(
            Modifier
                .clip(RoundedCornerShape(24.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(horizontal = 24.dp, vertical = 22.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(tr("微信登录"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                color = ink)
            Spacer(Modifier.height(6.dp))
            Text(
                if (jumpUrl.isNotEmpty()) "已尝试打开微信，没反应就点下面的按钮"
                else "正在准备微信授权…",
                fontSize = 12.5.sp, color = secondary, textAlign = TextAlign.Center
            )

            Spacer(Modifier.height(18.dp))

            Box(
                Modifier
                    .size(220.dp)
                    .clip(RoundedCornerShape(18.dp))
                    .background(ink.copy(alpha = 0.04f))
                    .border(0.8.dp, ink.copy(alpha = 0.08f), RoundedCornerShape(18.dp)),
                contentAlignment = Alignment.Center
            ) {
                val bmp = qr
                when {
                    loading -> Text(tr("正在生成二维码…"), fontSize = 13.sp, color = secondary)
                    bmp != null -> Image(
                        bitmap = bmp.asImageBitmap(),
                        contentDescription = "微信小程序码",
                        modifier = Modifier.size(200.dp)
                    )
                    err.isNotEmpty() -> Text(err, fontSize = 13.sp, color = V2.alert,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 18.dp))
                }
            }

            if (err.isNotEmpty() && qr == null) {
                Spacer(Modifier.height(10.dp))
                Text(err, fontSize = 12.5.sp, color = V2.alert, textAlign = TextAlign.Center)
            } else if (err.isEmpty()) {
                Spacer(Modifier.height(10.dp))
                Text(tr("也可以让另一台手机用微信扫这张码"),
                    fontSize = 12.sp, color = secondary.copy(alpha = 0.8f),
                    textAlign = TextAlign.Center)
            }

            if (jumpErr.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text(jumpErr, fontSize = 12.sp, color = V2.alert, textAlign = TextAlign.Center)
            }

            if (jumpUrl.isNotEmpty() && qr != null) {
                Spacer(Modifier.height(12.dp))
                androidx.compose.foundation.layout.Row(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(V2.accent.copy(alpha = 0.12f))
                        .clickable { openWeChat() }
                        .padding(vertical = 12.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(tr("打开微信授权"), fontSize = 15.sp,
                        fontWeight = FontWeight.Medium, color = V2.accent)
                }
            }

            Spacer(Modifier.height(8.dp))

            androidx.compose.foundation.layout.Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End
            ) {
                TextButton(onClick = { round++ }) {
                    Text(tr("换一张"), fontSize = 14.sp, color = V2.accent)
                }
                TextButton(onClick = onClose) {
                    Text(tr("取消"), fontSize = 14.sp, color = secondary)
                }
            }
        }
    }
}
