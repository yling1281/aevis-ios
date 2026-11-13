package com.aevis.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.rememberCoroutineScope
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** iOS 那张「V2Card」：22 圆角、纯色、0.5pt 细边、**没有阴影**。*/
@Composable
fun V2Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(V2.cardRadius))
            .background(MaterialTheme.colorScheme.surface)
            .padding(16.dp),
        content = content
    )
}

@Composable
fun IconBox(text: String) {
    Box(
        Modifier.size(V2.iconBox)
            .clip(RoundedCornerShape(V2.iconRadius))
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center
    ) { Text(text, fontSize = 18.sp) }
}

// ------------------------------------------------------------------ 登录

@Composable
fun LoginScreen(onDone: () -> Unit) {
    var email by remember { mutableStateOf("") }
    var pwd by remember { mutableStateOf("") }
    var err by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)
            .padding(horizontal = V2.gutter).verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.height(96.dp))
        Text("Aevis", fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("登录后同步你的会话、积分与设置",
             fontSize = V2.sub, color = MaterialTheme.colorScheme.onSurface.copy(0.55f))
        Spacer(Modifier.height(32.dp))

        V2Card {
            Field("邮箱", email, false) { email = it }
            Spacer(Modifier.height(14.dp))
            Field("密码", pwd, true) { pwd = it }
            if (err.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                Text(err, color = V2.alert, fontSize = V2.tiny)
            }
            Spacer(Modifier.height(18.dp))
            Button(
                onClick = {
                    if (busy) return@Button
                    busy = true; err = ""
                    scope.launch {
                        val (ok, msg) = withContext(Dispatchers.IO) {
                            Api.login(email.trim(), pwd)
                        }
                        busy = false
                        if (ok) onDone() else err = msg
                    }
                },
                modifier = Modifier.fillMaxWidth().height(48.dp),
                shape = RoundedCornerShape(V2.rowRadius)
            ) { Text(if (busy) "登录中…" else "登录", fontSize = V2.body) }
        }
    }
}

@Composable
private fun Field(label: String, value: String, secret: Boolean, onChange: (String) -> Unit) {
    Column {
        Text(label, fontSize = V2.micro, color = MaterialTheme.colorScheme.onSurface.copy(0.45f))
        Spacer(Modifier.height(6.dp))
        Box(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(horizontal = 14.dp, vertical = 13.dp)
        ) {
            BasicTextField(
                value = value, onValueChange = onChange, singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontSize = V2.body),
                visualTransformation = if (secret) PasswordVisualTransformation()
                else androidx.compose.ui.text.input.VisualTransformation.None
            )
        }
    }
}

// ------------------------------------------------------------------ 主壳

private data class Tab(val title: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)

@Composable
fun Shell(onSignOut: () -> Unit) {
    val tabs = listOf(
        Tab("聊天", Icons.Outlined.ChatBubbleOutline),
        Tab("通讯录", Icons.Outlined.People),
        Tab("发现", Icons.Outlined.Explore),
        Tab("我", Icons.Outlined.Person)
    )
    var idx by remember { mutableIntStateOf(0) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            NavigationBar(containerColor = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp) {
                tabs.forEachIndexed { i, t ->
                    NavigationBarItem(
                        selected = idx == i,
                        onClick = { idx = i },
                        icon = { Icon(t.icon, contentDescription = t.title) },
                        label = { Text(t.title, fontSize = V2.micro) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = V2.accent,
                            selectedTextColor = V2.accent,
                            indicatorColor = V2.accent.copy(0.12f)
                        )
                    )
                }
            }
        }
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            when (idx) {
                0 -> ChatTab()
                1 -> ContactsTab()
                2 -> DiscoverTab()
                else -> MeTab(onSignOut)
            }
        }
    }
}

@Composable
private fun Header(title: String, sub: String? = null) {
    Column(Modifier.padding(start = V2.gutter, end = V2.gutter, top = 18.dp, bottom = 10.dp)) {
        Text(title, fontSize = V2.display, fontWeight = FontWeight.Bold)
        if (sub != null) {
            Spacer(Modifier.height(2.dp))
            Text(sub, fontSize = V2.sub, color = MaterialTheme.colorScheme.onSurface.copy(0.5f))
        }
    }
}

@Composable
private fun ChatTab() {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("聊天", "和你的 AI 伙伴说话")
        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            Box(Modifier.fillMaxWidth().height(180.dp), contentAlignment = Alignment.Center) {
                Text("会话列表接进来就能用", fontSize = V2.sub,
                     color = MaterialTheme.colorScheme.onSurface.copy(0.4f))
            }
        }
    }
}

@Composable
private fun ContactsTab() {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("通讯录", "人设、分组、一起听")
        listOf("我的 AI 伙伴" to "还没有添加", "人设广场" to "逛逛别人的角色",
               "一起听" to "和朋友同步播放").forEach { (t, s) ->
            V2Card(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconBox(t.take(1))
                    Spacer(Modifier.width(12.dp))
                    Column {
                        Text(t, fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Text(s, fontSize = V2.tiny,
                             color = MaterialTheme.colorScheme.onSurface.copy(0.45f))
                    }
                }
            }
        }
    }
}

@Composable
private fun DiscoverTab() {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("发现", "广场 · 表情 · 创作者")
        val items = listOf("人设广场" to "挑一个喜欢的角色", "表情包" to "商店里能直接加",
            "创作者中心" to "做自己的角色", "模型状态" to "看看哪些在售")
        items.chunked(2).forEach { row ->
            Row(Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)) {
                row.forEach { (t, s) ->
                    V2Card(Modifier.weight(1f).padding(end = 6.dp)) {
                        Text(t, fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(4.dp))
                        Text(s, fontSize = V2.micro,
                             color = MaterialTheme.colorScheme.onSurface.copy(0.45f))
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f).padding(start = 6.dp))
            }
        }
    }
}

@Composable
private fun MeTab(onSignOut: () -> Unit) {
    var balance by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(Unit) {
        balance = withContext(Dispatchers.IO) { Api.balance() }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        Header("我")
        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(56.dp).clip(RoundedCornerShape(20.dp))
                        .background(V2.accent.copy(0.14f)),
                    contentAlignment = Alignment.Center
                ) { Text(Api.email().take(1).uppercase(), fontSize = 22.sp, color = V2.accent) }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(Api.email().ifEmpty { "未登录" }, fontSize = V2.body,
                         fontWeight = FontWeight.Medium)
                    Text("UID ${Api.uid().ifEmpty { "-" }}", fontSize = V2.micro,
                         color = MaterialTheme.colorScheme.onSurface.copy(0.45f))
                }
            }
            Spacer(Modifier.height(16.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("积分余额", fontSize = V2.sub)
                Text(balance?.toString() ?: "—", fontSize = V2.title,
                     fontWeight = FontWeight.SemiBold, color = V2.accent)
            }
        }
        Spacer(Modifier.height(10.dp))
        V2Card(Modifier.padding(horizontal = V2.gutter)) {
            Row(
                Modifier.fillMaxWidth().clickable { Api.signOut(); onSignOut() }
                    .padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("退出登录", fontSize = V2.body, color = V2.alert)
                Text("›", color = MaterialTheme.colorScheme.onSurface.copy(0.3f))
            }
        }
    }
}
