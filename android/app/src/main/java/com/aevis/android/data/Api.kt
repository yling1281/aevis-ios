package com.aevis.android.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeoutOrNull

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** 一次登录/注册调用的结果。`code` 是业务码（4113 注销 / 4114 封禁 / 4115 冻结）。 */
data class AuthResult(val ok: Boolean, val msg: String = "", val code: Int = 0)

/**
 * 后端就一套：和 iOS / 网页版 / 小程序同一个（HK 反代 → 4-4）。
 *
 * ⚠️ 地址必须用已备案的 lingyan.cyou —— 这条链路 iOS 已经验过，安卓照抄最省事。
 */
object Api {
    private const val BASE = "https://lingyan.cyou/prod-api/aevis"

    /// 直连线路（2026-11-14）：机房新开的外网 54319 → 内网 5533，
    /// 不经过香港反代、不依赖域名。
    /// 自签 TLS：CA 打在 `res/raw/aevis_direct_ca.crt`，
    /// `network_security_config.xml` 只对这一个 IP 信任它。
    private const val DIRECT = "https://103.236.72.107:54319"

    /// 上一次请求用的哪条线。**默认直连优先** ——
    /// 2026-11-14 实测：直连 56ms、香港反代 1493ms、aevis.cn 5192ms，
    /// 差 26 倍，没理由让用户先等主力超时。直连一旦失败就永久切回主力，
    /// 下次也不会再去撞（除非进程重启）。
    @Volatile
    private var preferDirect = true

    /// 云端下发的额外线路（2026-11-14）。
    /// 用户：「有些路线不行了，我们还能云更新，拿一个保底，然后云更新加其他的线路。」
    /// 来源 `/v1/app/config` 的 `lines`，缓存在本地，冷启动先读缓存再后台刷新。
    @Volatile
    private var cloudBases: List<String> = emptyList()

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

    // ---------------- 微信扫码登录（2026-11-14）----------------
    // 后端 /v1/auth/wx/qr/create 出 ticket + 小程序码 PNG，App 轮 /poll 拿 token。
    // 之前安卓这两个入口只是说明弹窗（不装作能用），现在真接上。

    data class WxQr(val ticket: String, val imageUrl: String, val jumpUrl: String,
                    val err: String = "")

    /** 拿一张新的小程序码。err 非空表示这条路当下不可用，界面如实说。 */
    fun wxQrCreate(): WxQr {
        val (code, json) = post("/v1/auth/wx/qr/create", JSONObject(), null)
        if (code !in 200..299) return WxQr("", "", "", "网络异常（HTTP $code）")
        val d = json.optJSONObject("data") ?: json
        if (!d.optBoolean("ok", false)) {
            return WxQr("", "", "",
                d.optString("msg").ifEmpty { "微信登录暂不可用" })
        }
        return WxQr(d.optString("ticket"), d.optString("image_url"),
                    d.optString("jump_url"))
    }

    /** 轮询结果：status = pending / ok / expired / err */
    data class WxPoll(val status: String, val token: String = "",
                      val email: String = "", val uid: String = "",
                      val msg: String = "")

    fun wxQrPoll(ticket: String): WxPoll {
        val (code, json) = post("/v1/auth/wx/qr/poll",
                                JSONObject().put("ticket", ticket), null)
        if (code !in 200..299) return WxPoll("err", msg = "网络异常（HTTP $code）")
        val d = json.optJSONObject("data") ?: json
        if (!d.optBoolean("ok", false)) {
            val m = d.optString("msg")
            return WxPoll(if (m.contains("过期")) "expired" else "err", msg = m)
        }
        return if (d.optString("status") == "ok") {
            WxPoll("ok", d.optString("token"), d.optString("email"),
                   d.optString("uid"))
        } else {
            WxPoll("pending")
        }
    }

    /** 拉二维码图片（小程序码）。相对路径补上当前线路。 */
    fun loadQrBitmap(url: String): android.graphics.Bitmap? {
        if (url.isEmpty()) return null
        val full = if (url.startsWith("http")) url else BASE + url
        return try {
            java.net.URL(full).openConnection().apply {
                connectTimeout = 10000
                readTimeout = 15000
            }.getInputStream().use {
                android.graphics.BitmapFactory.decodeStream(it)
            }
        } catch (e: Exception) {
            null
        }
    }

    // ---------------- 账号 / 站内信 / 商城（2026-11-14 补）----------------
    //
    // 用户：「这个账号的头像也不行，名称也不行，都没接入，通知也不行」
    // → 之前「我」页拿 email 首字母当头像、UID 当名字，其实 `/v1/me` 一直有
    //   `nickname` / `avatar`（`/v1/me/profile` 还能改），只是从来没调过。

    data class MeInfo(val nickname: String, val avatar: String, val email: String,
                      val uid: String, val membership: String)

    fun me(): MeInfo? {
        val t = token() ?: return null
        val (code, json) = get("/v1/me", t)
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: return null
        if (!d.optBoolean("ok", false)) return null
        val mem = d.optJSONObject("membership")?.optString("plan").orEmpty()
        return MeInfo(
            d.optString("nickname"), d.optString("avatar"),
            d.optString("email"), d.optString("uid"), mem
        )
    }

    /** 站内信。后端用的是 `X-Account` 头（不是 Bearer），别的模块都这么认。 */
    data class InboxItem(val id: Int, val title: String, val body: String,
                         val read: Boolean, val createdAt: String)

    fun inbox(): Pair<List<InboxItem>, Int> {
        val acc = email()
        if (acc.isEmpty()) return emptyList<InboxItem>() to 0
        val (code, json) = getWith("/v1/inbox/list", mapOf("X-Account" to acc), null)
        if (code !in 200..299) return emptyList<InboxItem>() to 0
        val d = json.optJSONObject("data") ?: return emptyList<InboxItem>() to 0
        val arr = d.optJSONArray("rows") ?: return emptyList<InboxItem>() to d.optInt("unread")
        val out = ArrayList<InboxItem>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                InboxItem(
                    o.optInt("id"), o.optString("title"), o.optString("body"),
                    o.optBoolean("read") || o.optBoolean("claimed"),
                    o.optString("created_at")
                )
            )
        }
        return out to d.optInt("unread")
    }

    /** 人设广场一条。后端 `persona_public` 的真实字段：
     *  `tagline`（一句话）/ `avatar_url` / `adopt_count`（被领养次数）/ `is_official`。*/
    data class Persona(val id: String, val name: String, val tagline: String,
                       val avatar: String, val adopt: Int, val official: Boolean,
                       val relation: String)

    fun personas(mine: Boolean = false): List<Persona> {
        val path = if (mine) "/v1/psquare/mine" else "/v1/psquare/list"
        val (code, json) = getWith(path, mapOf("X-Account" to email()), token())
        if (code !in 200..299) return emptyList()
        val d = json.optJSONObject("data") ?: return emptyList()
        val arr = d.optJSONArray("rows") ?: d.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<Persona>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                Persona(
                    o.optString("id"), o.optString("name"),
                    o.optString("tagline").ifEmpty { o.optString("personality") },
                    o.optString("avatar_url"),
                    o.optInt("adopt_count"),
                    o.optInt("is_official") == 1,
                    o.optString("relation")
                )
            )
        }
        return out
    }

    // ---------------- 网易云（2026-11-14）----------------
    //
    // 搜索走网易的**明文**接口 `/api/search/get`（不需要 weapi 加密，
    // iOS 的 `NeteaseClient` 也是先试明文）。播放地址不让客户端直连：
    // 后端 `/v1/music/url` 带 `Cookie: os=ios` 代取，否则网易回 -110 风控。

    data class Track(val id: String, val name: String, val artist: String,
                     val album: String, val cover: String, val durationMs: Int)

    fun searchMusic(keyword: String): List<Track> {
        val kw = keyword.trim()
        if (kw.isEmpty()) return emptyList()
        val q = URLEncoder.encode(kw, "UTF-8")
        val url = "https://music.163.com/api/search/get?s=$q&type=1&limit=20&offset=0"
        val text = try {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 8000
                readTimeout = 12000
                setRequestProperty("User-Agent",
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
                        "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
                setRequestProperty("Referer", "https://music.163.com/")
                // 少了这个头网易回 -110（风控），跟后端注释里踩过的是同一个坑
                setRequestProperty("Cookie", "os=ios; appver=8.9.70")
            }
            conn.inputStream.bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            return emptyList()
        }
        val arr = runCatching {
            JSONObject(text).optJSONObject("result")?.optJSONArray("songs")
        }.getOrNull() ?: return emptyList()

        val out = ArrayList<Track>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val artists = o.optJSONArray("artists")
            val names = ArrayList<String>()
            if (artists != null) {
                for (j in 0 until artists.length()) {
                    val a = artists.optJSONObject(j)?.optString("name").orEmpty()
                    if (a.isNotEmpty()) names.add(a)
                }
            }
            val albumObj = o.optJSONObject("album")
            val cover = albumObj?.optString("picUrl").orEmpty()
                .ifEmpty { artists?.optJSONObject(0)?.optString("img1v1Url").orEmpty() }
            out.add(
                Track(
                    o.optString("id"), o.optString("name"),
                    names.joinToString(" / "),
                    albumObj?.optString("name").orEmpty(),
                    cover, o.optInt("duration")
                )
            )
        }
        return out
    }

    // ---------------- 登录设备（2026-11-14）----------------

    data class Device(val token: String, val device: String, val ip: String,
                      val createdAt: String, val current: Boolean)

    fun sessions(): List<Device> {
        val t = token() ?: return emptyList()
        val (code, json) = get("/v1/auth/sessions", t)
        if (code !in 200..299) return emptyList()
        val arr = json.optJSONObject("data")?.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<Device>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                Device(
                    o.optString("token"), o.optString("device_id"),
                    o.optString("ip"), o.optString("created_at"),
                    o.optBoolean("current")
                )
            )
        }
        return out
    }

    fun revokeSession(tok: String): Boolean {
        val t = token() ?: return false
        val (code, _) = post("/v1/auth/sessions/revoke",
                             JSONObject().put("token", tok), t)
        return code in 200..299
    }

    // ---------------- 领养（2026-11-14）----------------
    //
    // 后端 `/v1/psquare/adopt` 只做 `adopt_count+1`，**没有"谁领养了谁"这张表**
    // （`/psquare/mine` 是"我发布的"，不是"我领养的"）。
    // 所以领养关系先记在本地；后端加表之后把 `adoptedIds()` 换成接口即可。

    private const val PREF_ADOPT = "aevis_adopted"

    fun adoptedIds(): Set<String> =
        prefs().getStringSet(PREF_ADOPT, emptySet())?.toSet() ?: emptySet()

    fun markAdopted(pid: String) {
        val cur = adoptedIds().toMutableSet()
        cur.add(pid)
        prefs().edit().putStringSet(PREF_ADOPT, cur).apply()
    }

    fun isAdopted(pid: String): Boolean = adoptedIds().contains(pid)

    /** 调后端 +1，成功返回 true（本地标记由调用方决定要不要落）。*/
    fun adopt(pid: String): Boolean {
        val (code, json) = post("/v1/psquare/adopt", JSONObject().put("id", pid), token())
        if (code !in 200..299) return false
        val d = json.optJSONObject("data") ?: json
        return d.optBoolean("ok", json.optInt("code", 200) == 200)
    }

    /** 表情包一套。后端 `emoji_pack` + `emoji_item`（`items` 是图 URL 数组）。*/
    data class EmojiPack(val id: String, val name: String, val intro: String,
                         val cover: String, val count: Int, val official: Boolean)

    fun emojiPacks(): List<EmojiPack> {
        val (code, json) = getWith("/v1/emoji/list", emptyMap(), token())
        if (code !in 200..299) return emptyList()
        val d = json.optJSONObject("data") ?: return emptyList()
        val arr = d.optJSONArray("rows") ?: return emptyList()
        val out = ArrayList<EmojiPack>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val items = o.optJSONArray("items")
            out.add(
                EmojiPack(
                    o.optString("id"), o.optString("name"), o.optString("intro"),
                    o.optString("cover_url").ifEmpty {
                        items?.optString(0).orEmpty()
                    },
                    o.optInt("count").let { if (it > 0) it else (items?.length() ?: 0) },
                    o.optInt("is_official") == 1
                )
            )
        }
        return out
    }

    /** 播放地址。后端代取（带 `Cookie: os=ios`），拿不到就降 128k 再试一次。 */
    fun musicUrl(id: String): String? {
        val (code, json) = get("/v1/music/url?id=" + URLEncoder.encode(id, "UTF-8"), token())
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: json
        return d.optString("url").takeIf { it.startsWith("http") }
    }

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

    fun init(ctx: Context) {
        appCtx = ctx.applicationContext
        // 先吃上次缓存的云端线路，再后台刷一遍 —— 冷启动不等网络
        cloudBases = prefs().getString("cloud_lines", "").orEmpty()
            .split(",").map { it.trim() }.filter { it.startsWith("http") }
        refreshCloudLines()
    }

    /// 拉 `/v1/app/config` 更新线路列表。失败就继续用缓存，不打扰用户。
    fun refreshCloudLines() {
        Thread {
            try {
                // 两条内置线路都试一下 —— 只试香港的话，香港一挂云更新就断了
                var res = callOnce(BASE, "GET", "/v1/app/config", null, token())
                if (res.first <= 0) res = callOnce(DIRECT, "GET", "/v1/app/config", null, token())
                if (res.first <= 0) return@Thread
                val arr = res.second.optJSONObject("data")?.optJSONArray("lines") ?: return@Thread
                val out = ArrayList<String>()
                for (i in 0 until arr.length()) {
                    val base = arr.optJSONObject(i)?.optString("base").orEmpty().trim()
                    if (base.startsWith("http")) out.add(base)
                }
                if (out.isNotEmpty()) {
                    cloudBases = out
                    prefs().edit().putString("cloud_lines", out.joinToString(",")).apply()
                }
            } catch (e: Exception) {
                // 云更新是保底手段，拿不到就安静用现有的
            }
        }.start()
    }

    /** 当前优先线路的根地址 —— 图片这类不走 call() 的请求要用它拼绝对地址。*/
    fun baseUrl(): String = if (preferDirect) DIRECT else BASE

    /**
     * 线路的**对外叫法**。2026-11-14 用户：「你不要直接把我们的 IP 明着写出来啊，
     * 你应该写一个简称，就是哪个线哪个线」—— 所以界面上只说「线路一 / 线路二」，
     * 具体地址不外露（截图、发给别人时也不会把机房 IP 带出去）。
     */
    // ---------------- 图片：多线路竞速（2026-11-14）----------------

    /**
     * 用户：「下载图片怎么下载这么慢，你直接多路线下载呀」。
     *
     * 以前图片只走 `baseUrl()` 一条线，那条挂/慢就干等（头像、表情包封面全卡住）。
     * 现在把两条线路**同时发**，谁先回就用谁 —— 图片是小文件，
     * 并发两份的流量代价可以忽略，换来的是"不会因为一条线慢而干等"。
     */
    suspend fun fetchImage(path: String): android.graphics.Bitmap? {
        if (path.startsWith("http")) return loadBitmap(path)
        // 顺序试：先当前优先线路，失败换另一条。
        // ⚠️ 别再用 Channel + supervisorScope 那套并发 —— 实测在真机上
        //    一张都没出来（Channel 的接收端在页面离开时会被取消，整批返回 null）。
        //    图片是小文件，顺序试的代价只是一次超时，可靠性高得多。
        val order = if (preferDirect) listOf(DIRECT, BASE) else listOf(BASE, DIRECT)
        for (b in order) {
            val r = runCatching { loadBitmap(b + path) }.getOrNull()
            if (r != null) return r
        }
        return null
    }

    private fun loadBitmap(full: String): android.graphics.Bitmap? {
        val conn = java.net.URL(full).openConnection()
        conn.connectTimeout = 5000
        conn.readTimeout = 10000
        return conn.getInputStream().use { android.graphics.BitmapFactory.decodeStream(it) }
    }

    /** 手动切线路（关于页里点一下在 直连 / 中转 之间换）。*/
    fun switchLine(): String {
        preferDirect = !preferDirect
        return lineName()
    }

    /** 查有没有新版本。返回 (最新版本名, 最新构建号, 下载地址, 说明)；查不到返回 null。*/
    fun latestRelease(): Array<String>? {
        val (code, json) = get("/v1/app/version?platform=android&build=" +
            com.aevis.android.BuildConfig.VERSION_CODE, null)
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: json
        val v = d.optString("latest_version")
        if (v.isEmpty()) return null
        return arrayOf(
            v, d.optString("build"), d.optString("ipa_url"), d.optString("notes")
        )
    }

    fun lineName(): String =
        if (preferDirect) com.aevis.android.core.I18n.tr("线路一 · 直连")
        else com.aevis.android.core.I18n.tr("线路二 · 中转")

    // ---------------- 资料缓存（2026-11-14）----------------
    //
    // 用户：「这个头像和这个名字是要缓存到本地的」。
    // 之前每次进「我」页都要等 /v1/me 回来才有名字头像，
    // 网慢的时候先闪一下邮箱首字母。现在落盘，冷启动直接有。

    fun cachedMe(): MeInfo? {
        val sp = prefs()
        val n = sp.getString("me_name", "").orEmpty()
        val a = sp.getString("me_avatar", "").orEmpty()
        if (n.isEmpty() && a.isEmpty()) return null
        return MeInfo(n, a, email(), uid(), sp.getString("me_mem", "").orEmpty())
    }

    fun saveMe(m: MeInfo) {
        prefs().edit()
            .putString("me_name", m.nickname)
            .putString("me_avatar", m.avatar)
            .putString("me_mem", m.membership)
            .apply()
    }

    fun token(): String? = prefs().getString("token", null)
    fun email(): String = prefs().getString("email", "") ?: ""
    fun uid(): String = prefs().getString("uid", "") ?: ""
    fun signedIn(): Boolean = !token().isNullOrEmpty()

    fun save(token: String, email: String, uid: String) {
        prefs().edit().putString("token", token).putString("email", email)
            .putString("uid", uid).apply()
    }

    fun signOut() { prefs().edit().clear().apply() }

    // ---------------- 网页授权登录（2026-11-13）----------------
    //
    // 浏览器打开 aevis.cn/recharge → 点「用 Aevis App 授权」→ `aevis://weblogin?t=…`
    // → 这里看一眼票、弹确认框、点允许。网页那边自己轮询拿到登录态。

    /** 确认框要显示的东西：四位验证码 + 是哪个设备在请求。 */
    fun webLoginPeek(ticket: String): Pair<Int, JSONObject> =
        get("/v1/web/auth/peek?t=" + URLEncoder.encode(ticket, "UTF-8"), token())

    fun webLoginConfirm(ticket: String): Pair<Int, JSONObject> =
        post("/v1/web/auth/confirm", JSONObject().put("ticket", ticket), token())

    fun webLoginCancel(ticket: String) {
        post("/v1/web/auth/cancel", JSONObject().put("ticket", ticket), token())
    }

    private fun post(path: String, body: JSONObject?, token: String?): Pair<Int, JSONObject> =
        call("POST", path, body, token)

    private fun get(path: String, token: String?): Pair<Int, JSONObject> =
        call("GET", path, null, token)

    /** 需要额外头的 GET（站内信认 `X-Account`，不认 Bearer）。 */
    private fun getWith(path: String, headers: Map<String, String>,
                        token: String?): Pair<Int, JSONObject> {
        var last: Pair<Int, JSONObject> = -1 to JSONObject().put("msg", "网络异常")
        for (base in listOf(if (preferDirect) DIRECT else BASE,
                            if (preferDirect) BASE else DIRECT)) {
            val r = callOnce(base, "GET", path, null, token, headers)
            if (r.first > 0) return r
            last = r
        }
        return last
    }

    private fun call(method: String, path: String, body: JSONObject?,
                     token: String?): Pair<Int, JSONObject> {
        // 候选顺序：上次成功的那条优先，然后另一条内置，最后才是云端下发的。
        // 最多试 3 条 —— 串行试太多线路，用户看到的就是"一直在转圈"。
        val order = ArrayList<String>(4)
        if (preferDirect) { order.add(DIRECT); order.add(BASE) }
        else { order.add(BASE); order.add(DIRECT) }
        for (b in cloudBases) {
            if (order.size >= 3) break
            if (!order.contains(b)) order.add(b)
        }

        var last: Pair<Int, JSONObject> = -1 to JSONObject().put("msg", "网络异常")
        for (base in order) {
            val r = callOnce(base, method, path, body, token)
            if (r.first > 0) {
                preferDirect = (base == DIRECT)
                return r
            }
            last = r
        }
        return last
    }

    private fun callOnce(host: String, method: String, path: String, body: JSONObject?,
                         token: String?, extra: Map<String, String> = emptyMap())
            : Pair<Int, JSONObject> {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(host + path).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 8000
                readTimeout = 20000
                setRequestProperty("Content-Type", "application/json")
                if (!token.isNullOrEmpty()) {
                    setRequestProperty("Authorization", "Bearer $token")
                }
                for ((k, v) in extra) if (v.isNotEmpty()) setRequestProperty(k, v)
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
