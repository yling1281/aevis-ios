package com.aevis.android

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import com.aevis.android.data.Api
import com.aevis.android.ui.AevisTheme
import com.aevis.android.ui.LoginScreen
import com.aevis.android.ui.Shell

class MainActivity : ComponentActivity() {

    /** 充值回跳：`aevis://pay?order=…`（易支付付完把浏览器带回 App）。*/
    private val payReturn = mutableStateOf(0)

    /** 登录态。放在 Activity 上而不是 inside setContent —— 深链回调要能改它。 */
    private val signedInState = mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Api.init(this)
        signedInState.value = Api.signedIn()
        handleIntent(intent)

        setContent {
            AevisTheme {
                val signedIn by signedInState
                // 收到支付回跳就重建一次「我」页（余额会重新拉）
                val tick by payReturn
                key(tick) {
                    if (signedIn) {
                        Shell(onSignOut = {
                            Api.signOut()
                            signedInState.value = false
                        })
                    } else {
                        LoginScreen(onDone = { signedInState.value = true })
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "aevis") return
        when (uri.host) {
            // 充值回来：核对到账靠「我」页重新拉余额
            "pay" -> {
                Toast.makeText(this, "已回到 Aevis，正在核对到账", Toast.LENGTH_SHORT).show()
                payReturn.value += 1
            }
            // QQ 授权完：服务端把 token 直接 302 过来
            "login" -> {
                val token = uri.getQueryParameter("token").orEmpty()
                if (token.isEmpty()) {
                    // 服务端会把 QQ 那边的原话放在 msg 里（比如「redirect_uri 不对」，
                    // 或者 QQ 互联 应用没上线），照原样弹出来，别只说「失败」。
                    val why = uri.getQueryParameter("msg").orEmpty()
                    Toast.makeText(
                        this,
                        if (why.isEmpty()) "登录失败：没拿到凭证" else why,
                        Toast.LENGTH_LONG
                    ).show()
                    return
                }
                Api.save(token, uri.getQueryParameter("email").orEmpty(),
                    uri.getQueryParameter("uid").orEmpty())
                signedInState.value = true
                Toast.makeText(this, "登录成功", Toast.LENGTH_SHORT).show()
            }
        }
    }
}
