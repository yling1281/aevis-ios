package com.aevis.android.ui

import android.content.Context
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.Spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * 朋友圈（2026-11-17）。
 *
 * 用户：「朋友圈也开始搞动态」「也要让 AI 可以发朋友圈」。
 *
 * - 卡片入场：整块上浮 + 透明度（不是逐元素），停下时 spring 轻微回弹
 * - AI 发一条：走现有 `Api.chat`，生成后作为卡片插到最前面
 * - 本地持久化：SharedPreferences 存 JSON，重启还在
 */
private data class Moment(
    val id: Long,
    val author: String,
    val text: String,
    val ts: Long,
    val likes: Int,
    val mine: Boolean,
    val ai: Boolean
)

private object MomentStore {
    private const val F = "aevis_moments"
    private const val K = "items"

    private fun sp(ctx: Context) = ctx.getSharedPreferences(F, Context.MODE_PRIVATE)

    fun load(ctx: Context): MutableList<Moment> {
        val raw = sp(ctx).getString(K, "") ?: ""
        if (raw.isBlank()) return mutableListOf()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                Moment(
                    o.optLong("id"), o.optString("author"), o.optString("text"),
                    o.optLong("ts"), o.optInt("likes"),
                    o.optBoolean("mine"), o.optBoolean("ai")
                )
            }.toMutableList()
        } catch (e: Exception) {
            mutableListOf()
        }
    }

    fun save(ctx: Context, list: List<Moment>) {
        val arr = JSONArray()
        list.forEach {
            arr.put(
                JSONObject().put("id", it.id).put("author", it.author).put("text", it.text)
                    .put("ts", it.ts).put("likes", it.likes).put("mine", it.mine).put("ai", it.ai)
            )
        }
        sp(ctx).edit().putString(K, arr.toString()).apply()
    }
}

private fun relTime(ts: Long): String {
    val d = (System.currentTimeMillis() - ts) / 1000
    return when {
        d < 60 -> "刚刚"
        d < 3600 -> "${d / 60} 分钟前"
        d < 86400 -> "${d / 3600} 小时前"
        else -> "${d / 86400} 天前"
    }
}

@Composable
fun MomentsScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val ink = MaterialTheme.colorScheme.onSurface
    val scope = rememberCoroutineScope()

    var list by remember { mutableStateOf<List<Moment>>(MomentStore.load(ctx)) }
    var composing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var aiBusy by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }

    fun push(m: Moment) {
        list = listOf(m) + list
        MomentStore.save(ctx, list)
    }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // 顶栏
        Row(
            Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier.size(44.dp).clip(RoundedCornerShape(50)).tapable { onBack() },
                contentAlignment = Alignment.Center
            ) { Text("‹", fontSize = 26.sp, color = ink.copy(alpha = 0.75f)) }
            Text("朋友圈", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            if (aiBusy) {
                Text("正在写…", fontSize = 12.sp, color = ink.copy(alpha = 0.4f))
            } else {
                Box(
                    Modifier.clip(RoundedCornerShape(14.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                        .tapable {
                            aiBusy = true
                            scope.launch {
                                val txt = withContext(Dispatchers.IO) {
                                    runCatching {
                                        Api.chat(
                                            "deepseek-flash",
                                            listOf(Api.Msg("user",
                                                "用第一人称写一条朋友圈，20-40 字，生活化、有点情绪，" +
                                                    "不要话题标签，不要引号，直接给正文。")),
                                            "你是一个真实的人，说话口语化，不发广告。"
                                        )
                                    }.getOrNull()
                                }
                                aiBusy = false
                                if (txt.isNullOrBlank()) {
                                    note = "AI 没写成，检查网络或额度"
                                } else {
                                    push(Moment(System.currentTimeMillis(), "TA", txt.trim(),
                                        System.currentTimeMillis(), 0, false, true))
                                    note = "TA 发了一条"
                                }
                            }
                        }
                ) { Text("让 TA 发一条", fontSize = 12.sp) }
            }
        }

        if (note.isNotBlank()) {
            Text(note, fontSize = 12.sp, color = ink.copy(alpha = 0.45f),
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 2.dp))
        }

        if (list.isEmpty()) {
            Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Text("还没有动态。点右下角写一条，或让 TA 发一条。",
                    fontSize = 13.sp, color = ink.copy(alpha = 0.35f))
            }
        } else {
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp)) {
                itemsIndexed(list) { i, m ->
                    MomentCard(m, index = i) {
                        list = list.map { if (it.id == m.id) it.copy(likes = it.likes + 1) else it }
                        MomentStore.save(ctx, list)
                    }
                    Spacer(Modifier.height(12.dp))
                }
            }
        }

        // 发布
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (composing) {
                BasicDraft(draft, ink, onDraft = { draft = it }, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                Box(
                    Modifier.clip(RoundedCornerShape(14.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                        .tapable {
                            if (draft.isNotBlank()) {
                                push(Moment(System.currentTimeMillis(), "我", draft.trim(),
                                    System.currentTimeMillis(), 0, true, false))
                                draft = ""; composing = false; note = ""
                            }
                        }
                ) { Text("发布", fontSize = 13.sp, fontWeight = FontWeight.Medium) }
            } else {
                Box(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .padding(vertical = 12.dp).tapable { composing = true },
                    contentAlignment = Alignment.Center
                ) { Text("写点什么…", fontSize = 14.sp, color = ink.copy(alpha = 0.45f)) }
            }
        }
    }
}

@Composable
private fun BasicDraft(value: String, ink: androidx.compose.ui.graphics.Color,
                       onDraft: (String) -> Unit, modifier: Modifier = Modifier) {
    androidx.compose.foundation.text.BasicTextField(
        value = value,
        onValueChange = onDraft,
        textStyle = androidx.compose.ui.text.TextStyle(
            fontSize = 14.sp, color = ink
        ),
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 14.dp, vertical = 12.dp)
    )
}

/** 卡片：入场时整块上浮 + 淡入，停下有轻微回弹。 */
@Composable
private fun MomentCard(m: Moment, index: Int, onLike: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(m.id) {
        delay((index.coerceAtMost(5) * 60).toLong())
        shown = true
    }
    val p by animateFloatAsState(
        targetValue = if (shown) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.62f, stiffness = Spring.StiffnessLow),
        label = "card"
    )

    Column(
        Modifier.fillMaxWidth()
            .graphicsLayer {
                alpha = p.coerceIn(0f, 1f)
                translationY = (1f - p) * 26f
            }
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(14.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(34.dp).clip(RoundedCornerShape(50))
                    .background(if (m.ai) MaterialTheme.colorScheme.secondary
                    else MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    m.author.take(1),
                    fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    color = if (m.ai) MaterialTheme.colorScheme.onSecondary else ink
                )
            }
            Spacer(Modifier.width(10.dp))
            Column {
                Text(m.author, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                Text(relTime(m.ts), fontSize = 11.sp, color = ink.copy(alpha = 0.35f))
            }
            Spacer(Modifier.weight(1f))
            if (m.ai) {
                Text("AI", fontSize = 10.sp, color = ink.copy(alpha = 0.35f))
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(m.text, fontSize = 14.5.sp, color = ink.copy(alpha = 0.88f), lineHeight = 22.sp)
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.clip(RoundedCornerShape(12.dp))
                    .padding(horizontal = 10.dp, vertical = 5.dp)
                    .tapable { onLike() }
            ) {
                Text(
                    if (m.likes > 0) "♡ ${m.likes}" else "♡ 赞",
                    fontSize = 12.sp, color = ink.copy(alpha = 0.5f)
                )
            }
        }
    }
}
