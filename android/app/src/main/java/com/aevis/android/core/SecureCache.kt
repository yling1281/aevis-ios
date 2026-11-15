package com.aevis.android.core

import android.content.Context
import java.io.File
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 本地缓存（**加密**）。
 *
 * 2026-11-14 用户：「你每次打，就是你要缓存啊，你要缓存在本地知道吗？
 * 你不要每次都要拉取，你要缓存在本地加密。」
 *
 * 存什么：头像 / 表情包封面（二进制）、人设列表 / 我的资料（JSON 字符串）。
 * 不存：音频流（那么大，而且本来就 CDN 直连）。
 *
 * 怎么加密：
 * - 密钥是**每台设备随机生成的 32 字节**，存在 SharedPreferences 里（不进代码、不进日志）。
 * - 每个文件 AES-256-CBC，随机 IV 放在文件头 16 字节，后面是密文。
 * - 换设备 / 清数据就解不开了，也不需要迁移 —— 都是缓存，丢了重新拉。
 *
 * ⚠️ 这不是"防逆向"级别的加密（密钥在本地，能 root 的照样能拿）。
 * 它的意义是：缓存文件直接拷出来、或者被别的 App 扫到，看不到明文。
 */
object SecureCache {

    private const val PREF = "aevis_cache_key"
    private const val KEY_NAME = "k"
    private const val DIR = "secure_cache"
    private const val IV_LEN = 16

    @Volatile
    private var key: ByteArray? = null

    private fun keyOf(ctx: Context): ByteArray {
        key?.let { return it }
        synchronized(this) {
            key?.let { return it }
            val sp = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            var raw = sp.getString(KEY_NAME, null)
            if (raw.isNullOrEmpty() || raw.length != 64) {
                val kb = ByteArray(32)
                SecureRandom().nextBytes(kb)
                raw = kb.joinToString("") { "%02x".format(it) }
                sp.edit().putString(KEY_NAME, raw).apply()
            }
            val kb = ByteArray(32)
            for (i in 0 until 32) {
                kb[i] = raw.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
            key = kb
            return kb
        }
    }

    private fun fileOf(ctx: Context, key: String): File {
        val dir = File(ctx.filesDir, DIR)
        if (!dir.exists()) dir.mkdirs()
        val name = android.util.Base64.encodeToString(
            key.toByteArray(Charsets.UTF_8),
            android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or
                android.util.Base64.NO_PADDING
        )
        return File(dir, name)
    }

    /** 写。失败就静默（缓存写不进去不该影响功能）。*/
    fun putBytes(ctx: Context, key: String, data: ByteArray) {
        runCatching {
            val iv = ByteArray(IV_LEN)
            SecureRandom().nextBytes(iv)
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(
                Cipher.ENCRYPT_MODE,
                SecretKeySpec(keyOf(ctx), "AES"),
                IvParameterSpec(iv)
            )
            val enc = cipher.doFinal(data)
            fileOf(ctx, key).writeBytes(iv + enc)
        }
    }

    fun getBytes(ctx: Context, key: String): ByteArray? {
        return runCatching {
            val f = fileOf(ctx, key)
            if (!f.exists() || f.length() <= IV_LEN) return null
            val all = f.readBytes()
            val iv = all.copyOfRange(0, IV_LEN)
            val body = all.copyOfRange(IV_LEN, all.size)
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(keyOf(ctx), "AES"),
                IvParameterSpec(iv)
            )
            cipher.doFinal(body)
        }.getOrNull()
    }

    /** 字符串缓存（JSON 之类）。*/
    fun putText(ctx: Context, key: String, text: String) =
        putBytes(ctx, key, text.toByteArray(Charsets.UTF_8))

    fun getText(ctx: Context, key: String): String? =
        getBytes(ctx, key)?.toString(Charsets.UTF_8)

    /** 缓存多大（字节），「关于」页可以显示。*/
    fun size(ctx: Context): Long {
        val dir = File(ctx.filesDir, DIR)
        if (!dir.exists()) return 0
        return dir.listFiles()?.sumOf { it.length() } ?: 0
    }

    fun clear(ctx: Context) {
        runCatching { File(ctx.filesDir, DIR).listFiles()?.forEach { it.delete() } }
    }
}
