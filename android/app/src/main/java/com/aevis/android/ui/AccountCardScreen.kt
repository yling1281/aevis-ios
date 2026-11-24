package com.aevis.android.ui

import com.aevis.android.R
import androidx.compose.ui.res.painterResource
import androidx.compose.material3.Icon
import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.I18n
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 个人账号页（2026-11-16，92，路由 `account`）。
 *
 * 从「我」页那块头像+昵称点进来。核心是**平台 ID**（public_id）：
 * 别人凭这 9 位数字就能找到你，所以用等宽大字 + 一键复制。
 */
@Composable
fun AccountCardScreen(
    onBack: () -> Unit,
    onOpenCloud: () -> Unit,
    onOpenLang: () -> Unit,
    onSignOut: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var card by remember { mutableStateOf<Api.AccountCard?>(null) }
    var askSearch by remember { mutableStateOf(false) }
    var searchText by remember { mutableStateOf("") }
    var confirmOut by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            val c = runCatching { Api.accountCard() }.getOrNull()
            // #5（99）：accountCard 可能拿不到（未登录/接口抖动），
            // 这时用 `me()` / `cachedMe()` 把昵称头像补上，别整页空白。
            val m = runCatching { Api.me() }.getOrNull()
                ?: runCatching { Api.cachedMe() }.getOrNull()
            card = c?.copy(
                nickname = c.nickname.ifBlank { m?.nickname.orEmpty() },
                avatar = c.avatar.ifBlank { m?.avatar.orEmpty() },
                email = c.email.ifBlank { m?.email.orEmpty() }
            ) ?: m?.let {
                Api.AccountCard(
                    publicId = "",   // MeInfo 没有 public_id，只有 accountCard 才给；拿不到就显示 —
                    email = it.email.orEmpty(),
                    emailBound = it.email.isNotBlank(),
                    bindings = emptyList(),
                    nickname = it.nickname.orEmpty(),
                    avatar = it.avatar.orEmpty()
                )
            }
        }
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = tr("个人账号"), onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {

            // ---------- 头部 ----------
            Column(
                Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 14.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Avatar(card?.avatar.orEmpty(), card?.nickname.orEmpty(), 72.dp)
                Spacer(Modifier.height(10.dp))
                Text(
                    card?.nickname?.ifBlank { tr("未设置昵称") } ?: "—",
                    fontSize = 18.sp, fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(3.dp))
                Text(
                    card?.email?.ifBlank { "—" } ?: "—",
                    fontSize = 12.sp, color = ink.copy(alpha = 0.45f)
                )
            }

            // ---------- 平台 ID ----------
            V2Card(Modifier.padding(horizontal = V2.gutter)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        tr("Aevis 号"), fontSize = 12.sp, color = ink.copy(alpha = 0.5f)
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        tr("复制"), fontSize = 12.sp, color = V2.accent,
                        modifier = Modifier.clip(squircle(8.dp))
                            .background(V2.accent.copy(alpha = 0.12f))
                            .tapable {
                                val id = card?.publicId.orEmpty()
                                if (id.isNotBlank()) {
                                    copyToClipboard(ctx, id)
                                    android.widget.Toast.makeText(
                                        ctx, "已复制", android.widget.Toast.LENGTH_SHORT
                                    ).show()
                                }
                            }
                            .padding(horizontal = 10.dp, vertical = 4.dp)
                    )
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    card?.publicId?.ifBlank { "—" } ?: "—",
                    fontSize = 22.sp, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Medium, letterSpacing = 2.sp
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    tr("这是你的 Aevis 号，别人可以凭它找到你"),
                    fontSize = 10.5.sp, color = ink.copy(alpha = 0.4f)
                )
            }

            Spacer(Modifier.height(V2.sectionGap))

            // ---------- 第三方绑定 ----------
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                val providers = card?.bindings.orEmpty().map { it.provider.lowercase() }
                val wxBound = providers.contains("wechat") || providers.contains("wx")
                BindRow(tr("微信"), wxBound) {
                    toast(ctx, if (wxBound) "暂不支持解绑" else "暂不支持")
                }
                AccountDivider()
                val qqBound = providers.contains("qq")
                BindRow(tr("QQ"), qqBound) {
                    toast(ctx, if (qqBound) "暂不支持解绑" else "暂不支持")
                }
                AccountDivider()
                // 云备份状态（复用 Api 里的同步结果，失败要看得见）
                Row(
                    Modifier.fillMaxWidth().tapable { onOpenCloud() }
                        .padding(horizontal = V2.gutter, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(tr("云备份"), fontSize = V2.body)
                    Spacer(Modifier.weight(1f))
                    val err = Api.lastBackupError
                    val at = Api.lastBackupOkAt
                    Text(
                        when {
                            err.isNotBlank() -> tr("失败：%s", err)
                            at > 0L -> tr("上次同步：%s",
                                java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.US)
                                    .format(java.util.Date(at)))
                            else -> tr("还没同步过")
                        },
                        fontSize = 11.5.sp,
                        color = if (err.isNotBlank()) V2.alert else ink.copy(alpha = 0.45f)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("›", fontSize = 18.sp, color = ink.copy(alpha = 0.3f))
                }
                AccountDivider()
                Row(
                    Modifier.fillMaxWidth().tapable { onOpenLang() }
                        .padding(horizontal = V2.gutter, vertical = 13.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(tr("语言"), fontSize = V2.body)
                    Spacer(Modifier.weight(1f))
                    Text(
                        I18n.label(), fontSize = 11.5.sp, color = ink.copy(alpha = 0.45f)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("›", fontSize = 18.sp, color = ink.copy(alpha = 0.3f))
                }
            }

            Spacer(Modifier.height(18.dp))

            // ---------- 退出登录 ----------
            Text(
                tr("退出登录"), fontSize = V2.body, color = V2.alert,
                modifier = Modifier.fillMaxWidth()
                    .tapable { confirmOut = true }
                    .padding(vertical = 12.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )

            Spacer(Modifier.height(30.dp))
        }
    }

    // 找人（这轮只做输入与提示）
    if (askSearch) {
        AlertDialog(
            onDismissRequest = { askSearch = false },
            title = { Text(tr("找人")) },
            text = {
                Column {
                    Text(
                        tr("输入 9 位 Aevis 号"), fontSize = 11.5.sp,
                        color = ink.copy(alpha = 0.45f)
                    )
                    Spacer(Modifier.height(8.dp))
                    BasicTextField(
                        value = searchText,
                        onValueChange = { searchText = it.filter { c -> c.isDigit() }.take(9) },
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(
                            fontSize = 16.sp, color = ink, fontFamily = FontFamily.Monospace
                        )
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    askSearch = false
                    toast(ctx, "对方还没开通资料页")
                }) { Text(tr("查找"), color = V2.accent) }
            },
            dismissButton = {
                TextButton(onClick = { askSearch = false }) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }

    if (confirmOut) {
        AlertDialog(
            onDismissRequest = { confirmOut = false },
            title = { Text(tr("退出登录？")) },
            text = {
                Text(
                    tr("退出后聊天记录会先同步到云端，再清空这台设备上的本地记录。"),
                    fontSize = V2.sub, lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmOut = false
                    scope.launch {
                        withContext(Dispatchers.IO) { runCatching { Api.signOut() } }
                        onSignOut()
                    }
                }) { Text(tr("退出"), color = V2.alert) }
            },
            dismissButton = {
                TextButton(onClick = { confirmOut = false }) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }
}

@Composable
private fun BindRow(label: String, bound: Boolean, onClick: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        // #6（99）：绑定了也要能点 —— 点了明确告诉用户"暂不支持解绑"，
        // 不能像以前那样点了毫无反馈。
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, fontSize = V2.body)
        Spacer(Modifier.weight(1f))
        if (bound) {
            Box(
                Modifier.size(6.dp).clip(androidx.compose.foundation.shape.CircleShape)
                    .background(Color(0xFF4AB85C))
            )
            Spacer(Modifier.width(5.dp))
            Text(tr("已绑定 · 暂不支持解绑"), fontSize = 11.5.sp, color = ink.copy(alpha = 0.45f))
        } else {
            Text(tr("去绑定"), fontSize = 11.5.sp, color = V2.accent)
        }
    }
}

@Composable
private fun AccountDivider() {
    Box(
        Modifier.fillMaxWidth().height(0.5.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f))
    )
}

private fun toast(ctx: android.content.Context, msg: String) =
    android.widget.Toast.makeText(ctx, msg, android.widget.Toast.LENGTH_SHORT).show()

/**
 * 语言切换页（2026-11-16，92，路由 `lang`）。
 *
 * 用户明确要求「不是点一下立刻切」：选完只是**选中态**，
 * 点底部「应用并重启界面」才写盘 + `activity.recreate()`。
 */
@Composable
fun LangScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    var picked by remember { mutableStateOf(I18n.lang) }
    val dirty = picked != I18n.lang

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(title = tr("语言"), onBack = onBack)

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(6.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                LangRow("简体中文", picked == "zh") { picked = "zh" }
                AccountDivider()
                LangRow("English", picked == "en") { picked = "en" }
            }

            Spacer(Modifier.height(8.dp))
            Text(
                tr("只翻译界面文案，角色说的话保持原样。"),
                fontSize = 10.5.sp, color = ink.copy(alpha = 0.35f),
                modifier = Modifier.padding(horizontal = V2.gutter)
            )

            Spacer(Modifier.height(20.dp))
            Box(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter)
                    .clip(squircle(14.dp))
                    .background(if (dirty) V2.accent else ink.copy(alpha = 0.06f))
                    .tapable(enabled = dirty) {
                        I18n.setLang(ctx, picked)
                        (ctx as? Activity)?.recreate()
                    }
                    .padding(vertical = 13.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    tr("应用并重启界面"), fontSize = V2.body, fontWeight = FontWeight.Medium,
                    color = if (dirty) Color.White else ink.copy(alpha = 0.3f)
                )
            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

@Composable
private fun LangRow(label: String, on: Boolean, onClick: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().tapable { onClick() }
            .padding(horizontal = V2.gutter, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            label, fontSize = V2.body,
            color = if (on) V2.accent else ink
        )
        Spacer(Modifier.weight(1f))
        if (on) Icon(
            painterResource(R.drawable.ic_check), contentDescription = null,
            tint = V2.accent, modifier = Modifier.size(15.dp)
        )
    }
}
