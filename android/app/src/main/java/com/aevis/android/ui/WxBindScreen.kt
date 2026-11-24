package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import kotlinx.coroutines.launch
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.ModelPrefs
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * 微信绑定（ClawBot 扫码，2026-11-15）。
 *
 * 用户：「客户端加一个这个接口…让用户可以在那里面设置绑定哪个」+
 *       「一个账号只能出一个二维码」+「客户端那里还能设置用哪个模型来扣费」。
 *
 * 链路：`POST /v1/wxbot/claw/qr` 出码 → 微信扫 → 轮询 `/claw/status`
 *      → 成功后回调到 `wx_bot_bind`（带 persona / model）。
 *
 * 「一人一码」是服务端保证的（`wx_qr` 表以 account 为主键，重出直接顶掉旧码），
 * 客户端这边只做**限流**：8 秒内不许重复点，避免自己把码刷掉。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun WxBindScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    var qrBmp by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var status by remember { mutableStateOf("") }       // wait / ok / none
    var err by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var bound by remember { mutableStateOf(false) }
    var lastAt by remember { mutableLongStateOf(0L) }

    var persons by remember { mutableStateOf<List<Api.Persona>>(emptyList()) }
    var persona by remember { mutableStateOf("") }
    var model by remember { mutableStateOf(ModelPrefs.current()) }

    fun refresh() {
        val now = System.currentTimeMillis()
        if (now - lastAt < 8000) {
            err = "刚生成过，等几秒再点（一个账号只保留一个有效码）"
            return
        }
        lastAt = now
        busy = true
        err = ""
        qrBmp = null
    }

    // 出码
    LaunchedEffect(busy) {
        if (!busy) return@LaunchedEffect
        val r = withContext(Dispatchers.IO) { runCatching { Api.wxClawQr() }.getOrNull() }
        if (r == null) {
            err = "出码失败，检查网络"
            busy = false
            return@LaunchedEffect
        }
        val bmp = withContext(Dispatchers.IO) { Api.qrToBitmap(r) }
        qrBmp = bmp
        status = "wait"
        busy = false
    }

    // 轮询
    LaunchedEffect(status) {
        if (status != "wait") return@LaunchedEffect
        repeat(100) {
            delay(2200)
            val st = withContext(Dispatchers.IO) {
                runCatching { Api.wxClawStatus() }.getOrNull()
            } ?: return@repeat
            when (st) {
                "ok" -> {
                    bound = true
                    status = "ok"
                    return@LaunchedEffect
                }
                "expired", "cancel" -> {
                    status = st
                    return@LaunchedEffect
                }
                else -> {}
            }
        }
        status = "expired"
    }

    LaunchedEffect(Unit) {
        // 2026-11-16：跟聊天列表同一个口径 —— 只能绑「我的角色」
        // （本地下载的 + 我创建的），不再用 `Api.contacts()` 带出广场的人
        persons = withContext(Dispatchers.IO) {
            runCatching { com.aevis.android.core.PersonaLib.merged() }.getOrElse { emptyList() }
        }
        if (persons.isNotEmpty()) persona = persons.first().id
        // 已经绑过就显示已绑状态
        val my = withContext(Dispatchers.IO) { runCatching { Api.wxMy() }.getOrNull() }
        if (my != null && my.first.isNotBlank()) {
            bound = true
            status = "ok"
            persona = my.second
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "微信绑定", onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Text(
                tr("用微信扫码，之后在微信里就能直接跟它聊。一个账号只保留一个有效二维码。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.48f), lineHeight = 16.sp,
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
            )
            Spacer(Modifier.height(10.dp))

            // ---- 二维码区 ----
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Column(
                    Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    val bmp = qrBmp
                    when {
                        bound -> {
                            Text(tr("已绑定"), fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold, color = V2.accent)
                            Spacer(Modifier.height(6.dp))
                            Text(tr("在微信里找到它，直接发消息就行"),
                                fontSize = 12.sp, color = ink.copy(alpha = 0.45f))
                        }
                        bmp != null -> {
                            Image(
                                bitmap = bmp.asImageBitmap(),
                                contentDescription = "微信二维码",
                                modifier = Modifier.size(220.dp)
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                when (status) {
                                    "wait" -> tr("用微信扫，扫完这里会自动变")
                                    "expired" -> tr("二维码过期了，重新生成")
                                    else -> tr("等待扫码…")
                                },
                                fontSize = 12.sp, color = ink.copy(alpha = 0.5f)
                            )
                        }
                        busy -> {
                            Box(Modifier.height(220.dp), contentAlignment = Alignment.Center) {
                                Text(tr("正在生成…"), fontSize = 13.sp,
                                    color = ink.copy(alpha = 0.4f))
                            }
                        }
                        else -> {
                            Box(Modifier.height(180.dp), contentAlignment = Alignment.Center) {
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Text(tr("还没生成二维码"), fontSize = 14.sp)
                                    Spacer(Modifier.height(4.dp))
                                    Text(tr("点下面的按钮生成"),
                                        fontSize = 12.sp, color = ink.copy(alpha = 0.42f))
                                }
                            }
                        }
                    }
                }
            }

            if (err.isNotEmpty()) {
                Text(err, fontSize = 12.sp, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp))
            }

            Spacer(Modifier.height(10.dp))

            // ---- 主按钮 ----
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .clip(squircle(14.dp))
                    .background(if (busy) ink.copy(alpha = 0.08f) else V2.accent)
                    .tapable { if (!busy && !bound) refresh() }
                    .padding(vertical = 14.dp),
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    if (busy) tr("生成中…") else if (bound) tr("已绑定") else tr("生成二维码"),
                    fontSize = 15.sp, fontWeight = FontWeight.Medium,
                    color = if (busy || bound) ink.copy(alpha = 0.42f) else Color.White
                )
            }

            Spacer(Modifier.height(18.dp))

            // ---- 绑哪个人设 ----
            Text(tr("微信里用哪个人设回你"), fontSize = V2.sub,
                fontWeight = FontWeight.Medium, color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp))
            if (persons.isEmpty()) {
                Text(tr("还没有人设，先去通讯录加一个"),
                    fontSize = 12.sp, color = ink.copy(alpha = 0.4f),
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 8.dp))
            } else {
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = V2.gutter, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    persons.take(20).forEach { p ->
                        val on = p.id == persona
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .clip(squircle(12.dp))
                                .background(if (on) V2.accent.copy(alpha = 0.10f)
                                else ink.copy(alpha = 0.04f))
                                .tapable {
                                    persona = p.id
                                    if (bound) {
                                        // 已绑定就只改人设，不重新扫码
                                        scope.launch {
                                            withContext(Dispatchers.IO) {
                                                runCatching { Api.wxBind(p.id, model) }
                                            }
                                        }
                                    }
                                }
                                .padding(horizontal = 10.dp, vertical = 8.dp)
                        ) {
                            Avatar(p.avatar, p.name, 38.dp)
                            Spacer(Modifier.height(4.dp))
                            Text(p.name, fontSize = 10.5.sp, maxLines = 1,
                                color = if (on) V2.accent else ink.copy(alpha = 0.6f))
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))

            // ---- 用哪个模型扣费 ----
            Text(tr("微信聊天用哪个模型扣费"), fontSize = V2.sub,
                fontWeight = FontWeight.Medium, color = ink.copy(alpha = 0.5f),
                modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                Row(
                    Modifier.fillMaxWidth().tapable { /* 去模型页选 */ }
                        .padding(horizontal = V2.gutter, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(Api.displayName(model), fontSize = V2.body)
                    Spacer(Modifier.weight(1f))
                    Text(tr("去模型页改"), fontSize = V2.tiny, color = V2.accent)
                }
            }

            Spacer(Modifier.height(10.dp))
            Text(
                tr("提示：微信里发的每条消息都会按这个模型扣墨点，选便宜的更省。"),
                fontSize = 11.sp, color = ink.copy(alpha = 0.36f), lineHeight = 15.sp,
                modifier = Modifier.padding(horizontal = V2.gutter)
            )

            if (bound) {
                Spacer(Modifier.height(V2.sectionGap))
                Text(
                    tr("解除绑定"), fontSize = 13.sp, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter)
                        .tapable {
                            bound = false
                            status = ""
                            qrBmp = null
                        }
                        .padding(vertical = 6.dp)
                )
            }

            Spacer(Modifier.height(34.dp))
        }
    }
}
