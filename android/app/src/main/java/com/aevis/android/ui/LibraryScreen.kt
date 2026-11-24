package com.aevis.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aevis.android.R
import com.aevis.android.core.I18n.tr
import com.aevis.android.data.Api
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 资源库（2026-11-16，129）。
 *
 * 只从**本地消息**里收集媒体：`img` 非空的图片 / 视频 / 文档，按时间倒序、同路径去重。
 * 不新建云端接口 —— 本地 `files/chatimg/` + 消息索引就够，飞行模式下照样能看。
 *
 * 分类靠扩展名判断（消息模型里没有 `kind` 字段）：
 * `.mp4/.mov/.m4v` → 视频；`.pdf/.doc/.docx/.txt/.zip/.apk/.ppt/.pptx/.xls/.xlsx` → 文档；其余 → 照片。
 */
private data class MediaItem(
    val pid: String,
    /** 在会话里的下标（删除时用）。*/
    val index: Int,
    /** 消息里存的路径（本地绝对路径或服务端相对路径）。*/
    val path: String,
    val kind: Int          // 0 照片 / 1 视频 / 2 文档
)

@Composable
fun LibraryScreen(onBack: () -> Unit) {
    val ink = MaterialTheme.colorScheme.onSurface
    val ctx = LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()

    var tab by remember { mutableIntStateOf(0) }
    var all by remember { mutableStateOf<List<MediaItem>?>(null) }
    var selectMode by remember { mutableStateOf(false) }
    var picked by remember { mutableStateOf<Set<Int>>(emptySet()) }
    var preview by remember { mutableStateOf<Int>(-1) }
    var confirmDelete by remember { mutableStateOf(false) }

    suspend fun reload() = withContext(Dispatchers.IO) {
        val out = ArrayList<MediaItem>()
        val seen = HashSet<String>()
        val convs = runCatching { Api.packConvs() }.getOrNull()
        convs?.keys()?.forEach { pid ->
            val msgs = Api.loadConv(pid)
            for (i in msgs.indices.reversed()) {
                val p = msgs[i].img
                if (p.isBlank()) continue
                val norm = p.substringAfterLast('/').lowercase()
                if (!seen.add(norm)) continue
                val ext = norm.substringAfterLast('.', "")
                val kind = when (ext) {
                    "mp4", "mov", "m4v", "webm" -> 1
                    "pdf", "doc", "docx", "txt", "zip", "apk", "ppt", "pptx", "xls", "xlsx" -> 2
                    else -> 0
                }
                out.add(MediaItem(pid, i, p, kind))
            }
        }
        all = out
    }

    LaunchedEffect(Unit) { reload() }

    BackHandler {
        when {
            preview >= 0 -> preview = -1
            selectMode -> { selectMode = false; picked = emptySet() }
            else -> onBack()
        }
    }

    val list = all
    val items = list?.filter { it.kind == tab } ?: emptyList()
    val counts = list?.let { l -> (0..2).map { k -> l.count { it.kind == k } } } ?: listOf(0, 0, 0)

    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        SubPageHeader(
            title = tr("资源库"),
            onBack = onBack,
            trailing = if (items.isNotEmpty()) {
                {
                    Text(
                        if (selectMode) tr("完成") else tr("选择"),
                        fontSize = 13.sp, fontWeight = FontWeight.Medium, color = V2.accent,
                        modifier = Modifier.tapable {
                            selectMode = !selectMode
                            if (!selectMode) picked = emptySet()
                        }.padding(horizontal = 4.dp, vertical = 4.dp)
                    )
                }
            } else null
        )

        // ---------- 三段 tab ----------
        Row(
            Modifier.fillMaxWidth().padding(horizontal = V2.gutter, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            val labels = listOf(
                tr("照片 %d", counts[0]),
                tr("视频 %d", counts[1]),
                tr("文档 %d", counts[2])
            )
            labels.forEachIndexed { i, label ->
                val on = tab == i
                Text(
                    label, fontSize = 12.5.sp,
                    fontWeight = if (on) FontWeight.Medium else FontWeight.Normal,
                    color = if (on) Color.White else ink.copy(alpha = 0.6f),
                    modifier = Modifier.clip(squircle(20.dp))
                        .background(if (on) V2.accent else ink.copy(alpha = 0.06f))
                        .tapable {
                            tab = i
                            picked = emptySet()
                        }
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                )
            }
        }

        when {
            list == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(tr("正在读取…"), fontSize = 12.sp, color = ink.copy(alpha = 0.4f))
            }
            items.isEmpty() -> EmptyLibrary(tab)
            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(4),
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = V2.gutter, end = V2.gutter, top = 8.dp, bottom = 24.dp
                ),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                items(items) { it ->
                    val idx = items.indexOf(it)
                    MediaCell(
                        item = it,
                        selected = idx in picked,
                        selectMode = selectMode,
                        onClick = {
                            if (selectMode) {
                                picked = if (idx in picked) picked - idx else picked + idx
                            } else preview = idx
                        },
                        onLong = {
                            selectMode = true
                            picked = picked + idx
                        }
                    )
                }
            }
        }

        // ---------- 多选删除条 ----------
        if (selectMode) {
            Row(
                Modifier.fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surface)
                    .navigationBarsPadding()
                    .padding(horizontal = V2.gutter, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    tr("已选 %d 项", picked.size), fontSize = 13.sp,
                    color = ink.copy(alpha = 0.6f)
                )
                Spacer(Modifier.weight(1f))
                Text(
                    tr("删除"), fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    color = if (picked.isEmpty()) ink.copy(alpha = 0.3f) else V2.alert,
                    modifier = Modifier.tapable(enabled = picked.isNotEmpty()) {
                        confirmDelete = true
                    }.padding(horizontal = 8.dp, vertical = 4.dp)
                )
            }
        }
    }

    // ---------- 全屏预览（可左右滑）----------
    if (preview >= 0 && preview < items.size) {
        val pager = rememberPagerState(initialPage = preview) { items.size }
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { preview = -1 },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)
        ) {
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                HorizontalPager(state = pager, modifier = Modifier.fillMaxSize()) { page ->
                    MediaFull(items[page].path)
                }
                Row(
                    Modifier.fillMaxWidth().statusBarsPadding().padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        tr("返回"), fontSize = 14.sp, color = Color.White,
                        modifier = Modifier.tapable { preview = -1 }
                            .padding(horizontal = 8.dp, vertical = 6.dp)
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        "${pager.currentPage + 1} / ${items.size}",
                        fontSize = 12.sp, color = Color.White.copy(alpha = 0.7f)
                    )
                }
            }
        }
    }

    // ---------- 删除确认 ----------
    if (confirmDelete) {
        val targets = picked.mapNotNull { items.getOrNull(it) }
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(tr("删除这 %d 项？", targets.size)) },
            text = {
                Text(
                    tr("只从聊天记录里移除这几条消息，手机相册里的原图不受影响。"),
                    fontSize = V2.sub, lineHeight = 20.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    scope.launch {
                        withContext(Dispatchers.IO) {
                            // 按会话分组删，删完各存一次（倒序删，下标不会串）
                            targets.groupBy { it.pid }.forEach { (pid, list) ->
                                val msgs = Api.loadConv(pid).toMutableList()
                                list.sortedByDescending { it.index }.forEach { it2 ->
                                    if (it2.index in msgs.indices) msgs.removeAt(it2.index)
                                }
                                Api.saveConv(pid, msgs)
                            }
                        }
                        picked = emptySet()
                        selectMode = false
                        reload()
                    }
                }) { Text(tr("删除"), color = V2.alert) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text(tr("取消")) }
            },
            containerColor = MaterialTheme.colorScheme.surface
        )
    }
}

/** 空态：居中线条猫 + 一句灰字（三个 tab 各一句）。*/
@Composable
private fun EmptyLibrary(tab: Int) {
    val ink = MaterialTheme.colorScheme.onSurface
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                painterResource(R.drawable.ic_cat_line), null,
                tint = ink.copy(alpha = 0.18f),
                modifier = Modifier.size(84.dp)
            )
            Spacer(Modifier.height(14.dp))
            Text(
                when (tab) {
                    1 -> tr("发过的视频会出现在这里")
                    2 -> tr("发过的文件会出现在这里")
                    else -> tr("发过的照片会出现在这里")
                },
                fontSize = 12.5.sp, color = ink.copy(alpha = 0.42f)
            )
        }
    }
}

/** 网格单元：本地路径直接 decode；服务端路径走 EmojiImage（自带加密缓存）。*/
@Composable
private fun MediaCell(
    item: MediaItem,
    selected: Boolean,
    selectMode: Boolean,
    onClick: () -> Unit,
    onLong: () -> Unit
) {
    Box(
        Modifier.aspectRatio(1f).clip(squircle(8.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
            .tapable(onLongClick = onLong) { onClick() }
    ) {
        if (item.kind == 0) {
            EmojiImage(
                url = item.path,
                modifier = Modifier.fillMaxSize(),
                radius = 8.dp,
                scale = ContentScale.Crop,
                placeholderBg = false
            )
        } else {
            Column(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Icon(
                    painterResource(
                        if (item.kind == 1) R.drawable.ic_att_camera else R.drawable.ic_att_file
                    ), null,
                    tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                    modifier = Modifier.size(22.dp)
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    if (item.kind == 1) tr("视频") else tr("文件"),
                    fontSize = 9.5.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f)
                )
            }
        }
        if (selectMode) {
            Box(
                Modifier.fillMaxSize()
                    .background(
                        if (selected) V2.accent.copy(alpha = 0.28f) else Color.Transparent
                    )
            )
            Box(
                Modifier.align(Alignment.TopEnd).padding(4.dp).size(18.dp)
                    .clip(androidx.compose.foundation.shape.CircleShape)
                    .background(
                        if (selected) V2.accent else Color.Black.copy(alpha = 0.28f)
                    ),
                contentAlignment = Alignment.Center
            ) {
                if (selected) {
                    Icon(
                        painterResource(R.drawable.ic_login_check), null,
                        tint = Color.White, modifier = Modifier.size(12.dp)
                    )
                }
            }
        }
    }
}

/** 全屏看一张（本地 decode / 网络缓存，失败给一句话）。*/
@Composable
private fun MediaFull(path: String) {
    val ctx = LocalContext.current.applicationContext
    val bmp by produceState<android.graphics.Bitmap?>(initialValue = null, path) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                if (isLocalFile(path)) {
                    android.graphics.BitmapFactory.decodeFile(localImagePath(path))
                } else {
                    val c = com.aevis.android.core.SecureCache.getBytes(ctx, "img:" + path)
                    if (c != null) android.graphics.BitmapFactory.decodeByteArray(c, 0, c.size)
                    else Api.fetchImage(path)
                }
            }.getOrNull()
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val b = bmp
        if (b != null) {
            Image(
                bitmap = b.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()
            )
        } else {
            Text(tr("加载中…"), fontSize = 12.sp, color = Color.White.copy(alpha = 0.5f))
        }
    }
}
