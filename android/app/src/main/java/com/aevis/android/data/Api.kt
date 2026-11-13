package com.aevis.android.data

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 后端就一套：和 iOS / 网页版 / 小程序同一个（HK 反代 → 4-4）。
 *
 * ⚠️ 地址必须用已备案的 lingyan.cyou —— aevis.cn 没在 App 里用，
 * 是因为这一条链路 iOS 已经验过了，安卓照抄最省事。
 */
object Api {
    private const val BASE = "https://lingyan.cyou/prod-api/aevis"

    fun login(email: String, password: String): Pair<Boolean, String> {
        val body = JSONObject().put("email", email).put("password", password)
        val (code, json) = post("/v1/auth/login", body, null)
        if (code !in 200..299) return false to "HTTP $code"
        // 这个接口的 token 在**顶层**（`{ok,token,uid,email,membership}`），
        // 也有分支包在 `data` 里 —— 两边都认，别因为外壳变了就登不上。
        val data = json.optJSONObject("data") ?: json
        val tok = data.optString("token").ifEmpty { json.optString("token") }
        if (tok.isEmpty()) return false to json.optString("msg", "账号或密码不正确")
        save(tok, data.optString("email").ifEmpty { email }, data.optString("uid"))
        return true to ""
    }

    /** 余额（积分）。没登录或网络不通都返回 null，界面如实显示「—」。 */
    fun balance(): Int? {
        val t = token() ?: return null
        val (code, json) = get("/v1/llm/balance", t)
        if (code !in 200..299) return null
        return json.optJSONObject("data")?.optInt("balance", -1)?.takeIf { it >= 0 }
    }

    // ---------------- 底层 ----------------

    private fun prefs(c: Context = appCtx) =
        c.getSharedPreferences("aevis", Context.MODE_PRIVATE)

    lateinit var appCtx: Context
        private set

    fun init(ctx: Context) { appCtx = ctx.applicationContext }

    fun token(): String? = prefs().getString("token", null)
    fun email(): String = prefs().getString("email", "") ?: ""
    fun uid(): String = prefs().getString("uid", "") ?: ""
    fun signedIn(): Boolean = !token().isNullOrEmpty()

    fun save(token: String, email: String, uid: String) {
        prefs().edit().putString("token", token).putString("email", email)
            .putString("uid", uid).apply()
    }

    fun signOut() { prefs().edit().clear().apply() }

    private fun post(path: String, body: JSONObject?, token: String?): Pair<Int, JSONObject> =
        call("POST", path, body, token)

    private fun get(path: String, token: String?): Pair<Int, JSONObject> =
        call("GET", path, null, token)

    private fun call(method: String, path: String, body: JSONObject?,
                     token: String?): Pair<Int, JSONObject> {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(BASE + path).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 15000
                readTimeout = 20000
                setRequestProperty("Content-Type", "application/json")
                if (!token.isNullOrEmpty()) {
                    setRequestProperty("Authorization", "Bearer $token")
                }
                if (body != null) doOutput = true
            }
            if (body != null) conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() } ?: ""
            code to (runCatching { JSONObject(text) }.getOrElse { JSONObject() })
        } catch (e: Exception) {
            -1 to JSONObject().put("msg", e.message ?: "网络异常")
        } finally {
            conn?.disconnect()
        }
    }
}
