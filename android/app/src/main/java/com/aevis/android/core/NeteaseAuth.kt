package com.aevis.android.core

import android.util.Base64
import org.json.JSONObject
import java.math.BigInteger
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 网易云 weapi 加密 + 扫码登录（2026-11-14）。
 *
 * 移植自 iOS 的 `NeteaseCrypto.swift` / `NeteaseQRLogin.swift`。
 * 算法没得选，网易云只认这一套：
 *
 *   1. 随机 16 位 base62 串当 secretKey
 *   2. AES-128-CBC(明文, presetKey)                  → base64
 *   3. AES-128-CBC(第 2 步的 base64, secretKey)      → params
 *   4. encSecKey = (倒序 secretKey 的十六进制) ^ 65537 mod N，左补 0 到 256 位
 *
 * Swift 那边自己写了套大数（Big），Kotlin 直接用 `java.math.BigInteger`。
 */
object NeteaseAuth {

    private const val PRESET = "0CoJUm6Qyw8W8jud"
    private const val IV = "0102030405060708"
    private const val B62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    private const val UA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    private val MODULUS = BigInteger(
        "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725" +
            "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ec" +
            "bda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d8" +
            "13cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7", 16
    )
    private val EXP = BigInteger.valueOf(65537)

    // ---------------- 加密 ----------------

    private fun randomKey(): String {
        val r = SecureRandom()
        val sb = StringBuilder(16)
        repeat(16) { sb.append(B62[r.nextInt(B62.length)]) }
        return sb.toString()
    }

    private fun aes(text: String, key: String): String {
        val c = Cipher.getInstance("AES/CBC/PKCS5Padding")
        c.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(key.toByteArray(Charsets.UTF_8), "AES"),
            IvParameterSpec(IV.toByteArray(Charsets.UTF_8))
        )
        return Base64.encodeToString(c.doFinal(text.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    private fun encSecKey(secret: String): String {
        val hex = secret.reversed().toByteArray(Charsets.UTF_8)
            .joinToString("") { "%02x".format(it) }
        val enc = BigInteger(hex, 16).modPow(EXP, MODULUS)
        return enc.toString(16).padStart(256, '0')
    }

    fun weapi(json: String): Pair<String, String> {
        val secret = randomKey()
        val first = aes(json, PRESET)
        val second = aes(first, secret)
        return second to encSecKey(secret)
    }

    // ---------------- 请求 ----------------

    private data class Resp(val code: Int, val text: String, val cookie: String)

    private fun post(path: String, params: JSONObject, cookie: String = ""): Resp {
        val (p, k) = weapi(params.toString())
        val body = "params=" + java.net.URLEncoder.encode(p, "UTF-8") +
            "&encSecKey=" + java.net.URLEncoder.encode(k, "UTF-8")
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL("https://music.163.com" + path).openConnection() as HttpURLConnection)
                .apply {
                    requestMethod = "POST"
                    connectTimeout = 10000
                    readTimeout = 15000
                    doOutput = true
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    setRequestProperty("User-Agent", UA)
                    setRequestProperty("Referer", "https://music.163.com/")
                    if (cookie.isNotEmpty()) setRequestProperty("Cookie", cookie)
                }
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() } ?: ""
            val ck = conn.headerFields
                .filterKeys { it != null && it.equals("Set-Cookie", true) }
                .values.flatten()
                .mapNotNull { it.substringBefore(";").takeIf { s -> s.contains("=") } }
                .joinToString("; ")
            Resp(code, text, ck)
        } catch (e: Exception) {
            Resp(-1, e.message ?: "网络异常", "")
        } finally {
            conn?.disconnect()
        }
    }

    // ---------------- Cookie 存取 ----------------

    private const val PREF = "aevis_netease"
    private const val KEY_COOKIE = "cookie"
    private const val KEY_UID = "uid"
    private const val KEY_NAME = "name"

    fun cookie(ctx: android.content.Context): String =
        ctx.getSharedPreferences(PREF, android.content.Context.MODE_PRIVATE)
            .getString(KEY_COOKIE, "").orEmpty()

    fun loggedIn(ctx: android.content.Context): Boolean = cookie(ctx).contains("MUSIC_U=")

    fun saveLogin(ctx: android.content.Context, cookie: String, uid: String, name: String) {
        ctx.getSharedPreferences(PREF, android.content.Context.MODE_PRIVATE).edit()
            .putString(KEY_COOKIE, cookie)
            .putString(KEY_UID, uid)
            .putString(KEY_NAME, name)
            .apply()
    }

    fun uid(ctx: android.content.Context): String =
        ctx.getSharedPreferences(PREF, android.content.Context.MODE_PRIVATE)
            .getString(KEY_UID, "").orEmpty()

    fun nickName(ctx: android.content.Context): String =
        ctx.getSharedPreferences(PREF, android.content.Context.MODE_PRIVATE)
            .getString(KEY_NAME, "").orEmpty()

    fun logout(ctx: android.content.Context) {
        ctx.getSharedPreferences(PREF, android.content.Context.MODE_PRIVATE).edit().clear().apply()
    }

    /** 登录后查一次自己的 uid / 昵称，用来显示「已登录：xxx」。*/
    fun fetchAccount(ctx: android.content.Context): Pair<String, String>? {
        val ck = cookie(ctx)
        if (ck.isEmpty()) return null
        val r = post("/weapi/w/nuser/account/get", JSONObject().put("csrf_token", ""), ck)
        if (r.code !in 200..299) return null
        val o = runCatching { JSONObject(r.text) }.getOrNull() ?: return null
        val prof = o.optJSONObject("profile") ?: return null
        return prof.optString("userId") to prof.optString("nickname")
    }

    // ---------------- 扫码登录 ----------------

    data class Qr(val key: String, val url: String)

    /** 要一个二维码。`url` 是要画成二维码的内容。*/
    fun qrKey(): Qr? {
        val r = post("/weapi/login/qrcode/unikey",
                     JSONObject().put("type", 1).put("csrf_token", ""))
        if (r.code !in 200..299) return null
        val key = runCatching { JSONObject(r.text).optString("unikey") }.getOrNull()
        if (key.isNullOrEmpty()) return null
        return Qr(key, "https://music.163.com/scan_qrcode?codekey=" + key)
    }

    /**
     * 轮询。返回 (状态, cookie)。
     * 状态：wait（等扫）/ scanned（已扫待确认）/ ok（**cookie 非空就是成功**）/ expired / err
     */
    fun qrPoll(key: String): Pair<String, String> {
        val r = post("/weapi/login/qrcode/client/login",
                     JSONObject().put("key", key).put("type", 1))
        if (r.code !in 200..299) return "err" to ""
        val obj = runCatching { JSONObject(r.text) }.getOrNull() ?: return "err" to ""
        val st = when (obj.optInt("code")) {
            800 -> "expired"
            801 -> "wait"
            802 -> "scanned"
            803 -> "ok"
            else -> "err"
        }
        // 803 那次响应里带 Set-Cookie（MUSIC_U），一定要顺手捞下来
        return st to r.cookie
    }
}
