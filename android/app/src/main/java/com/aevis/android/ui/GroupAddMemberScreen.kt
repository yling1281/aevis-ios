package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.GroupStore
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.PersonaLib
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 给群加人（2026-11-16）。
 *
 * 只做一件事：把人追加进 `memberIds`。已经在群里的人照 `MemberPicker` 的规则
 * 置灰保留（右侧写「已在群里」）—— 用户要能看见"这个已经有了"，而不是凭空消失。
 */
@Composable
fun GroupAddMemberScreen(gid: String, onBack: () -> Unit, onDone: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface

    var group by remember(gid) { mutableStateOf(GroupStore.find(gid)) }
    var picked by remember { mutableStateOf<Set<String>>(emptySet()) }
    var list by remember { mutableStateOf<List<Api.Persona>?>(null) }

    LaunchedEffect(gid) {
        list = withContext(Dispatchers.IO) {
            runCatching { PersonaLib.localList() }.getOrElse { emptyList() }
        }
    }

    val locked = group?.memberIds.orEmpty().toSet()
    val canAdd = picked.isNotEmpty()

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(
            title = "加人",
            onBack = onBack,
            subtitle = tr("加进「%s」", group?.name.orEmpty().ifBlank { tr("群聊") })
        )

        Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())) {
            Spacer(Modifier.height(2.dp))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    tr("选人"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                    color = ink.copy(alpha = 0.5f)
                )
                Spacer(Modifier.weight(1f))
                Text(
                    tr("已选 %d 人", picked.size), fontSize = V2.micro,
                    color = if (canAdd) V2.accent else ink.copy(alpha = 0.4f)
                )
            }
            Spacer(Modifier.height(6.dp))

            when (val items = list) {
                null -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                    Text(
                        tr("正在加载…"), fontSize = V2.tiny, color = ink.copy(alpha = 0.4f),
                        modifier = Modifier.padding(vertical = 18.dp)
                    )
                }
                else -> if (items.isEmpty()) {
                    V2Card(Modifier.padding(horizontal = V2.gutter)) {
                        Text(
                            tr("没有可以加的人了"),
                            fontSize = V2.tiny, color = ink.copy(alpha = 0.45f),
                            modifier = Modifier.padding(vertical = 18.dp)
                        )
                    }
                } else {
                    MemberPicker(
                        items = items,
                        picked = picked,
                        locked = locked,
                        onToggle = { id ->
                            picked = if (picked.contains(id)) picked - id else picked + id
                        }
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
        }

        Column(
            Modifier.fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = V2.gutter, vertical = 12.dp)
        ) {
            Box(
                Modifier.fillMaxWidth()
                    .clip(squircle(16.dp))
                    .background(if (canAdd) V2.accent else ink.copy(alpha = 0.06f))
                    .tapable(enabled = canAdd) {
                        val g = group ?: return@tapable
                        // 只追加，不动已有成员的顺序
                        GroupStore.save(g.copy(memberIds = g.memberIds + picked.toList()))
                        onDone()
                    }
                    .padding(vertical = 15.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    if (canAdd) tr("添加 %d 人", picked.size) else tr("添加"),
                    fontSize = 16.sp, fontWeight = FontWeight.Medium,
                    color = if (canAdd) Color.White else ink.copy(alpha = 0.35f)
                )
            }
        }
    }
}
