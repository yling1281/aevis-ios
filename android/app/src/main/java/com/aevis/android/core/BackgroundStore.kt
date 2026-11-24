package com.aevis.android.core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import java.io.File

/**
 * 聊天背景（2026-11-15）。
 *
 * 用户要「自定义背景图、整体背景图、聊天记录背景图」，还要模糊和动效。
 *
 * 存法：图复制到 `files/bg/chat.jpg`（不占相册、卸载一起走）。
 * 渲染：`renderBg()` 是 @Composable，聊天页和设置页共用同一套，改一处两边都变。
 *
 * ⚠️ `Modifier.blur` 在 Android 12 以下**不生效**（不会崩，只是没效果），
 *    所以低版本会自动多叠一层半透明遮罩来凑视觉，不然背景太花看不清字。
 */
object BackgroundStore {

    private var ctxRef: Context? = null

    fun init(ctx: Context) {
        ctxRef = ctx.applicationContext
    }

    private fun dir(): File {
        val d = File(ctxRef!!.filesDir, "bg")
        if (!d.exists()) d.mkdirs()
        return d
    }

    private fun file(): File = File(dir(), "chat.jpg")

    fun has(): Boolean = file().exists()

    /** 从相册导入，压到 1080 宽（够用，太大拖慢滚动）。*/
    fun import(ctx: Context, uri: Uri): Boolean = runCatching {
        // R-04：背景是整屏大图，先按屏宽采样再压缩
        val (sw, sh) = com.aevis.android.data.screenSize(ctx)
        val src = ctx.contentResolver.openInputStream(uri)?.use {
            com.aevis.android.data.decodeSampled(it, sw, sh)
        } ?: return false
        val w = 1080
        val h = (src.height * (w.toFloat() / src.width)).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(src, w, h, true)
        val tmp = File(dir(), "chat.tmp")
        tmp.outputStream().use { os ->
            scaled.compress(Bitmap.CompressFormat.JPEG, 82, os)
        }
        val dst = file()
        if (dst.exists()) dst.delete()
        if (!tmp.renameTo(dst)) {
            tmp.copyTo(dst, overwrite = true)
            tmp.delete()
        }
        true
    }.getOrDefault(false)

    fun clear(ctx: Context) {
        runCatching { file().delete() }
    }

    fun load(): Bitmap? {
        val f = file()
        if (!f.exists() || f.length() < 128) return null
        // R-04：按屏幕尺寸采样
        val (sw, sh) = com.aevis.android.data.screenSize(ctxRef!!)
        return com.aevis.android.data.decodeSampledFile(f.absolutePath, sw, sh)
    }

    /** 渐变预设（都是「浅色为主」，保证黑字能看清）。*/
    val presets: List<List<Color>> = listOf(
        listOf(Color(0xFFF6F3EC), Color(0xFFEDE6F5)),
        listOf(Color(0xFFE8F0FA), Color(0xFFF6F3EC)),
        listOf(Color(0xFFFDF0F4), Color(0xFFF3F0FA)),
        listOf(Color(0xFF1F1D2B), Color(0xFF2E2A3D)),
        listOf(Color(0xFFEAF4EC), Color(0xFFF0F0E6)),
        listOf(Color(0xFFFFF4E6), Color(0xFFF5EAE6))
    )

    /**
     * 渲染背景。`ver` 只在换图时变，用来触发 recomposition。
     */
    @Composable
    fun renderBg(
        ctx: Context,
        kind: Int,        // 0 纯色 / 1 图片 / 2 渐变
        preset: Int,
        blur: Int,
        dim: Int,
        ver: Int,
        modifier: Modifier = Modifier
    ) {
        Box(modifier) {
            when (kind) {
                1 -> {
                    val bmp = remember(ver) { load() }
                    if (bmp != null) {
                        Image(
                            bitmap = bmp.asImageBitmap(),
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize().then(
                                if (blur > 0) Modifier.blur(blur.dp) else Modifier
                            )
                        )
                    } else {
                        // 没选到图就退回页面底色，别留一片白（也别写死米白 —— 深色主题下会白到看不见字）
                        Box(
                            Modifier.fillMaxSize()
                                .background(androidx.compose.material3.MaterialTheme.colorScheme.background)
                        )
                    }
                }
                2 -> {
                    val c = presets.getOrElse(preset) { presets[0] }
                    Box(
                        Modifier.fillMaxSize()
                            .background(Brush.linearGradient(c))
                    )
                }
                // 纯色（默认）：**跟主题走**（2026-11-16）。
                // 以前写死 `Color(0xFFF6F3EC)`（米白），结果深色主题下聊天页是米白底 +
                // 半透明白气泡 + 白字 —— 白底白字，等于没做深色模式。
                else -> Box(
                    Modifier.fillMaxSize()
                        .background(androidx.compose.material3.MaterialTheme.colorScheme.background)
                )
            }
            // 遮罩：图太亮时压暗，文字才看得清。
            // 低版本 blur 无效，这里多压一点（+6%）补偿。
            if (dim > 0) {
                Box(
                    Modifier.fillMaxSize()
                        .background(Color.Black.copy(alpha = (dim / 100f).coerceIn(0f, 0.6f)))
                )
            }
        }
    }
}
