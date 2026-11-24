package com.aevis.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.core.I18n.tr
import com.aevis.android.core.LocalPersonaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 创建 / 编辑人设（2026-11-16）。
 *
 * 用户的原话：「我可以自己创建角色，名字、头像、性格、说话风格都能自己写」，
 * 以及「下载下来的角色我要能改」。两件事的字段是**完全一样**的，
 * 所以合成一个页面：`existingId == null` 就是创建，否则就是编辑。
 * 两个页面各写一遍的话，改一个字段得改两处，早晚会不一致。
 *
 * 边界（和 `LocalPersonaStore` 的约定保持一致）：
 *   · 创建走 `save(origin = "created")`，id 用 `newId()`（`local_<时间戳>`，撞不到广场的 id）；
 *   · 编辑只 `update` **本地这一份**，广场的原始数据一个字节都不动；
 *   · 头像存的是 `filesDir/personas/<id>.jpg` 的**绝对路径**，
 *     `Avatar()` 里加了本地路径分支，所以列表/聊天页能直接显示。
 */
@Composable
fun PersonaEditScreen(
    existingId: String?,
    onBack: () -> Unit,
    onSaved: (String) -> Unit
) {
    val ctx = LocalContext.current
    val ink = MaterialTheme.colorScheme.onSurface
    val scope = rememberCoroutineScope()

    // id 只生成一次：头像文件名要用它，重组时重新生成会把刚存的图变成孤儿文件
    val id = remember(existingId) { existingId ?: LocalPersonaStore.newId() }
    // 预填用「进页面那一刻」的本地数据 —— 不跟着列表刷新走，免得边填边被覆盖
    val old = remember(id) { LocalPersonaStore.find(id) }

    var name by remember(id) { mutableStateOf(old?.name.orEmpty()) }
    var avatar by remember(id) { mutableStateOf(old?.avatar.orEmpty()) }
    var persona by remember(id) { mutableStateOf(old?.persona.orEmpty()) }
    // 高级设定展开态（2026-11-16，94）
    var advOpen by remember(id) { mutableStateOf(false) }
    var style by remember(id) { mutableStateOf(old?.style.orEmpty()) }
    var importing by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }

    /**
     * 相册选图。用 `PickVisualMedia`（系统照片选择器）而不是 `GetContent`：
     * 前者不申请存储权限、给的是单张图，minSdk 26 上会自动退化成系统文档选择器。
     */
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult   // 用户点了取消，什么都不做
        importing = true
        note = ""
        scope.launch {
            // 解码 + 缩放 + 压 JPEG 都在 IO 上做 —— 原图动辄几千万像素，主线程会卡出 ANR
            val path = withContext(Dispatchers.IO) { importAvatar(ctx, uri, id) }
            importing = false
            if (path.isEmpty()) {
                note = tr("这张图读不出来，换一张试试")
            } else {
                avatar = path
            }
        }
    }

    fun save() {
        val n = name.trim()
        if (n.isEmpty()) return
        if (old == null) {
            // 新建（或者这条本地记录已经被删了）：整条写进去
            LocalPersonaStore.save(
                LocalPersonaStore.Item(
                    id = id,
                    name = n,
                    avatar = avatar,
                    persona = persona.trim(),
                    style = style.trim(),
                    origin = "created",
                    updatedAt = 0L   // save() 内部会补成当前时间
                )
            )
        } else {
            // 编辑：只动本地这一份，广场的原始数据不碰
            LocalPersonaStore.update(
                id,
                name = n,
                avatar = avatar,
                persona = persona.trim(),
                style = style.trim()
            )
        }
        onSaved(id)
    }

    val canSave = name.trim().isNotEmpty()

    BackHandler { onBack() }

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(
            title = if (existingId == null) tr("创建人设") else tr("编辑角色"),
            onBack = onBack,
            subtitle = if (existingId == null) tr("名字、头像、性格都能自己写")
            else tr("改的是本地这一份"),
            trailing = {
                // 顶栏也给一个保存 —— 长表单滚到一半时不用滑到底部
                Text(
                    tr("保存"),
                    fontSize = V2.sub,
                    fontWeight = FontWeight.Medium,
                    color = if (canSave) V2.accent else ink.copy(alpha = 0.28f),
                    modifier = Modifier
                        .clip(squircle(10.dp))
                        .tapable(enabled = canSave) { save() }
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                )
            }
        )

        Column(
            Modifier.fillMaxWidth().weight(1f)
                .verticalScroll(rememberScrollState())
        ) {
            // ---------- 头像 ----------
            Row(
                Modifier.fillMaxWidth().padding(horizontal = V2.gutter),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val bmp = rememberLocalBitmap(avatar)
                Box(
                    Modifier.size(88.dp).clip(squircle(20.dp))
                        .background(V2.accent.copy(alpha = 0.12f))
                        .tapable {
                            if (!importing) {
                                picker.launch(
                                    PickVisualMediaRequest(
                                        ActivityResultContracts.PickVisualMedia.ImageOnly
                                    )
                                )
                            }
                        },
                    contentAlignment = Alignment.Center
                ) {
                    if (bmp != null) {
                        Image(
                            bitmap = bmp.asImageBitmap(), contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize()
                        )
                    } else {
                        // 没选图就显示名字首字 —— 跟 `Avatar()` 的兜底保持一个观感
                        Text(
                            if (importing) "…" else name.trim().take(1).ifEmpty { "＋" },
                            fontSize = 30.sp, color = V2.accent,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        if (importing) tr("正在处理…") else tr("点头像换一张"),
                        fontSize = V2.body, fontWeight = FontWeight.Medium
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(
                        tr("从相册选，会缩到 512 存进手机里"),
                        fontSize = V2.micro, color = ink.copy(alpha = 0.42f)
                    )
                }
            }

            Spacer(Modifier.height(20.dp))

            // ---------- 名字（必填）----------
            FieldLabel(tr("名字"))
            FieldBox(
                value = name, onValueChange = { name = it },
                placeholder = tr("它叫什么"),
                singleLine = true, minHeight = 22.dp
            )

            // ---------- 性格（2026-11-16，94：正文 / 系统设定分开显示）----------
            FieldLabel(tr("性格"))
            val split = remember(persona) { splitPersona(persona) }
            FieldBox(
                // 只编辑"正文"那部分；改动后用 mergePersona 把系统设定按原下标拼回去
                value = split.body,
                onValueChange = { newBody ->
                    persona = mergePersona(newBody, split.advancedParas, split.advancedIdx)
                },
                placeholder = if (split.body.isBlank() && split.advanced.isNotBlank())
                    tr("（这个人设只有系统设定，没有正文）")
                else tr("例如：外冷内热，说话带刺但会默默关心人"),
                singleLine = false, minHeight = 132.dp   // 6 行
            )

            // 高级设定：默认收起，展开只读（保存时原样拼回，用户改不到原文）
            if (split.advanced.isNotBlank()) {
                Spacer(Modifier.height(6.dp))
                Text(
                    tr("高级设定（点击展开）"), fontSize = V2.micro, color = V2.accent,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 4.dp)
                        .tapable { advOpen = !advOpen }
                )
                if (advOpen) {
                    Text(
                        split.advanced,
                        fontSize = 11.sp, lineHeight = 17.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                        modifier = Modifier.padding(horizontal = V2.gutter, vertical = 2.dp)
                    )
                }
            }

            // ---------- 说话风格 ----------
            FieldLabel(tr("说话风格"))
            FieldBox(
                value = style, onValueChange = { style = it },
                placeholder = tr("例如：句子很短，爱用反问，偶尔冒一句方言"),
                singleLine = false, minHeight = 88.dp    // 4 行
            )

            if (note.isNotEmpty()) {
                Text(
                    note, fontSize = V2.micro, color = V2.alert,
                    modifier = Modifier.padding(horizontal = V2.gutter, vertical = 6.dp)
                )
            }

            Spacer(Modifier.height(24.dp))
        }

        // ---------- 底部主按钮 ----------
        Column(
            Modifier.fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = V2.gutter, vertical = 12.dp)
        ) {
            Row(
                Modifier.fillMaxWidth()
                    .clip(squircle(16.dp))
                    .background(if (canSave) V2.accent else ink.copy(alpha = 0.06f))
                    .tapable(enabled = canSave) { save() }
                    .padding(vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    if (importing) tr("正在处理头像…") else tr("保存"),
                    fontSize = 16.sp, fontWeight = FontWeight.Medium,
                    color = if (canSave) Color.White else ink.copy(alpha = 0.35f)
                )
            }
            if (!canSave) {
                Spacer(Modifier.height(6.dp))
                Text(
                    tr("名字填了才能保存"),
                    fontSize = V2.micro, color = ink.copy(alpha = 0.42f),
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }
    }
}

/** 字段标题（比正文小一号，浅色，跟 iOS 的表单标签一个观感）。*/
@Composable
private fun FieldLabel(text: String) {
    Text(
        text, fontSize = V2.micro,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.42f),
        modifier = Modifier.padding(start = V2.gutter, end = V2.gutter, top = 14.dp, bottom = 7.dp)
    )
}

/**
 * 表单里的一个输入框。
 *
 * 用 `BasicTextField` 而不是 `OutlinedTextField`：后者自带 Material 的
 * 边框 / 浮动标签 / 焦点光晕，一眼就是安卓原生表单，跟这套 V2 不搭。
 */
@Composable
private fun FieldBox(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    singleLine: Boolean,
    minHeight: Dp
) {
    val ink = MaterialTheme.colorScheme.onSurface
    Box(
        Modifier.fillMaxWidth()
            .padding(horizontal = V2.gutter)
            .clip(squircle(14.dp))
            .background(ink.copy(alpha = 0.05f))
            .padding(horizontal = 13.dp, vertical = 11.dp)
    ) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = singleLine,
            textStyle = TextStyle(fontSize = V2.body, color = ink),
            cursorBrush = SolidColor(V2.accent),
            modifier = Modifier.fillMaxWidth()
                .heightIn(min = minHeight)
                // 多行框给固定高度（= 6 行 / 4 行）—— 内容超了 BasicTextField 自己会滚，
                // 不用外面再套 verticalScroll（嵌套滚动在输入框里很难用）
                .then(if (singleLine) Modifier else Modifier.height(minHeight)),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        Text(
                            placeholder, fontSize = V2.body,
                            color = ink.copy(alpha = 0.3f)
                        )
                    }
                    inner()
                }
            }
        )
    }
}

/**
 * 本地图片路径 → Bitmap（IO 线程解码）。
 *
 * 为什么不复用 `Avatar()`：这里要的是**方形**（编辑页的头像位是圆角方块），
 * 而且刚选完图要立刻刷新，走一遍网络缓存那套反而绕。
 */
@Composable
private fun rememberLocalBitmap(path: String): Bitmap? {
    var bmp by remember(path) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(path) {
        bmp = if (path.isEmpty()) null else withContext(Dispatchers.IO) {
            runCatching {
                // 2026-11-16：下载来的角色，它的头像还是**服务端相对路径** `/v1/media/…`，
                // 这种不能 decodeFile（会 null → 编辑页显示首字母）。
                // 本地文件才读盘，其余走网络（跟 `Avatar()` 同一套判断，别各写一套）。
                if (isLocalFile(path)) BitmapFactory.decodeFile(localImagePath(path))
                else com.aevis.android.data.Api.fetchImage(path)
            }.getOrNull()
        }
    }
    return bmp
}

/**
 * 相册里选的图 → 复制进 `filesDir/personas/<id>.jpg`，返回**绝对路径**。
 *
 * 为什么要复制而不是直接存 `content://`：系统给的 Uri 只在本次授权内有效，
 * 用户重启 App 或清了最近任务之后就读不到了 —— 头像会变成首字母。
 * 复制进自己的目录才是真的"存在手机里"。
 *
 * 尺寸：最长边 512px、JPEG 88 —— 头像最大也就显示到 88dp，
 * 512 已经够 3 倍屏；再大只是白占空间、每次列表滚动都要多解一遍。
 */
private fun importAvatar(ctx: Context, uri: Uri, id: String): String {
    return try {
        val dir = java.io.File(ctx.filesDir, "personas")
        if (!dir.exists()) dir.mkdirs()
        val out = java.io.File(dir, "$id.jpg")

        // 第一遍只读尺寸：原图可能有 8000px，直接整张解码会 OOM（低端机 100% 崩）
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        ctx.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        }
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        var sample = 1
        while (longest > 0 && longest / sample > 1024) sample *= 2

        // 第二遍按采样率解码（内存里最大 1024px）
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val src = ctx.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts)
        } ?: return ""

        // 再精确缩到最长边 512（采样率只能按 2 的幂降，剩下的用 createScaledBitmap 补）
        val maxSide = maxOf(src.width, src.height)
        val bmp: Bitmap = if (maxSide > 512) {
            val s = 512f / maxSide.toFloat()
            Bitmap.createScaledBitmap(
                src,
                (src.width * s).toInt().coerceAtLeast(1),
                (src.height * s).toInt().coerceAtLeast(1),
                true
            )
        } else {
            src
        }

        out.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 88, it) }
        // 缩放出来的中间图已经没用了，立刻放掉（不依赖 GC，低端机上差别很明显）
        if (bmp !== src) bmp.recycle()
        src.recycle()
        out.absolutePath
    } catch (e: Exception) {
        ""
    }
}
