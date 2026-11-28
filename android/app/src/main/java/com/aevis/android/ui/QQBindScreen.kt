package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * QQ 接入（2026-11-28 第三次口径：机器人是用户在 QQ 开放平台自己注册的，我们只提供通道）。
 *
 * 用户原话：「是要绑定用户自己的机器人啊…QQ 扫完码会提示这是一个什么 QQ 机器人，
 * 需要你自己去绑定，绑定你的哪个机器人」——
 *
 *   1. 二维码内容是 QQ 开放平台的机器人入口（q.qq.com），我们不代注册；
 *   2. 用户扫码后在 QQ 里登录开放平台，创建/选择属于他自己的机器人；
 *   3. 页面直接给出这个机器人的 AppID / AppSecret，用户复制回来填；
 *   4. 服务端校验后按这份凭据单开一条 Bot 连接 —— 机器人是他的，人设挂他的账号。
 *
 * 一个账号仍然只能绑一个机器人；绑完可以解绑换。
 */
private const val STAGE_SCAN = 0
private const val STAGE_CRED = 1
private const val STAGE_DONE = 2

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun QQBindScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface

    var ready by remember { mutableStateOf(false) }
    var enabled by remember { mutableStateOf(true) }
    var bound by remember { mutableStateOf(false) }
    var appid by remember { mutableStateOf("") }
    var botName by remember { mutableStateOf("") }
    var linkState by remember { mutableStateOf("") }

    var officialUrl by remember { mutableStateOf("") }
    var qr by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var stage by remember { mutableIntStateOf(STAGE_SCAN) }

    var appidIn by remember { mutableStateOf("") }
    var secretIn by remember { mutableStateOf("") }
    var showSecret by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var err by remember { mutableStateOf("") }

    var persona by remember { mutableStateOf("") }
    var persons by remember { mutableStateOf<List<Api.Persona>>(emptyList()) }
    val scope = rememberCoroutineScope()

    suspend fun applyStatus() {
        val st = withContext(Dispatchers.IO) { runCatching { Api.qqStatus() }.getOrNull() }
        if (st == null) {
            if (Api.lastQqError.isNotBlank()) err = Api.lastQqError
            return
        }
        enabled = st.enabled
        bound = st.boundMine || (st.appid.isNotBlank() && st.bound)
        appid = st.appid
        botName = st.botName
        linkState = st.state
        if (st.officialUrl.isNotBlank()) officialUrl = st.officialUrl
        if (st.persona.isNotBlank()) persona = st.persona
        if (bound && stage == STAGE_SCAN) stage = STAGE_DONE
    }

    suspend fun loadEntry() {
        if (officialUrl.isNotBlank() && qr != null) return
        val r = withContext(Dispatchers.IO) { runCatching { Api.qqBindStart(persona) }.getOrNull() }
        if (r == null) {
            err = Api.lastQqError.ifBlank { "拿不到官方入口，检查网络" }
            return
        }
        officialUrl = r.url
        qr = withContext(Dispatchers.IO) { Api.qrToBitmap(r.url) }
    }

    LaunchedEffect(Unit) {
        applyStatus()
        persons = withContext(Dispatchers.IO) {
            runCatching { com.aevis.android.core.PersonaLib.merged() }.getOrElse { emptyList() }
        }
        if (persona.isBlank() && persons.isNotEmpty()) persona = persons.first().id
        ready = true
        if (enabled && !bound) loadEntry()
    }

    // 绑完等服务端把连接建起来：pending → online / error
    LaunchedEffect(bound) {
        if (!bound) return@LaunchedEffect
        repeat(20) {
            delay(3000)
            applyStatus()
            if (linkState == "online" || linkState == "error") return@LaunchedEffect
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = "QQ 接入", onBack = onBack)

        if (!ready) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(tr("读取中…"), fontSize = 13.sp, color = ink.copy(alpha = 0.4f))
            }
            return@Column
        }

        if (!enabled) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(tr("QQ 接入暂未开放"), fontSize = 15.sp)
                    Spacer(Modifier.height(6.dp))
                    Text(tr("后台打开开关后这里就能用"),
                        fontSize = 12.sp, color = ink.copy(alpha = 0.42f))
                }
            }
            return@Column
        }

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            StepBar(step = if (bound) STAGE_DONE else stage)
            Spacer(Modifier.height(10.dp))

            if (bound) {
                BoundCard(appid = appid, botName = botName, linkState = linkState, err = err)
            } else if (stage == STAGE_SCAN) {
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(tr("用手机 QQ 扫这个码"), fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold, color = ink)
                        Spacer(Modifier.height(4.dp))
                        Text(tr("在 QQ 里创建或选择你自己的机器人（注册在 QQ 那边，不是我们替你建）"),
                            fontSize = 11.5.sp, color = ink.copy(alpha = 0.5f),
                            textAlign = TextAlign.Center, lineHeight = 16.sp)
                        Spacer(Modifier.height(12.dp))
                        val bmp = qr
                        if (bmp != null) {
                            Image(bitmap = bmp.asImageBitmap(), contentDescription = "QQ 开放平台入口",
                                modifier = Modifier.size(200.dp))
                        } else {
                            Box(Modifier.size(200.dp), contentAlignment = Alignment.Center) {
                                Text(tr("二维码生成中…"), fontSize = 12.sp,
                                    color = ink.copy(alpha = 0.4f))
                            }
                        }
                        Spacer(Modifier.height(12.dp))
                        Column(Modifier.fillMaxWidth()) {
                            listOf(
                                "1. 手机 QQ 扫码，进 QQ 开放平台的机器人页",
                                "2. 点「创建机器人」，或用你已经有的那个",
                                "3. 复制页面上这个机器人的 AppID 和 AppSecret",
                                "4. 回来点下面「我复制好了」，填进来就绑上了"
                            ).forEach {
                                Text(it, fontSize = 11.5.sp, lineHeight = 18.sp,
                                    color = ink.copy(alpha = 0.55f),
                                    modifier = Modifier.padding(vertical = 1.dp))
                            }
                        }
                    }
                }
            } else {
                V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Column(Modifier.fillMaxWidth()) {
                        Text(tr("填你自己机器人的凭据"), fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold, color = ink)
                        Spacer(Modifier.height(3.dp))
                        Text(tr("在 QQ 开放平台刚创建的那个机器人，「开发设置」里能看到"),
                            fontSize = 11.5.sp, color = ink.copy(alpha = 0.5f), lineHeight = 16.sp)
                        Spacer(Modifier.height(12.dp))

                        LabeledField(
                            label = "AppID", value = appidIn,
                            onValueChange = { appidIn = it.filter { c -> c.isDigit() }.take(14) },
                            placeholder = "纯数字，例如 1905697056",
                            keyboardType = KeyboardType.Number
                        )
                        Spacer(Modifier.height(10.dp))
                        LabeledField(
                            label = "AppSecret", value = secretIn,
                            onValueChange = { secretIn = it.trim().take(64) },
                            placeholder = "32 位字符串，只用来连你的机器人",
                            password = !showSecret,
                            trailing = {
                                Text(
                                    if (showSecret) tr("隐藏") else tr("显示"),
                                    fontSize = 11.5.sp, color = V2.accent,
                                    modifier = Modifier.tapable { showSecret = !showSecret }
                                )
                            }
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(tr("密钥只存服务端、只写不读，后台和 App 都不会回显"),
                            fontSize = 10.5.sp, color = ink.copy(alpha = 0.38f), lineHeight = 15.sp)
                    }
                }
            }

            if (err.isNotEmpty()) {
                Text(err, fontSize = 12.sp, color = V2.alert, lineHeight = 17.sp,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp))
            }

            Spacer(Modifier.height(12.dp))

            if (!bound) {
                val canGo = if (stage == STAGE_SCAN) true
                else appidIn.length >= 5 && secretIn.length >= 16
                val label = when {
                    busy -> tr("请稍候…")
                    stage == STAGE_SCAN -> tr("我复制好了，去填")
                    else -> tr("绑定这个机器人")
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                        .clip(squircle(14.dp))
                        .background(if (busy || !canGo) ink.copy(alpha = 0.08f) else V2.accent)
                        .tapable {
                            if (busy || !canGo) return@tapable
                            if (stage == STAGE_SCAN) {
                                err = ""
                                stage = STAGE_CRED
                                if (officialUrl.isBlank()) {
                                    // 没拿到入口也不挡着填凭据
                                }
                            } else {
                                scope.launch {
                                    busy = true
                                    err = ""
                                    val ok = withContext(Dispatchers.IO) {
                                        runCatching {
                                            Api.qqBindCred(appidIn, secretIn, persona)
                                        }.getOrDefault(false)
                                    }
                                    busy = false
                                    if (ok) {
                                        secretIn = ""
                                        stage = STAGE_DONE
                                        bound = true
                                        applyStatus()
                                    } else {
                                        err = Api.lastQqError.ifBlank { "绑定失败，检查 AppID/Secret" }
                                    }
                                }
                            }
                        }
                        .padding(vertical = 14.dp),
                    horizontalArrangement = Arrangement.Center
                ) {
                    Text(label, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                        color = if (busy || !canGo) ink.copy(alpha = 0.42f) else Color.White)
                }
            } else {
                Text(
                    tr("解除绑定"), fontSize = 13.sp, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter)
                        .tapable {
                            scope.launch {
                                busy = true
                                withContext(Dispatchers.IO) { runCatching { Api.qqUnbind() } }
                                busy = false
                                bound = false
                                appid = ""
                                botName = ""
                                linkState = ""
                                appidIn = ""
                                secretIn = ""
                                stage = STAGE_SCAN
                            }
                        }
                        .padding(vertical = 8.dp)
                )
            }

            Spacer(Modifier.height(6.dp))
            Text(
                tr("一个账号只能绑一个机器人 · 换绑先解绑"),
                fontSize = 11.sp, color = ink.copy(alpha = 0.36f),
                modifier = Modifier.padding(horizontal = V2.gutter)
            )

            Spacer(Modifier.height(18.dp))

            if (!bound) {
                Text(tr("QQ 里用哪个人设回你"), fontSize = V2.sub,
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
                                    .tapable { persona = p.id }
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
            }

            Spacer(Modifier.height(34.dp))
        }
    }
}

/** 已绑定卡片：机器人名 + AppID 尾号 + 连接状态。 */
@Composable
private fun BoundCard(appid: String, botName: String, linkState: String, err: String) {
    val ink = MaterialTheme.colorScheme.onSurface
    V2Card(Modifier.padding(horizontal = V2.gutter)) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                Modifier.size(58.dp).clip(squircle(29.dp))
                    .background(Color(0xFF34C759)),
                contentAlignment = Alignment.Center
            ) {
                Text("✓", fontSize = 30.sp, color = Color.White, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(10.dp))
            Text(tr("已绑定你的机器人"), fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold, color = V2.accent)
            Spacer(Modifier.height(4.dp))
            if (botName.isNotBlank()) {
                Text(botName, fontSize = 12.5.sp, color = ink.copy(alpha = 0.6f))
                Spacer(Modifier.height(2.dp))
            }
            if (appid.isNotBlank()) {
                Text("AppID " + appid, fontSize = 11.5.sp, color = ink.copy(alpha = 0.42f))
            }
            Spacer(Modifier.height(8.dp))
            val (txt, col) = when (linkState) {
                "online" -> tr("连接正常，可以在 QQ 里直接聊") to Color(0xFF34C759)
                "error" -> tr("连接异常，检查密钥或开放平台 IP 白名单") to V2.alert
                "pending", "" -> tr("正在连接…") to ink.copy(alpha = 0.5f)
                else -> linkState to ink.copy(alpha = 0.5f)
            }
            Text(txt, fontSize = 11.5.sp, color = col, textAlign = TextAlign.Center, lineHeight = 16.sp)
            if (err.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(err, fontSize = 10.5.sp, color = ink.copy(alpha = 0.42f),
                    textAlign = TextAlign.Center, lineHeight = 15.sp)
            }
        }
    }
}

/** 带标签的输入框（跟页面其它地方一样用 BasicTextField，不引 Material 大组件）。 */
@Composable
private fun LabeledField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    password: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    trailing: (@Composable () -> Unit)? = null
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(Modifier.fillMaxWidth()) {
        Text(label, fontSize = 11.5.sp, color = ink.copy(alpha = 0.5f),
            modifier = Modifier.padding(bottom = 5.dp))
        Row(
            Modifier.fillMaxWidth().clip(squircle(12.dp))
                .background(ink.copy(alpha = 0.05f))
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(Modifier.weight(1f)) {
                if (value.isEmpty()) {
                    Text(placeholder, fontSize = 13.sp, color = ink.copy(alpha = 0.3f))
                }
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    singleLine = true,
                    textStyle = TextStyle(fontSize = 13.sp, color = ink),
                    keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
                    visualTransformation = if (password) PasswordVisualTransformation()
                    else VisualTransformation.None,
                    modifier = Modifier.fillMaxWidth()
                )
            }
            if (trailing != null) {
                Spacer(Modifier.width(8.dp))
                trailing()
            }
        }
    }
}

/** 三步进度条：扫码 → 填密钥 → 完成。 */
@Composable
private fun StepBar(step: Int) {
    val ink = MaterialTheme.colorScheme.onSurface
    val labels = listOf("扫码", "填密钥", "完成")
    Row(
        Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        labels.forEachIndexed { i, t ->
            val done = step > i
            val cur = step == i
            Box(
                Modifier.size(18.dp).clip(squircle(9.dp))
                    .background(
                        when {
                            done -> V2.accent
                            cur -> V2.accent.copy(alpha = 0.18f)
                            else -> ink.copy(alpha = 0.07f)
                        }
                    ),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    if (done) "✓" else "${i + 1}",
                    fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
                    color = if (done) Color.White else if (cur) V2.accent else ink.copy(alpha = 0.4f)
                )
            }
            Spacer(Modifier.width(5.dp))
            Text(t, fontSize = 11.sp,
                color = if (cur) V2.accent else ink.copy(alpha = if (done) 0.6f else 0.35f))
            if (i < labels.size - 1) {
                Spacer(Modifier.width(8.dp))
                Box(Modifier.weight(1f).height(1.dp).background(ink.copy(alpha = 0.10f)))
                Spacer(Modifier.width(8.dp))
            }
        }
    }
}
