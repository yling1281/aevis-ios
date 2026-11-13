package com.aevis.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import com.aevis.android.data.Api
import com.aevis.android.ui.AevisTheme
import com.aevis.android.ui.LoginScreen
import com.aevis.android.ui.Shell
import android.widget.Toast

class MainActivity : ComponentActivity() {

    /** 充值回跳：`aevis://pay?order=…`（易支付付完把浏览器带回 App）。*/
    private val payReturn = mutableStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Api.init(this)
        handleIntent(intent)

        setContent {
            AevisTheme {
                var signedIn by remember { mutableStateOf(Api.signedIn()) }
                // 收到支付回跳就重建一次「我」页（余额会重新拉）
                val tick by payReturn
                key(tick) {
                    if (signedIn) {
                        Shell(onSignOut = { signedIn = false })
                    } else {
                        LoginScreen(onDone = { signedIn = true })
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme == "aevis" && uri.host == "pay") {
            Toast.makeText(this, "已回到 Aevis，正在核对到账", Toast.LENGTH_SHORT).show()
            payReturn.value += 1
        }
    }
}
