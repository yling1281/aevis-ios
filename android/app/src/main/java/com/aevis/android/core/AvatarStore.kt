package com.aevis.android.core

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.File

/**
 * 人设头像的本地覆盖（2026-11-15）。
 *
 * 用户：「好像并不能修改对方的这个头像之类的，这个是可以自定义修改的」。
 *
 * 服务端没有「改人设头像」的接口（`persona_public` 只在创建时写 avatar_url），
 * 所以先做本地覆盖：用户换了头像 → 存到 `files/avatars/<pid>.jpg` → 界面优先读它。
 * 换设备会丢，但至少功能是通的。等服务端加了接口再补上传。
 *
 * 注意：**不覆盖服务端原图**，原图继续走 SecureCache，这里只是盖在上面一层。
 */
object AvatarStore {

    private var ctxRef: Context? = null

    fun init(ctx: Context) {
        ctxRef = ctx.applicationContext
    }

    private fun dir(): File {
        val d = File(ctxRef!!.filesDir, "avatars")
        if (!d.exists()) d.mkdirs()
        return d
    }

    /**
     * **统一读取点**（2026-11-17，176）。
     *
     * 本地有头像文件就用本地绝对路径，否则回落到服务端给的 remote。
     * 之前各处直接读 `me.avatar`（服务端字段），所以「我」页换了头像，
     * 聊天页我方气泡还是老图 —— 全部改成走这个函数即可一致。
     * ⚠️ 只影响**读取**，不影响上传。
     */
    fun displayOf(pid: String, remote: String?): String {
        val f = runCatching { file(pid) }.getOrNull()
        return if (f != null && f.exists() && f.length() > 64) f.absolutePath
        else remote.orEmpty()
    }

    fun file(pid: String): File = File(dir(), pid + ".jpg")

    fun has(pid: String): Boolean = pid.isNotBlank() && file(pid).exists()

    /** 读本地头像；没有返回 null。*/
    fun load(pid: String): Bitmap? {
        if (pid.isBlank()) return null
        val f = file(pid)
        if (!f.exists() || f.length() < 64) return null
        // R-03：512 采样
        return com.aevis.android.data.decodeSampledFile(f.absolutePath, 512, 512)
    }

    /**
     * 从相册选的 Uri 导入。成功返回 true。
     *
     * 统一压成 512×512 的 JPEG（头像用不到更大，太大拖慢列表滚动），
     * 先写临时文件再改名，避免写一半失败把原来的头像弄坏。
     */
    fun import(ctx: Context, pid: String, uri: Uri): Boolean {
        if (pid.isBlank()) return false
        return runCatching {
            val src = ctx.contentResolver.openInputStream(uri)?.use { ins ->
                com.aevis.android.data.decodeSampled(ins, 512, 512)
            } ?: return false

            // 居中裁成正方形，再缩到 512
            val side = minOf(src.width, src.height)
            val x = (src.width - side) / 2
            val y = (src.height - side) / 2
            val square = Bitmap.createBitmap(src, x, y, side, side)
            val out = Bitmap.createScaledBitmap(square, 512, 512, true)

            val tmp = File(dir(), pid + ".tmp")
            tmp.outputStream().use { os ->
                out.compress(Bitmap.CompressFormat.JPEG, 88, os)
            }
            val dst = file(pid)
            if (dst.exists()) dst.delete()
            if (!tmp.renameTo(dst)) {
                tmp.copyTo(dst, overwrite = true)
                tmp.delete()
            }
            true
        }.getOrDefault(false)
    }

    /** 恢复成服务端原头像。*/
    fun reset(pid: String) {
        runCatching { file(pid).delete() }
    }
}
