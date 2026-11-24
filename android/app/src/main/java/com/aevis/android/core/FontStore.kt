package com.aevis.android.core

import android.content.Context
import android.graphics.Typeface
import android.net.Uri
import java.io.File

/**
 * 自定义字体（2026-11-15）。
 *
 * 用户不要内置字体（省体积、避开授权），改成「去开源站下载 → 回来导入」。
 *
 * 存哪儿：App 私有目录 `files/fonts/custom.ttf`，卸载一起带走，不污染相册/下载。
 * 校验：只认真正的字体文件（看文件头魔数），避免用户选错文件导致界面崩掉 ——
 * 一个坏字体让整个列表渲染失败，排查起来非常难。
 */
object FontStore {

    private const val DIR = "fonts"
    private const val NAME = "custom.ttf"
    private const val PREF = "aevis_font"
    private const val KEY_LABEL = "label"

    private var ctxRef: Context? = null

    fun init(ctx: Context) {
        ctxRef = ctx.applicationContext
    }

    private fun c() = ctxRef!!
    private fun dir() = File(c().filesDir, DIR).apply { if (!exists()) mkdirs() }

    fun currentFile(ctx: Context): File = File(File(ctx.filesDir, DIR), NAME)

    fun currentFile(): File = File(dir(), NAME)

    fun currentName(): String {
        val f = currentFile()
        if (!f.exists()) return "系统默认"
        return c().getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getString(KEY_LABEL, "")?.takeIf { it.isNotBlank() } ?: "自定义字体"
    }

    /** 日记页拿它渲染；没有就用 null（继承系统字体）。*/
    fun typeface(): Typeface? {
        val f = currentFile()
        if (!f.exists() || f.length() < 1024) return null
        return runCatching { Typeface.createFromFile(f) }.getOrNull()
    }

    /**
     * 从系统文件选择器的 Uri 导入。返回 true 表示成功。
     *
     * 先落到临时文件，验完魔数再改名 —— 直接写目标路径的话，
     * 选错文件会把原来能用的字体也覆盖掉。
     */
    fun import(ctx: Context, uri: Uri): Boolean {
        return runCatching {
            val tmp = File(dir(), "importing.tmp")
            ctx.contentResolver.openInputStream(uri)?.use { ins ->
                tmp.outputStream().use { outs -> ins.copyTo(outs) }
            } ?: return false
            if (!looksLikeFont(tmp)) {
                tmp.delete()
                return false
            }
            val dst = currentFile(ctx)
            if (dst.exists()) dst.delete()
            if (!tmp.renameTo(dst)) {
                tmp.copyTo(dst, overwrite = true)
                tmp.delete()
            }
            val label = queryName(ctx, uri) ?: "自定义字体"
            ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
                .edit().putString(KEY_LABEL, label).apply()
            true
        }.getOrDefault(false)
    }

    fun reset(ctx: Context) {
        runCatching { currentFile(ctx).delete() }
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().clear().apply()
    }

    /** 字体文件头：ttf 从 0x00010000 或 "true"/"ttcf" 开头，otf 是 "OTTO"。*/
    private fun looksLikeFont(f: File): Boolean {
        if (f.length() < 1024) return false
        val head = ByteArray(4)
        runCatching {
            f.inputStream().use { it.read(head) }
        }.getOrElse { return false }
        val b0 = head[0].toInt() and 0xFF
        val b1 = head[1].toInt() and 0xFF
        val b2 = head[2].toInt() and 0xFF
        val b3 = head[3].toInt() and 0xFF
        // 0x00010000
        if (b0 == 0 && b1 == 0 && b2 == 1 && b3 == 0) return true
        val s = String(head, Charsets.US_ASCII)
        return s == "OTTO" || s == "true" || s == "ttcf"
    }

    private fun queryName(ctx: Context, uri: Uri): String? = runCatching {
        ctx.contentResolver.query(uri, null, null, null, null)?.use { cur ->
            val i = cur.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (i >= 0 && cur.moveToFirst()) cur.getString(i) else null
        }
    }.getOrNull()
}
