package com.aevis.android.ui

import com.aevis.android.R
import androidx.compose.ui.res.painterResource
import androidx.compose.material3.Icon
import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.GroupStore
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.PersonaLib
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 新建群聊（2026-11-16）。
 *
 * 两步（95 起）：
 *   ① 选成员 —— 至少选一个人才能下一步（空群没人接话）；
 *   ② 群资料 —— 群头像（可选）+ 群名（**不能空**，默认「我的群聊」）。
 *
 * 为什么把群资料拆成单独一步而不是塞在选人上面：
 * 建群时人的注意力在「拉谁进来」，头像和名字是第二件事；
 * 一屏塞两件事，用户会先点"创建"再去群里改名（多一步）。
 *
 * 成员列表用的是「我的角色」（`PersonaLib.localList()`）——
 * 广场上没下载的角色不该出现在这里，跟聊天列表一个口径。
 */
@Composable
fun GroupCreateScreen(onBack: () -> Unit, onCreate: (String) -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var step by remember { mutableIntStateOf(0) }
    var name by remember { mutableStateOf(tr("我的群聊")) }
    var avatar by remember { mutableStateOf("") }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var uploading by remember { mutableStateOf(false) }
    var picked by remember { mutableStateOf<Set<String>>(emptySet()) }
    var list by remember { mutableStateOf<List<Api.Persona>?>(null) }

    LaunchedEffect(Unit) {
        list = withContext(Dispatchers.IO) {
            runCatching { PersonaLib.localList() }.getOrElse { emptyList() }
        }
    }

    // 群头像：相册选图 → 立刻本地预览 → 后台裁 512 + 上传 /v1/media
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            preview = decodeGroupAvatarPreview(ctx, uri)
            uploading = true
            val path = uploadGroupAvatar(ctx, uri)
            uploading = false
            if (path == null) {
                android.widget.Toast.makeText(
                    ctx, tr("头像没传上去，稍后再试"), android.widget.Toast.LENGTH_SHORT
                ).show()
            } else {
                avatar = path
            }
        }
    }

    val canNext = picked.isNotEmpty()
    val canCreate = name.trim().isNotEmpty() && picked.isNotEmpty() && !uploading

    BackHandler {
        if (step > 0) step-- else onBack()
    }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(
            title = if (step == 0) "新建群聊" else "群资料",
            onBack = { if (step > 0) step-- else onBack() },
            subtitle = if (step == 0) tr("先选几个人") else tr("给它一张脸和一个名字")
        )

        Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())) {
            if (step == 0) {
                // ---------- 第一步：选成员 ----------
                Row(
                    Modifier.fillMaxWidth().padding(
                        horizontal = V2.gutter, vertical = 4.dp
                    ),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        tr("选成员"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                        color = ink.copy(alpha = 0.5f)
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        tr("已选 %d 人", picked.size), fontSize = V2.micro,
                        color = if (picked.isEmpty()) ink.copy(alpha = 0.4f) else V2.accent
                    )
                }
                Spacer(Modifier.height(8.dp))

                when (val items = list) {
                    null -> V2Card(Modifier.padding(horizontal = V2.gutter)) {
                        Text(
                            tr("正在加载…"), fontSize = V2.tiny,
                            color = ink.copy(alpha = 0.4f),
                            modifier = Modifier.padding(vertical = 18.dp)
                        )
                    }
                    else -> if (items.isEmpty()) {
                        V2Card(Modifier.padding(horizontal = V2.gutter)) {
                            Text(
                                tr("还没有自己的角色，先去广场下载一个"),
                                fontSize = V2.tiny, color = ink.copy(alpha = 0.45f),
                                modifier = Modifier.padding(vertical = 18.dp)
                            )
                        }
                    } else {
                        MemberPicker(
                            items = items,
                            picked = picked,
                            locked = emptySet(),
                            onToggle = { id ->
                                picked = if (picked.contains(id)) picked - id else picked + id
                            }
                        )
                    }
                }
                Spacer(Modifier.height(24.dp))
            } else {
                // ---------- 第二步：群资料 ----------
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = V2.gutter),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    GroupAvatarPicker(
                        avatar = avatar, preview = preview, name = name,
                        size = 88.dp, uploading = uploading
                    ) {
                        picker.launch(
                            PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageOnly
                            )
                        )
                    }
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(tr("群头像"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(3.dp))
                        Text(
                            when {
                                uploading -> tr("正在上传…")
                                avatar.isEmpty() -> tr("可以跳过，以后在群资料里换")
                                else -> tr("点左边换一张")
                            },
                            fontSize = 11.5.sp, color = ink.copy(alpha = 0.55f),
                            lineHeight = 16.sp
                        )
                    }
                }

                Spacer(Modifier.height(22.dp))
                Text(
                    tr("群昵称"), fontSize = V2.micro, color = ink.copy(alpha = 0.42f),
                    modifier = Modifier.padding(
                        start = V2.gutter, end = V2.gutter, bottom = 7.dp
                    )
                )
                Box(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = V2.gutter)
                        .clip(squircle(14.dp))
                        .background(ink.copy(alpha = 0.05f))
                        .padding(horizontal = 13.dp, vertical = 11.dp)
                ) {
                    BasicTextField(
                        value = name,
                        onValueChange = { name = it },
                        singleLine = true,
                        textStyle = TextStyle(fontSize = V2.body, color = ink),
                        cursorBrush = SolidColor(V2.accent),
                        decorationBox = { inner ->
                            if (name.isEmpty()) {
                                Text(
                                    tr("我的群聊"), fontSize = V2.body,
                                    color = ink.copy(alpha = 0.32f)
                                )
                            }
                            inner()
                        },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
                if (name.trim().isEmpty()) {
                    Spacer(Modifier.height(6.dp))
                    Text(
                        tr("群名不能为空"), fontSize = V2.micro,
                        color = V2.alert.copy(alpha = 0.85f),
                        modifier = Modifier.padding(horizontal = V2.gutter)
                    )
                }

                Spacer(Modifier.height(18.dp))
                Text(
                    tr("群里有 %d 个人", picked.size), fontSize = V2.micro,
                    color = ink.copy(alpha = 0.42f),
                    modifier = Modifier.padding(horizontal = V2.gutter)
                )
                Spacer(Modifier.height(24.dp))
            }
        }

        // ---------- 底部主按钮 ----------
        if (step == 0) {
            GroupPrimaryButton(
                text = tr("下一步"),
                enabled = canNext,
                hint = tr("至少选一个人")
            ) { step = 1 }
        } else {
            GroupPrimaryButton(
                text = tr("创建群聊"),
                enabled = canCreate,
                hint = if (uploading) tr("头像还在上传") else tr("群名不能为空")
            ) {
                val gid = GroupStore.newId()
                GroupStore.save(
                    GroupStore.Group(
                        id = gid,
                        name = name.trim(),
                        memberIds = picked.toList(),
                        updatedAt = 0L,
                        avatar = avatar
                    )
                )
                onCreate(gid)
            }
        }
    }
}

/**
 * 选人列表（建群 / 加人共用，2026-11-16）。
 *
 * `locked` 是「已经在群里的人」：**置灰但仍然显示**，右侧写「已在群里」。
 * 直接不给他们看的话，用户会以为是列表少了人（"我明明有 5 个角色，怎么只显示 2 个"）。
 */
@Composable
internal fun MemberPicker(
    items: List<Api.Persona>,
    picked: Set<String>,
    locked: Set<String>,
    onToggle: (String) -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
        items.forEachIndexed { i, p ->
            val isLocked = locked.contains(p.id)
            val on = picked.contains(p.id)
            if (i > 0) {
                Box(
                    Modifier.fillMaxWidth().height(0.5.dp)
                        .background(ink.copy(alpha = 0.07f))
                )
            }
            Row(
                Modifier.fillMaxWidth()
                    .alpha(if (isLocked) 0.42f else 1f)
                    .then(if (isLocked) Modifier else Modifier.tapable { onToggle(p.id) })
                    .padding(horizontal = V2.gutter, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Avatar(p.avatar, p.name, 44.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        p.name, fontSize = V2.body, fontWeight = FontWeight.Medium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis
                    )
                    if (p.tagline.isNotBlank()) {
                        Text(
                            p.tagline, fontSize = V2.micro,
                            color = ink.copy(alpha = 0.45f), maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                Spacer(Modifier.width(8.dp))
                if (isLocked) {
                    Text(
                        tr("已在群里"), fontSize = V2.micro,
                        color = ink.copy(alpha = 0.5f)
                    )
                } else {
                    // 22dp 圆形勾选：选中 = 实心主色 + 白勾；未选 = 空心描边
                    Box(
                        Modifier.size(22.dp).clip(CircleShape)
                            .background(if (on) V2.accent else Color.Transparent)
                            .then(
                                if (on) Modifier
                                else Modifier.border(1.4.dp, ink.copy(alpha = 0.22f), CircleShape)
                            ),
                        contentAlignment = Alignment.Center
                    ) {
                        if (on) {
                            Icon(
                                painterResource(R.drawable.ic_check), contentDescription = null,
                                tint = Color.White, modifier = Modifier.size(12.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}
