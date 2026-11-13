package com.aevis.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.data.Api
import com.aevis.android.data.AuthResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 登录门 —— **逐条照 iOS `Features/Login/LoginView.swift` 的抖音版式**。
 *
 * 用户 2026-11-13：「登录界面也没一样，苹果可以，但是安卓你没做」。
 * 之前这页是「Aevis 大标题 + 一张卡片两个输入框」，跟 iOS 完全是两个 App。
 *
 * iOS 那一版的结构（数值全部照抄，单位 pt → dp）：
 * ```
 *                                          帮助            ← 15pt 次要色，右对齐
 * 登录发现更多精彩                                          ← 25pt semibold
 * 验证码只发给已注册的邮箱；还没有账号就点「去注册」            ← 12.5pt 次要色
 * ┌────────────────────────────┐
 * │ ✉  请输入邮箱               │                        ← 16 圆角，5.5% 底
 * └────────────────────────────┘
 * ⇄ 密码登录      没有账号，去注册                          ← 13.5pt
 * [        验证并登录        ]                            ← 整宽胶囊，16.5pt，禁用 35% 透明
 * ○ 已阅读并同意 用户协议 和 隐私政策                       ← 11.5pt
 *                              (间距 96)
 *   ⭕微信    ⭕QQ    ⭕扫码    (找回账号)                   ← 52 圆底 + 11pt 字
 * ```
 *
 * 三条不能破的（跟 iOS 一致）：强制登录没有跳过；协议必须自己勾；没勾点登录只提示。
 */
private enum class Mode { Code, Password, Register }

@Composable
fun LoginScreen(onDone: () -> Unit) {
    val ctx = LocalContext.current

    var mode by remember { mutableStateOf(Mode.Code) }

    // 验证码登录
    var email by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var codeSent by remember { mutableStateOf(false) }

    // 密码登录
    var account by remember { mutableStateOf("") }
    var pwd by remember { mutableStateOf("") }

    // 注册
    var invited by remember { mutableStateOf(false) }

    var agreed by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf<String?>(null) }
    var noteBad by remember { mutableStateOf(false) }
    /// 底部那两个圆圈（微信 / 扫码）点开时的说明弹窗
    var tip by remember { mutableStateOf<String?>(null) }

    val scope = rememberCoroutineScope()
    val ink = MaterialTheme.colorScheme.onSurface
    val secondary = ink.copy(alpha = 0.55f)
    val tertiary = ink.copy(alpha = 0.38f)

    fun open(url: String) {
        runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    }

    val sendStep = (mode == Mode.Code && !codeSent) || (mode == Mode.Register && !invited)

    val title = when {
        working -> "处理中…"
        mode == Mode.Code -> if (codeSent) "登录" else "验证并登录"
        mode == Mode.Password -> "登录"
        else -> if (invited) "注册并登录" else "发送验证码"
    }

    val enabled = when (mode) {
        Mode.Code -> if (codeSent) code.isNotEmpty() else email.trim().isNotEmpty()
        Mode.Password -> account.trim().isNotEmpty() && pwd.isNotEmpty()
        Mode.Register ->
            if (invited) code.isNotEmpty() && pwd.length >= 8
            else email.trim().isNotEmpty() && pwd.length >= 8
    }

    fun primary() {
        if (working) return
        note = null
        noteBad = false
        // iOS：没勾协议点登录 → 标红提示，绝不替用户同意
        if (!agreed) {
            note = "请先阅读并同意用户协议和隐私政策。"
            noteBad = true
            return
        }
        working = true
        scope.launch {
            val r: AuthResult = withContext(Dispatchers.IO) {
                when (mode) {
                    Mode.Code ->
                        if (codeSent) Api.loginWithCode(email, code) else Api.sendLoginCode(email)
                    Mode.Password -> Api.loginPassword(account, pwd)
                    Mode.Register ->
                        if (invited) Api.register(email, pwd, code) else Api.sendRegisterCode(email)
                }
            }
            working = false
            if (r.ok) {
                if (sendStep) {
                    // 发码成功：留在本页，把验证码输入框亮出来
                    if (mode == Mode.Code) codeSent = true else invited = true
                } else {
                    onDone()
                }
            } else {
                note = if (r.code == 4113 || r.code == 4114 || r.code == 4115) {
                    r.msg
                } else {
                    r.msg.ifEmpty { "操作失败，请稍后再试" }
                }
                noteBad = true
            }
        }
    }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 22.dp)
            .padding(top = 10.dp, bottom = 30.dp)
    ) {
        // —— 顶部：只有「帮助」（强制登录门禁，没有上一页可退）——
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Text("帮助", fontSize = 15.sp, color = secondary,
                modifier = Modifier.padding(top = 4.dp)
                    .clickable { open("https://aevis.cn/support.html") })
        }
        Spacer(Modifier.height(26.dp))

        // —— 标题 ——
        Text("登录发现更多精彩", fontSize = 25.sp, fontWeight = FontWeight.SemiBold, color = ink)
        Spacer(Modifier.height(8.dp))
        Text(
            if (mode == Mode.Register) "邮箱 + 密码 + 验证码，注册即赠 30 天体验"
            else "验证码只发给已注册的邮箱；还没有账号就点「去注册」",
            fontSize = 12.5.sp, color = secondary, lineHeight = 19.sp
        )
        Spacer(Modifier.height(26.dp))

        // —— 输入区 ——
        when (mode) {
            Mode.Code -> {
                BigField(R.drawable.ic_login_mail, "请输入邮箱", email, { email = it })
                if (codeSent) {
                    Spacer(Modifier.height(12.dp))
                    BigField(R.drawable.ic_login_hash, "邮箱里那 6 位数字", code, { code = it },
                        number = true, imeDone = true)
                }
            }
            Mode.Password -> {
                BigField(R.drawable.ic_login_person, "邮箱或手机号", account, { account = it })
                Spacer(Modifier.height(12.dp))
                BigField(R.drawable.ic_login_lock, "密码", pwd, { pwd = it }, secret = true)
            }
            Mode.Register -> {
                BigField(R.drawable.ic_login_mail, "用来收验证码的邮箱", email, { email = it })
                Spacer(Modifier.height(12.dp))
                BigField(R.drawable.ic_login_lock, "密码：至少 8 位，含字母和数字", pwd,
                    { pwd = it }, secret = true, imeDone = !invited)
                if (invited) {
                    Spacer(Modifier.height(12.dp))
                    BigField(R.drawable.ic_login_hash, "邮箱里那 6 位数字", code, { code = it },
                        number = true, imeDone = true)
                }
            }
        }
        Spacer(Modifier.height(14.dp))

        // —— 切换行 ——
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(
                Modifier.clickable(enabled = !working) {
                    mode = if (mode == Mode.Code) Mode.Password else Mode.Code
                    codeSent = false
                }, verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(painterResource(R.drawable.ic_login_swap), null, tint = V2.accent,
                    modifier = Modifier.size(13.dp))
                Spacer(Modifier.width(5.dp))
                Text(if (mode == Mode.Code) "密码登录" else "验证码登录",
                    fontSize = 13.5.sp, color = V2.accent)
            }
            Spacer(Modifier.width(16.dp))
            Text(
                if (mode == Mode.Register) "已经有账号，去登录" else "没有账号，去注册",
                fontSize = 13.5.sp, color = secondary,
                modifier = Modifier.clickable(enabled = !working) {
                    mode = if (mode == Mode.Register) Mode.Code else Mode.Register
                    invited = false
                }
            )
        }
        Spacer(Modifier.height(22.dp))

        // —— 主按钮：整宽胶囊，禁用态是淡色（不是灰块）——
        Box(
            Modifier.fillMaxWidth()
                .clip(CircleShape)
                .background(if (enabled && !working) V2.accent else V2.accent.copy(alpha = 0.35f))
                .clickable(enabled = enabled && !working) { primary() }
                .padding(vertical = 16.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(title, fontSize = 16.5.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        }

        Spacer(Modifier.height(14.dp))

        // —— 协议 ——
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Box(
                Modifier.padding(top = 2.dp).size(16.dp).clip(CircleShape)
                    .then(
                        if (agreed) Modifier.background(V2.accent)
                        else Modifier.border(1.5.dp, secondary.copy(alpha = 0.6f), CircleShape)
                    )
                    .clickable { agreed = !agreed },
                contentAlignment = Alignment.Center
            ) {
                if (agreed) {
                    Icon(painterResource(R.drawable.ic_login_check), null,
                        tint = Color.White, modifier = Modifier.size(11.dp))
                }
            }
            Spacer(Modifier.width(8.dp))
            Column {
                Row {
                    Text("已阅读并同意 ", fontSize = 11.5.sp, color = secondary)
                    Text("用户协议", fontSize = 11.5.sp, color = V2.accent,
                        modifier = Modifier.clickable { open("https://aevis.cn/terms.html") })
                    Text(" 和 ", fontSize = 11.5.sp, color = secondary)
                    Text("隐私政策", fontSize = 11.5.sp, color = V2.accent,
                        modifier = Modifier.clickable { open("https://aevis.cn/privacy.html") })
                }
                Spacer(Modifier.height(2.dp))
                Text("未注册的邮箱验证通过后将自动创建账号。",
                    fontSize = 11.sp, color = tertiary)
            }
        }

        if (note != null) {
            Spacer(Modifier.height(12.dp))
            Text(note ?: "", fontSize = 12.5.sp,
                color = if (noteBad) V2.alert else secondary, lineHeight = 19.sp)
        }

        // 内容不满一屏时把圆圈那排顶到底部（抖音是贴着键盘上沿的）
        Spacer(Modifier.height(96.dp))

        // —— 底部：微信 / QQ / 扫码 / 找回账号 ——
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircleEntry("微信", R.drawable.ic_login_wechat,
                Color(0xFF4AB85C), !working) {
                tip = "微信登录还在接入。现在用邮箱验证码最快；微信里也能直接搜「Aevis」小程序。"
            }
            Spacer(Modifier.width(14.dp))
            CircleEntry("QQ", R.drawable.ic_login_qq,
                Color(0xFF428CF0), !working) {
                // 真跳：系统浏览器 → QQ 授权 → 服务端 302 回 aevis://login
                if (working) return@CircleEntry
                working = true
                scope.launch {
                    val (url, e) = withContext(Dispatchers.IO) { Api.qqAuthUrl() }
                    working = false
                    if (url.isEmpty()) {
                        note = e; noteBad = true
                    } else {
                        open(url)
                    }
                }
            }
            Spacer(Modifier.width(14.dp))
            CircleEntry("扫码", R.drawable.ic_login_qr,
                Color(0xFF6B708C), !working) {
                tip = "扫码是给平板和网页版用的。手机上直接用邮箱验证码登录就行。"
            }
            Spacer(Modifier.width(14.dp))
            Text("找回账号", fontSize = 13.5.sp, color = secondary,
                modifier = Modifier.clip(CircleShape)
                    .border(0.8.dp, secondary.copy(alpha = 0.35f), CircleShape)
                    .clickable { open("https://aevis.cn/support.html") }
                    .padding(horizontal = 18.dp, vertical = 11.dp))
        }
    }

    if (tip != null) {
        AlertDialog(
            onDismissRequest = { tip = null },
            confirmButton = {
                TextButton(onClick = { tip = null }) { Text("知道了") }
            },
            text = { Text(tip ?: "", fontSize = 14.sp, lineHeight = 21.sp) }
        )
    }
}

/** 大圆角输入框（抖音同款）：16 圆角、5.5% 底、左侧图标 18、正文 15.5。 */
@Composable
private fun BigField(icon: Int, placeholder: String, value: String,
                     onChange: (String) -> Unit,
                     secret: Boolean = false, number: Boolean = false,
                     imeDone: Boolean = false) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(ink.copy(alpha = 0.055f))
            .padding(horizontal = 16.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(painterResource(icon), null, tint = ink.copy(alpha = 0.5f),
            modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        BasicTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(
                fontSize = 15.5.sp, color = ink
            ),
            cursorBrush = SolidColor(V2.accent),
            visualTransformation =
                if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                keyboardType = when {
                    secret -> KeyboardType.Password
                    number -> KeyboardType.Number
                    else -> KeyboardType.Email
                },
                imeAction = if (imeDone) ImeAction.Done else ImeAction.Next
            ),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        Text(placeholder, fontSize = 15.5.sp, color = ink.copy(alpha = 0.35f))
                    }
                    inner()
                }
            }
        )
    }
}

/** 一个圆形入口：52 圆底（13% 色）+ 图标 20，下面 11 字。 */
@Composable
private fun CircleEntry(title: String, icon: Int, color: Color,
                        enabled: Boolean, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.clickable(enabled = enabled) { onClick() }
            .then(if (enabled) Modifier else Modifier.padding(0.dp))
    ) {
        Box(
            Modifier.size(52.dp).clip(CircleShape).background(color.copy(alpha = 0.13f)),
            contentAlignment = Alignment.Center
        ) {
            Icon(painterResource(icon), null, tint = color, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(6.dp))
        Text(title, fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f), maxLines = 1)
    }
}
