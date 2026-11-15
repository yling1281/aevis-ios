package com.aevis.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import com.aevis.android.core.I18n
import com.aevis.android.data.Api
import com.aevis.android.ui.AevisTheme
import com.aevis.android.ui.LoginScreen
import com.aevis.android.ui.Shell
import com.aevis.android.ui.WebLoginDialog
import com.aevis.android.ui.WebLoginRequest

class MainActivity : ComponentActivity() {

    /** 充值回跳：`aevis://pay?order=…`（易支付付完把浏览器带回 App）。*/
    private val payReturn = mutableStateOf(0)

    /** 登录态。放在 Activity 上而不是 inside setContent —— 深链回调要能改它。 */
    private val signedInState = mutableStateOf(false)

    /** 网页要求授权登录时的确认框（2026-11-13）。null = 不显示。 */
    private val webLoginReq = mutableStateOf<WebLoginRequest?>(null)
    private val webLoginBusy = mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 多语言：读 assets 里的共用词表，跟随系统语言
        I18n.init(this)
        enableEdgeToEdge()
        Api.init(this)
        signedInState.value = Api.signedIn()
        handleIntent(intent)

        setContent {
            AevisTheme {
                val signedIn by signedInState
                // 收到支付回跳就重建一次「我」页（余额会重新拉）
                val tick by payReturn
                // 语言一变就整棵树重建 —— 文案是在各个 Composable 里现取的，
                // 不重建的话只有正在重组的那个子节点会变，其它地方还是旧语言。
                val langVer = I18n.version
                key(tick, langVer) {
                    if (signedIn) {
                        Shell(onSignOut = {
                            Api.signOut()
                            signedInState.value = false
                        })
                    } else {
                        LoginScreen(onDone = { signedInState.value = true })
                    }
                }

                // 网页授权确认框：不放在 `key(tick)` 里面 ——
                // 支付回跳重建 Shell 时它不该跟着消失。
                val req by webLoginReq
                val busy by webLoginBusy
                req?.let { r ->
                    WebLoginDialog(
                        req = r,
                        busy = busy,
                        onAllow = { approveWebLogin(r) },
                        onDeny = { denyWebLogin(r) },
                    )
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
            // 网页要授权登录（2026-11-13）：`aevis://weblogin?t=…`
            // 浏览器那边已经开着票在轮询，这里只负责问用户同不同意。
            "weblogin" -> {
                val ticket = uri.getQueryParameter("t").orEmpty()
                if (ticket.isEmpty()) return
                handleScanTicket(ticket)
            }
        }
    }

    /// 拿到票号 → 查一眼 → 弹确认框。两条入口共用：
    ///   · 浏览器/系统相机扫到 `aevis://weblogin?t=…`（深链）
    ///   · App 里「我 → 扫一扫」原生扫码（2026-11-13）
    fun handleScanTicket(ticket: String) {
        if (ticket.isEmpty()) return
        if (!Api.signedIn()) {
            Toast.makeText(this, "先在 Aevis 里登录账号，再扫这张码", Toast.LENGTH_LONG).show()
            return
        }
        Thread {
            val (_, obj) = Api.webLoginPeek(ticket)
            val data = obj.optJSONObject("data")
            runOnUiThread {
                if (data == null || !data.optBoolean("ok", false)) {
                    Toast.makeText(this, obj.optString("msg", "这个登录码用不了"),
                        Toast.LENGTH_LONG).show()
                } else {
                    webLoginReq.value = WebLoginRequest(
                        ticket = ticket,
                        code = data.optString("code"),
                        device = data.optString("device"),
                    )
                }
            }
        }.start()
    }

    /// 点「允许」：让服务端把这票标成 confirmed，然后开一下 `wlogin?ok=1`
    /// 给用户看一句「已授权」。**不要**在这里跳回充值页 ——
    /// 那会新开一个浏览器标签，原来那页还在原地等。
    private fun approveWebLogin(req: WebLoginRequest) {
        if (webLoginBusy.value) return
        webLoginBusy.value = true
        Thread {
            val (_, obj) = Api.webLoginConfirm(req.ticket)
            val ok = obj.optInt("code", -1) == 200
            val redirect = obj.optJSONObject("data")?.optString("redirect").orEmpty()
            runOnUiThread {
                webLoginBusy.value = false
                webLoginReq.value = null
                if (ok) {
                    Toast.makeText(this, "已授权，回到浏览器就能直接充值了",
                        Toast.LENGTH_LONG).show()
                    if (redirect.isNotEmpty()) {
                        runCatching {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(redirect)))
                        }
                    }
                } else {
                    Toast.makeText(this, obj.optString("msg", "授权没成功"),
                        Toast.LENGTH_LONG).show()
                }
            }
        }.start()
    }

    private fun denyWebLogin(req: WebLoginRequest) {
        webLoginReq.value = null
        Thread { Api.webLoginCancel(req.ticket) }.start()
    }
}
