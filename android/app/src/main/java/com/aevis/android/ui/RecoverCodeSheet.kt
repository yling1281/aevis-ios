package com.aevis.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.ChatArchive
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 「用恢复码恢复」半窗（2026-11-16，119）。
 *
 * 换手机 / 重装但**没登录成功**时，用户手里只有一串恢复码 —— 这个半窗就是那条后路。
 *
 * 流程刻意分两步：先 `/stat` 让他看到「找到备份：141.8 KB · 11-16 23:36」，
 * 确认没问题再点「恢复」；不然输错一个字符点了恢复，失败信息会很含糊。
 * 写回复用 `ChatArchive.applyJson`（跟 ZIP 导入、116 的自动恢复同一条路径）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecoverCodeSheet(
    onDismiss: () -> Unit,
    onRecovered: (Int) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    // 只存 **归一后的 8 位 A-Z0-9**；横杠只是显示层的装饰（VisualTransformation）
    var raw by remember { mutableStateOf("") }
    var stat by remember { mutableStateOf<Api.RecoverStat?>(null) }
    var checking by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var err by remember { mutableStateOf("") }

    /**
     * 输入处理（2026-11-16，122）：
     * · 横杠 / 空格 / 小写 / 全角 全部由 `Api.normCode` 吃掉 —— **不要求用户自己打横杠**；
     * · 长度按**归一后**的字符数算（8 位），不是"带横杠 9 位"；
     * · 粘贴一整串（带空格、小写、中文输入法的全角横杠）也能过；
     * · 只有刚好 8 位才去查，不足 8 位只提示「现在几位」。
     */
    fun onInput(v: String) {
        val clean = Api.normCode(v).take(8)
        if (clean == raw) {
            // 只删了装饰用的横杠 —— 不要把输入吞掉，直接把光标留在原地
            return
        }
        raw = clean
        err = ""
        stat = null
        if (clean.length == 8) {
            checking = true
            scope.launch {
                val (s, e) = withContext(Dispatchers.IO) { Api.recoverStat(clean) }
                checking = false
                stat = s
                err = if (s == null) e.ifBlank { tr("恢复码不存在") }
                else if (s.hasBackup.not()) tr("这个恢复码还没有备份") else ""
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = { if (!working) onDismiss() },
        containerColor = dialogSurfaceColor(),
        scrimColor = Color.Black.copy(alpha = 0.32f)
    ) {
        Column(
            Modifier.fillMaxWidth()
                .padding(horizontal = V2.gutter)
                .navigationBarsPadding()
        ) {
            Text(tr("用恢复码恢复"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text(
                tr("在旧手机的「云空间」里能看到这串码，8 位字母数字"),
                fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
            )
            Spacer(Modifier.height(14.dp))

            // 输入框：等宽大字，字母之间留点呼吸
            Box(
                Modifier.fillMaxWidth()
                    .clip(squircle(14.dp))
                    .background(ink.copy(alpha = 0.05f))
                    .padding(horizontal = 14.dp, vertical = 14.dp)
            ) {
                BasicTextField(
                    value = raw,
                    onValueChange = { onInput(it) },
                    singleLine = true,
                    enabled = !working,
                    // 横杠只在**显示层**插，底层值始终是 8 位纯字母数字 ——
                    // 这样粘贴/退格都不会因为"删掉的是装饰字符"而卡住
                    visualTransformation = CodeDash,
                    textStyle = TextStyle(
                        fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace,
                        letterSpacing = 2.sp,
                        color = ink
                    ),
                    cursorBrush = SolidColor(V2.accent),
                    decorationBox = { inner ->
                        if (raw.isEmpty()) {
                            Text(
                                "ABCD-EFGH", fontSize = 22.sp,
                                fontFamily = FontFamily.Monospace, letterSpacing = 2.sp,
                                color = ink.copy(alpha = 0.25f)
                            )
                        }
                        inner()
                    },
                    modifier = Modifier.fillMaxWidth()
                )
            }

            Spacer(Modifier.height(10.dp))
            when {
                checking -> Text(
                    tr("正在查询…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
                )
                err.isNotBlank() -> Text(
                    err, fontSize = V2.tiny, color = V2.alert, lineHeight = 18.sp
                )
                stat != null && stat!!.hasBackup -> Text(
                    tr(
                        "找到备份：%s · %s",
                        fmtBackupSize(stat!!.bytes), fmtBackupTime(stat!!.at)
                    ),
                    fontSize = V2.tiny, color = V2.accent
                )
                raw.length in 1..7 -> Text(
                    // 122：报具体位数，不要只说"格式不对"
                    tr("码要 8 位（现在 %d 位）", raw.length),
                    fontSize = V2.tiny, color = ink.copy(alpha = 0.45f)
                )
            }

            Spacer(Modifier.height(16.dp))
            val canRecover = stat?.hasBackup == true && !working
            Box(
                Modifier.fillMaxWidth()
                    .clip(squircle(14.dp))
                    .background(if (canRecover) V2.accent else ink.copy(alpha = 0.06f))
                    // 122：不满 8 位也让点 —— 点了就给一句「码要 8 位（现在 N 位）」，
                    // 比一个"灰着没反应"的按钮好懂。
                    .tapable(enabled = !working) {
                        if (!canRecover) {
                            err = if (raw.length < 8) tr("码要 8 位（现在 %d 位）", raw.length)
                            else tr("这个恢复码还没有备份")
                            return@tapable
                        }
                        val code = raw
                        working = true
                        err = ""
                        scope.launch {
                            val (backup, e) = withContext(Dispatchers.IO) {
                                Api.recoverPull(code)
                            }
                            if (backup.isBlank()) {
                                working = false
                                err = e.ifBlank { tr("恢复失败，稍后再试") }
                                return@launch
                            }
                            val r = withContext(Dispatchers.IO) {
                                ChatArchive.applyJson(ctx, backup, merge = true)
                            }
                            working = false
                            if (r.err.isBlank()) {
                                onRecovered(r.convs)
                            } else {
                                err = r.err
                            }
                        }
                    }
                    .padding(vertical = 14.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    if (working) tr("正在恢复…") else tr("恢复"),
                    fontSize = V2.body, fontWeight = FontWeight.Medium,
                    color = if (canRecover || working) Color.White else ink.copy(alpha = 0.35f)
                )
            }
            if (working) {
                Spacer(Modifier.height(10.dp))
                LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth(),
                    color = V2.accent,
                    trackColor = ink.copy(alpha = 0.08f)
                )
            }

            Spacer(Modifier.height(10.dp))
            Text(
                tr("恢复是合并的：只补新消息，本地已有的不会丢。"),
                fontSize = V2.micro, color = ink.copy(alpha = 0.42f)
            )
            Spacer(Modifier.height(18.dp))
        }
    }
}

/**
 * 恢复码的显示装饰（2026-11-16，122）：底层值永远是 8 位纯 `A-Z0-9`，
 * 渲染时在第 4 位后插一个 `-`。
 *
 * 为什么不用"value 里真的拼横杠"那种写法：那样用户按退格删到横杠时，
 * 拼回去又出现，光标会卡在同一个位置，看起来像"删不掉/输不进去"。
 * `VisualTransformation` 只改显示，不改数据，退格、粘贴、全选替换都不会出问题。
 */
private object CodeDash : androidx.compose.ui.text.input.VisualTransformation {
    override fun filter(text: androidx.compose.ui.text.AnnotatedString)
            : androidx.compose.ui.text.input.TransformedText {
        val raw = text.text
        val out = buildString(raw.length + 1) {
            raw.forEachIndexed { i, c ->
                if (i == 4) append('-')
                append(c)
            }
        }
        val mapping = object : androidx.compose.ui.text.input.OffsetMapping {
            override fun originalToTransformed(offset: Int): Int =
                if (offset <= 4) offset else offset + 1
            override fun transformedToOriginal(offset: Int): Int =
                if (offset <= 4) offset else offset - 1
        }
        return androidx.compose.ui.text.input.TransformedText(
            androidx.compose.ui.text.AnnotatedString(out), mapping
        )
    }
}
