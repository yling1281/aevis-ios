package com.aevis.android.ui

import androidx.compose.foundation.background
import com.aevis.android.core.I18n.tr
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog

/**
 * 网页授权登录的确认框（2026-11-13）。
 *
 * 浏览器那边点「用 Aevis App 授权」→ 唤起 `aevis://weblogin?t=…` →
 * 这里问一句「在 Chrome · Windows 上登录？」。用户点允许之后，
 * **浏览器自己会轮询拿到登录态**，我们不需要再跳回去。
 *
 * 显示四位验证码是刻意的：用户能拿它和电脑屏幕上的码对一眼，
 * 就不会被随便一条链接骗着点「允许」。
 */
data class WebLoginRequest(
    val ticket: String,
    val code: String,
    val device: String,
)

@Composable
fun WebLoginDialog(
    req: WebLoginRequest,
    busy: Boolean,
    onAllow: () -> Unit,
    onDeny: () -> Unit,
) {
    Dialog(onDismissRequest = { if (!busy) onDeny() }) {
        Column(
            modifier = Modifier
                .width(320.dp)
                .background(V2.cardLight, RoundedCornerShape(26.dp))
                .padding(horizontal = 22.dp, vertical = 26.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "在${req.device}上登录？",
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xFF1D1B17),
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(9.dp))
            Text(
                "确认后，那台设备就能用你的 Aevis 账号直接充值。",
                fontSize = 13.sp,
                color = Color(0xFF8A8378),
                textAlign = TextAlign.Center,
                lineHeight = 20.sp,
            )

            if (req.code.isNotEmpty()) {
                Spacer(Modifier.height(18.dp))
                Box(
                    modifier = Modifier
                        .background(Color(0xFFF4F0FF), RoundedCornerShape(12.dp))
                        .padding(horizontal = 16.dp, vertical = 9.dp)
                ) {
                    Text(
                        req.code,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color(0xFF7664E2),
                        letterSpacing = 5.sp,
                    )
                }
                Spacer(Modifier.height(10.dp))
                Text(
                    "网页上显示的验证码应该也是这四位",
                    fontSize = 11.5.sp,
                    color = Color(0xFFA9A29A),
                    textAlign = TextAlign.Center,
                )
            }

            Spacer(Modifier.height(24.dp))

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp)
                    .background(
                        Brush.linearGradient(listOf(Color(0xFFA897F5), Color(0xFF7664E2))),
                        RoundedCornerShape(16.dp)
                    )
                    .tapable(enabled = !busy, onClick = onAllow),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (busy) "正在授权…" else "允许登录",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White,
                )
            }

            Spacer(Modifier.height(6.dp))

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(44.dp)
                    .tapable(enabled = !busy, onClick = onDeny),
                contentAlignment = Alignment.Center,
            ) {
                Text(tr("不允许"), fontSize = 15.sp, color = Color(0xFF8A8378))
            }
        }
    }
}
