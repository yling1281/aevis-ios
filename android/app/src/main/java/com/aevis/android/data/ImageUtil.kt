package com.aevis.android.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

/**
 * 带采样的位图解码（2026-11-16，R-02/03/04 修复）。
 *
 * 以前这些地方都是 `BitmapFactory.decodeStream(...)` 直接解全尺寸：
 * 一张 4000px 的原图 ≈ 48MB，列表里几十张足以 OOM 或疯狂 GC。
 * 这里先读 bounds 算 `inSampleSize`（2 的幂），再解第二遍。
 *
 * ⚠️ 必须把整段 `readBytes()` 出来再解两次 —— `InputStream` 不能回绕，
 * 直接复用同一个流第二次 decode 会拿到 null。
 */
fun decodeSampled(input: InputStream, reqW: Int, reqH: Int): Bitmap? = runCatching {
    val bytes = input.readBytes()
    if (bytes.isEmpty()) return null
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val w = bounds.outWidth
    val h = bounds.outHeight
    if (w <= 0 || h <= 0) return null

    val tw = if (reqW > 0) reqW else w
    val th = if (reqH > 0) reqH else h
    var s = 1
    while (w / (s * 2) >= tw && h / (s * 2) >= th) s *= 2

    BitmapFactory.decodeByteArray(
        bytes, 0, bytes.size,
        BitmapFactory.Options().apply { inSampleSize = s }
    )
}.getOrNull()

/** 文件版（`decodeFile` 的几个调用点都换到这里）。*/
fun decodeSampledFile(path: String, reqW: Int, reqH: Int): Bitmap? = runCatching {
    File(path).let { f ->
        if (!f.exists()) return null
        FileInputStream(f).use { decodeSampled(it, reqW, reqH) }
    }
}.getOrNull()

/** 屏幕尺寸（背景图按它采样）。*/
fun screenSize(ctx: android.content.Context): Pair<Int, Int> = runCatching {
    val dm = ctx.resources.displayMetrics
    dm.widthPixels to dm.heightPixels
}.getOrDefault(1080 to 1920)
