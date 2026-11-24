package com.aevis.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.GroupStore
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.PersonaLib
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/*
 * 群头像（2026-11-16，95）。
 *
 * 后端没有「群」这一层（见 `GroupStore`），所以群头像也不需要新的接口：
 * 走**已有的** `POST /v1/media` 上传，存**服务端相对路径**（`/v1/media/xxx.jpg`），
 * 跟人设头像同一个口径 —— `Avatar()` 既认本地路径也认相对路径，不用改渲染层。
 *
 * 上传前先**中心裁正方形 + 缩到 512**：
 *   · 群头像在界面上最大只显示 88dp，原图动辄几千万像素，直传又慢又浪费额度；
 *   · 不裁的话非正方形的图会被 `ContentScale.Crop` 二次裁，看着像随手截的。
 */

/** 相册里的图 → 512 方图 → 上传 → 服务端相对路径。失败返回 null。*/
internal suspend fun uploadGroupAvatar(ctx: android.content.Context, uri: Uri): String? =
    withContext(Dispatchers.IO) {
        val file = runCatching {
            val src = ctx.contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it)
            } ?: return@runCatching null
            val side = minOf(src.width, src.height)
            if (side <= 0) return@runCatching null
            val square = Bitmap.createBitmap(
                src, (src.width - side) / 2, (src.height - side) / 2, side, side
            )
            val scaled = Bitmap.createScaledBitmap(square, 512, 512, true)
            val f = File(ctx.cacheDir, "group_avatar_" + System.currentTimeMillis() + ".jpg")
            f.outputStream().use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 88, out)
            }
            f
        }.getOrNull() ?: return@withContext null
        try {
            Api.uploadImage(ctx, Uri.fromFile(file))
        } finally {
            runCatching { file.delete() }
        }
    }

/** 选完图先在本机解一张小的立刻显示，不用等网络往返。*/
internal suspend fun decodeGroupAvatarPreview(
    ctx: android.content.Context,
    uri: Uri
): Bitmap? = withContext(Dispatchers.IO) {
    runCatching {
        val src = ctx.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it)
        } ?: return@runCatching null
        val side = minOf(src.width, src.height)
        if (side <= 0) return@runCatching null
        val square = Bitmap.createBitmap(
            src, (src.width - side) / 2, (src.height - side) / 2, side, side
        )
        Bitmap.createScaledBitmap(square, 256, 256, true)
    }.getOrNull()
}

/**
 * 群头像方框（建群第二步 / 群资料页共用）。
 *
 * 没有图就显示群名首字（跟 `Avatar()` 的兜底一个观感），上传中转圈用"…"代替。
 */
@Composable
internal fun GroupAvatarPicker(
    avatar: String,
    preview: Bitmap?,
    name: String,
    size: Dp,
    uploading: Boolean,
    onPick: () -> Unit
) {
    Box(
        Modifier.size(size).clip(squircle(22.dp))
            .background(V2.accent.copy(alpha = 0.12f))
            .tapable(enabled = !uploading) { onPick() },
        contentAlignment = Alignment.Center
    ) {
        if (preview != null) {
            Image(
                bitmap = preview.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else if (avatar.isNotEmpty()) {
            // 已经有服务端地址（编辑已有群）：交给通用 Avatar 去下载 + 缓存
            Avatar(avatar, name, size)
        } else {
            Text(
                if (uploading) "…" else name.trim().take(1).ifEmpty { "群" },
                fontSize = 30.sp, color = V2.accent, fontWeight = FontWeight.Medium
            )
        }
    }
}

/** 二级页底部的主按钮（建群「下一步 / 创建群聊」、群资料「保存」共用）。*/
@Composable
internal fun GroupPrimaryButton(
    text: String,
    enabled: Boolean,
    hint: String? = null,
    onClick: () -> Unit
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Column(
        Modifier.fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = V2.gutter, vertical = 12.dp)
    ) {
        Box(
            Modifier.fillMaxWidth()
                .clip(squircle(16.dp))
                .background(if (enabled) V2.accent else ink.copy(alpha = 0.06f))
                .tapable(enabled = enabled) { onClick() }
                .padding(vertical = 15.dp),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text, fontSize = 16.sp, fontWeight = FontWeight.Medium,
                color = if (enabled) Color.White else ink.copy(alpha = 0.35f)
            )
        }
        if (!enabled && hint != null) {
            Spacer(Modifier.height(6.dp))
            Text(hint, fontSize = V2.micro, color = ink.copy(alpha = 0.42f))
        }
    }
}

/**
 * 群资料页（2026-11-16，95）。
 *
 * 只做两件事：换群头像、改群名。成员只读展示 —— 加人还是走群聊里的「加人」，
 * 那个页面（`GroupAddMemberScreen`）已经有「已在群里」的置灰逻辑，不在这里重做一遍。
 *
 * 保存走 `GroupStore.updateProfile`：**不刷 `updatedAt`**，
 * 否则改个头像这个群就跳到会话列表最前面。
 */
@Composable
fun GroupProfileScreen(gid: String, onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    val old = remember(gid) { GroupStore.find(gid) }
    var name by remember(gid) { mutableStateOf(old?.name.orEmpty()) }
    var avatar by remember(gid) { mutableStateOf(old?.avatar.orEmpty()) }
    var preview by remember(gid) { mutableStateOf<Bitmap?>(null) }
    var uploading by remember { mutableStateOf(false) }
    var members by remember(gid) { mutableStateOf<List<Api.Persona>>(emptyList()) }

    LaunchedEffect(gid) {
        members = withContext(Dispatchers.IO) {
            val all = runCatching { PersonaLib.localList() }.getOrElse { emptyList() }
            old?.memberIds.orEmpty().mapNotNull { id -> all.firstOrNull { it.id == id } }
        }
    }

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

    val canSave = name.trim().isNotEmpty() && !uploading

    fun save() {
        if (!canSave) return
        GroupStore.updateProfile(gid, name.trim(), avatar)
        android.widget.Toast.makeText(
            ctx, tr("已保存"), android.widget.Toast.LENGTH_SHORT
        ).show()
        onBack()
    }

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(
            title = "群资料",
            onBack = onBack,
            subtitle = "头像和群名都能自己改",
            trailing = {
                Text(
                    tr("保存"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                    color = if (canSave) V2.accent else ink.copy(alpha = 0.28f),
                    modifier = Modifier.clip(squircle(10.dp))
                        .tapable(enabled = canSave) { save() }
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                )
            }
        )

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())
        ) {
            Spacer(Modifier.height(6.dp))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter),
                verticalAlignment = Alignment.CenterVertically
            ) {
                GroupAvatarPicker(
                    avatar = avatar, preview = preview, name = name,
                    size = 88.dp, uploading = uploading
                ) {
                    picker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                    )
                }
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) {
                    Text(tr("群头像"), fontSize = V2.body, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(3.dp))
                    Text(
                        if (uploading) tr("正在上传…") else tr("点左边换一张，会自动裁成方图"),
                        fontSize = 11.5.sp, color = ink.copy(alpha = 0.55f),
                        lineHeight = 16.sp
                    )
                }
            }

            Spacer(Modifier.height(22.dp))
            Text(
                tr("群名"), fontSize = V2.micro, color = ink.copy(alpha = 0.42f),
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
                                tr("群名不能为空"), fontSize = V2.body,
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
                    tr("群名为空就存不了"), fontSize = V2.micro,
                    color = V2.alert.copy(alpha = 0.85f),
                    modifier = Modifier.padding(horizontal = V2.gutter)
                )
            }

            Spacer(Modifier.height(22.dp))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    tr("群成员"), fontSize = V2.sub, fontWeight = FontWeight.Medium,
                    color = ink.copy(alpha = 0.5f)
                )
                Spacer(Modifier.weight(1f))
                Text(
                    tr("%d 人", members.size), fontSize = V2.micro,
                    color = ink.copy(alpha = 0.4f)
                )
            }
            Spacer(Modifier.height(8.dp))
            V2Card(Modifier.padding(horizontal = V2.gutter), pad = 0.dp) {
                if (members.isEmpty()) {
                    Text(
                        tr("这个群里还没有人"), fontSize = V2.tiny,
                        color = ink.copy(alpha = 0.45f),
                        modifier = Modifier.padding(horizontal = V2.gutter, vertical = 16.dp)
                    )
                }
                members.forEachIndexed { i, p ->
                    if (i > 0) {
                        Box(
                            Modifier.fillMaxWidth().height(0.5.dp)
                                .background(ink.copy(alpha = 0.07f))
                        )
                    }
                    Row(
                        Modifier.fillMaxWidth()
                            .padding(horizontal = V2.gutter, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Avatar(p.avatar, p.name, 40.dp)
                        Spacer(Modifier.width(12.dp))
                        Text(
                            p.name, fontSize = V2.body, fontWeight = FontWeight.Medium,
                            maxLines = 1, overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
            Spacer(Modifier.height(28.dp))
        }
    }
}
