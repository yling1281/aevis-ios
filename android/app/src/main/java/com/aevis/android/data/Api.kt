package com.aevis.android.data

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** 一次登录/注册调用的结果。`code` 是业务码（4113 注销 / 4114 封禁 / 4115 冻结）。 */
data class AuthResult(val ok: Boolean, val msg: String = "", val code: Int = 0)

/**
 * 后端就一套：和 iOS / 网页版 / 小程序同一个（HK 反代 → 4-4）。
 *
 * ⚠️ 地址必须用已备案的 lingyan.cyou —— 这条链路 iOS 已经验过，安卓照抄最省事。
 */
object Api {
    private const val BASE = "https://lingyan.cyou/prod-api/aevis"

    // ---------------- 登录的三种方式（与 iOS LoginView 一一对应）----------------

    /** 验证码登录第 1 步：给邮箱发 6 位码。**只发给已注册的邮箱**。 */
    fun sendLoginCode(email: String): AuthResult =
        simple("/v1/auth/email/code", JSONObject().put("email", norm(email)))

    /** 验证码登录第 2 步。 */
    fun loginWithCode(email: String, code: String): AuthResult =
        auth("/v1/auth/login/email-code",
             JSONObject().put("email", norm(email)).put("code", code.trim()), email)

    /** 密码登录。 */
    fun loginPassword(email: String, password: String): AuthResult =
        auth("/v1/auth/login/email",
             JSONObject().put("email", norm(email)).put("password", password), email)

    /** 注册第 1 步：发码（注册也要先验证邮箱能收信）。 */
    fun sendRegisterCode(email: String): AuthResult =
        simple("/v1/auth/email/code", JSONObject().put("email", norm(email)))

    /** 注册第 2 步。邮箱 + 密码 + 验证码。 */
    fun register(email: String, password: String, code: String): AuthResult =
        auth("/v1/auth/register",
             JSONObject().put("email", norm(email)).put("password", password)
                 .put("code", code.trim()), email)

    /**
     * QQ 一键登录：拿授权地址。用法跟 iOS 一样 —— 丢给**系统浏览器**打开，
     * QQ 授权完服务端 302 回 `aevis://login?token=…`，由 MainActivity 接。
     * 返回 (地址, 错误文案)。
     */
    fun qqAuthUrl(): Pair<String, String> {
        val (code, json) = post("/v1/auth/qq/url", JSONObject(), null)
        if (code !in 200..299) return "" to "网络异常（HTTP $code）"
        val data = json.optJSONObject("data") ?: json
        val url = data.optString("auth_url").ifEmpty { data.optString("url") }
        if (url.isEmpty()) return "" to json.optString("msg").ifEmpty { "QQ 登录还没配置" }
        return url to ""
    }

    fun logout() = signOut()

    /** 余额（积分）。没登录或网络不通都返回 null，界面如实显示「—」。 */
    fun balance(): Int? {
        val t = token() ?: return null
        val (code, json) = get("/v1/llm/balance", t)
        if (code !in 200..299) return null
        return json.optJSONObject("data")?.optInt("balance", -1)?.takeIf { it >= 0 }
    }

    // ---------------- 内部 ----------------

    private fun norm(email: String) = email.trim().lowercase()

    /** 不用 token 的调用（发验证码）：只关心成功与否 + 服务端那句话。 */
    private fun simple(path: String, body: JSONObject): AuthResult {
        val (code, json) = post(path, body, null)
        if (code !in 200..299) {
            return AuthResult(false, json.optString("msg").ifEmpty { "网络异常（HTTP $code）" }, code)
        }
        val biz = json.optInt("code", 200)
        if (biz != 200 && json.has("msg") && !json.optBoolean("ok", false)) {
            // 服务端的 `err()` 也是 HTTP 200 + code!=200 的形态，不能只看 HTTP 码
            return AuthResult(false, json.optString("msg", "发送失败"), biz)
        }
        return AuthResult(true)
    }

    /** 需要落 token 的调用：登录 / 注册。 */
    private fun auth(path: String, body: JSONObject, email: String): AuthResult {
        val (code, json) = post(path, body, null)
        if (code !in 200..299) {
            return AuthResult(false, json.optString("msg").ifEmpty { "网络异常（HTTP $code）" }, code)
        }
        // token 可能在顶层，也可能包在 data 里 —— 两种都认（后端有两个分支）
        val data = json.optJSONObject("data") ?: json
        val tok = data.optString("token").ifEmpty { json.optString("token") }
        if (tok.isEmpty()) {
            val biz = json.optInt("code", 0)
            val msg = json.optString("msg").ifEmpty { "账号或密码不正确" }
            return AuthResult(false, msg, biz)
        }
        save(tok, data.optString("email").ifEmpty { email.trim() },
             data.optString("uid").ifEmpty { json.optString("uid") })
        return AuthResult(true)
    }

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
