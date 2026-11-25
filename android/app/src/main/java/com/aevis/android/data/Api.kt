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
 * 后端就一套：和 iOS / 网页版 / 小程序同一个（直连 / 北京反代 → 4-4）。
 *
 * ⚠️ 地址必须用已备案的 lingyan.cyou —— 这条链路 iOS 已经验过，安卓照抄最省事。
 */
object Api {
    /**
     * 线路常量（2026-11-16，106）：**Base64 + XOR(0x5A)** 存，运行时解出来。
     * 目的只是让 `strings` / apk 反编译时一眼看不到域名，不是真加密。
     * XOR 密钥改这里的话，四个密文要一起重算。
     */
    private fun d(s: String): String = runCatching {
        String(android.util.Base64.decode(s, android.util.Base64.DEFAULT)
            .map { (it.toInt() xor 0x5A).toByte() }.toByteArray())
    }.getOrDefault("")

    private val BASE get() = d("Mi4uKilgdXU2MzQ9Izs0dDkjNS91Kig1Pnc7KjN1Oz8sMyk=")

    /// 直连线路（2026-11-14）：机房新开的外网 54319 → 内网 5533，
    /// 不经过反代、不依赖域名。
    /// 自签 TLS：CA 打在 `res/raw/aevis_direct_ca.crt`，
    /// `network_security_config.xml` 只对这一个 IP 信任它。
    private val DIRECT get() = d("Mi4uKilgdXVraml0aGlsdG1odGtqbWBvbmlrYw==")

    /**
     * 新线路（2026-11-16，105）：北京机 `123.57.33.160` 经 SSH 隧道反代到 4-4，
     * 实测 `/v1/app/config` 往返 **0.18–0.20 秒**（原来 1.1–3.3 秒）。
     * 用法与 `BASE` 完全一致（`/v1/...` 路径），所以可以直接当候选。
     * ⚠️ 和 BASE/DIRECT 一样：**只允许出现在网络层**，界面/日志一律不露域名。
     */
    private val FASTLINE get() = d("Mi4uKilgdXUrbTdpOyJ0NjM0PSM7NHQ5IzUv")

    /**
     * 备用自签线路（2026-11-16，106）：，证书是自签的。
     * 靠  里登记的  才能连
     * （系统 CA 不认它）。**只作为最后一档兜底**。
     */
    private val API2LINE get() = d("Mi4uKilgdXU7KjNodDYzND0jOzR0OSM1L2BiYmNj")

    /// 上一次请求用的哪条线。**默认直连优先** ——
    /// 2026-11-14 实测：直连 56ms、中转反代 1493ms、aevis.cn 5192ms，
    /// 差 26 倍，没理由让用户先等慢线超时。直连一旦失败就切到备用，
    /// 下次也不会再去撞（除非进程重启）。
    @Volatile
    private var preferDirect = true

    /**
     * 当前线路连续失败次数（2026-11-16）。
     *
     * 只统计**网络层**失败（`call()` 里所有候选线路都没打通）。到 3 次且
     * 「自动选最快」开着时，`chat()` 会切到另一条线路重试一次。
     * 成功一次就归零 —— 偶尔抖一下不该立刻换线。
     */
    @Volatile
    private var lineFailStreak = 0

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

    /**
     * QQ 登录（2026-11-16，97）：SDK 拿到的 `access_token` + `openid` 交给服务端校验。
     *
     * 服务端会自己打 `graph.qq.com/oauth2.0/me` 反查 openid，并硬校验 AppID=1906403793，
     * **不信任**客户端传的 openid；首次登录自动建号（`auth_identity(provider='qq')`）。
     */
    fun qqLogin(accessToken: String, openid: String): AuthResult {
        val (code, json) = post(
            "/v1/auth/qqlogin",
            JSONObject().put("access_token", accessToken).put("openid", openid),
            null
        )
        if (code !in 200..299) return AuthResult(false, "网络异常（$code）", code)
        if (json.optInt("code", -1) != 0)
            return AuthResult(false, json.optString("msg").ifBlank { "QQ 登录失败" }, code)
        val d = json.optJSONObject("data")
            ?: return AuthResult(false, "返回格式不对", code)
        val tok = d.optString("token")
        if (tok.isBlank()) return AuthResult(false, d.optString("msg").ifBlank { "QQ 登录失败" }, code)
        // 落库：跟邮箱/微信登录同一个 `save(token, email, uid)`
        save(tok, d.optString("email"), d.optString("uid"))
        return AuthResult(true)
    }

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
        val full = if (url.startsWith("http")) url else baseUrl() + url
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
                      val uid: String, val membership: String,
                      // 语音音色（2026-11-16）：后端给了就用它念，没给就退到 /v1/tts/voices 第一个
                      val voice: String = "")

    fun me(): MeInfo? {
        val t = token() ?: return null
        val (code, json) = get("/v1/me", t)
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: return null
        if (!d.optBoolean("ok", false)) return null
        val mem = d.optJSONObject("membership")?.optString("plan").orEmpty()
        return MeInfo(
            d.optString("nickname"), d.optString("avatar"),
            d.optString("email"), d.optString("uid"), mem,
            d.optString("voice").ifBlank { d.optString("tts_voice") }
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

    // ---------------- 墨点扫码充值（2026-11-18，181）----------------

    /** 二维码下单结果。*/
    data class QrOrder(
        val orderNo: String,
        val amountYuan: String,
        val points: Int,
        val qrContent: String
    )

    /**
     * `POST /v1/points/recharge/qr` —— 拿二维码内容（不跳浏览器）。
     * 失败返回 null，原因写进 [lastPayError]（网关原话，例如「下单频率过快」）。
     */
    fun rechargeQr(pkg: String, type: String = "wxpay"): QrOrder? {
        lastPayError = ""
        val (c, j) = post(
            "/v1/points/recharge/qr",
            JSONObject().put("pkg", pkg).put("type", type), token()
        )
        if (c !in 200..299) { lastPayError = "HTTP $c"; return null }
        if (j.optInt("code", -1) != 200 && j.optInt("code", -1) != 0) {
            lastPayError = j.optString("msg").ifBlank { "下单失败" }
            return null
        }
        val d = j.optJSONObject("data") ?: run {
            lastPayError = "返回格式不对"; return null
        }
        val qr = d.optString("qrContent")
        if (qr.isBlank()) { lastPayError = "没拿到二维码内容"; return null }
        return QrOrder(
            d.optString("orderNo"), d.optString("amountYuan"),
            d.optInt("points"), qr
        )
    }

    /** 会员扫码下单（2026-11-18，182）：`POST /v1/pay/member/qr {plan}`。*/
    data class MemberQr(
        val orderNo: String, val plan: String, val days: Int,
        val amountYuan: String, val qrContent: String
    )

    fun memberQr(plan: String): MemberQr? {
        lastPayError = ""
        val (c, j) = post("/v1/pay/member/qr", JSONObject().put("plan", plan), token())
        if (c !in 200..299) { lastPayError = "HTTP $c"; return null }
        val code = j.optInt("code", -1)
        if (code != 200 && code != 0) {
            lastPayError = j.optString("msg").ifBlank { "下单失败" }
            return null
        }
        val d = j.optJSONObject("data") ?: run { lastPayError = "返回格式不对"; return null }
        val qr = d.optString("qrContent")
        if (qr.isBlank()) { lastPayError = "没拿到二维码内容"; return null }
        return MemberQr(
            d.optString("orderNo"), d.optString("plan"), d.optInt("days"),
            d.optString("amountYuan"), qr
        )
    }

    /** `GET /v1/points/recharge/<no>` —— 读 `status`（没有就退 `state`）。*/
    fun rechargeStatus(orderNo: String): Pair<String, Int> {
        val (c, j) = get("/v1/points/recharge/" + URLEncoder.encode(orderNo, "UTF-8"), token())
        if (c !in 200..299) return "" to 0
        val d = j.optJSONObject("data") ?: return "" to 0
        val st = d.optString("status").ifBlank { d.optString("state") }
        return st to d.optInt("points")
    }

    /** 只取未读数（2026-11-16，104）：底部 tab 红点用，不拉整表。*/
    // ---------------- 模型统计 / 天气（2026-11-16，109） ----------------

    data class Bucket(val ok: Int, val fail: Int) {
        val total: Int get() = ok + fail
    }

    data class LlmStat(
        val model: String,
        val calls: Int,
        val fails: Int,
        val avgMs: Long,
        val buckets: List<Bucket>
    ) {
        fun successRate(): Double = if (calls <= 0) 0.0
        else (calls - fails).toDouble() / calls
    }

    /**
     * 近 30 分钟按模型聚合。服务端没上线/没数据 → 返回 null（界面显示 `—`，**不造假**）。
     * 期望结构：`{"code":0,"data":{"models":[{"model":"gpt-4o","calls":10,"fails":2,
     *            "avg_ms":3300,"buckets":[{"ok":3,"fail":1},…]}]}}`
     */
    fun llmStats(): List<LlmStat>? {
        val t = token() ?: return null
        val (c, j) = get("/v1/llm/stats", t)
        if (c !in 200..299) return null
        val arr = j.optJSONObject("data")?.optJSONArray("models") ?: return null
        if (arr.length() == 0) return emptyList()
        val out = ArrayList<LlmStat>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val bs = ArrayList<Bucket>()
            val ba = o.optJSONArray("buckets")
            if (ba != null) for (k in 0 until ba.length()) {
                val b = ba.optJSONObject(k) ?: continue
                bs.add(Bucket(b.optInt("ok"), b.optInt("fail")))
            }
            out.add(
                LlmStat(
                    o.optString("model"),
                    o.optInt("calls"),
                    o.optInt("fails"),
                    o.optLong("avg_ms"),
                    bs
                )
            )
        }
        return out
    }

    // ---------------- 模型状态：/v1/relay/status（110，官网 /status 同源） ----------------

    /**
     * 一个模型的状态块。字段名严格照接口，**不要改语义**：
     * `ping`（毫秒，可空）/ `uptime24`（0–1，可空）/ `beats`（近 24 小时，50 个 30 分钟槽，1 绿 0 红）。
     */
    data class RelayModel(
        val model: String,
        val name: String,
        val vendor: String,
        val ping: Long?,          // null = 没测到
        val uptime24: Double?,    // null = 没数据
        val beats: List<Int>,
        val matched: Boolean,
        val note: String
    )

    /**
     * `/v1/relay/status` 的**进程内缓存**（2026-11-16，115）。
     *
     * 返回体 ~13KB、30+ 个模型，服务状态页每次进来都全量拉一遍既慢又费流量；
     * 5 分钟内直接给缓存，用户点「刷新」才 `force = true` 重新请求。
     */
    @Volatile
    private var relayCache: List<RelayModel>? = null
    @Volatile
    private var relayCacheAt: Long = 0L
    private const val RELAY_TTL = 5 * 60_000L

    /** 只读缓存（不发起请求）—— 页面第一帧就该拿它渲染。 */
    fun relayStatusCached(): List<RelayModel>? = relayCache

    fun relayStatus(force: Boolean = false): List<RelayModel>? {
        val now = System.currentTimeMillis()
        val hit = relayCache
        if (!force && hit != null && now - relayCacheAt < RELAY_TTL) return hit
        val fresh = fetchRelayStatus() ?: return hit
        relayCache = fresh
        relayCacheAt = now
        return fresh
    }

    private fun fetchRelayStatus(): List<RelayModel>? = runCatching {
        val (c, j) = get("/v1/relay/status", token())
        if (c !in 200..299) return null
        val arr = j.optJSONObject("data")?.optJSONArray("models") ?: return null
        val out = ArrayList<RelayModel>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val beats = ArrayList<Int>()
            o.optJSONArray("beats")?.let { ba ->
                for (k in 0 until ba.length()) beats.add(ba.optInt(k))
            }
            out.add(
                RelayModel(
                    model = o.optString("model"),
                    name = o.optString("name").ifBlank { o.optString("model") },
                    vendor = o.optString("vendor"),
                    ping = if (o.isNull("ping")) null else o.optLong("ping"),
                    uptime24 = if (o.isNull("uptime24")) null else o.optDouble("uptime24"),
                    beats = beats,
                    matched = o.optBoolean("matched", true),
                    note = o.optJSONObject("relay")?.optString("note").orEmpty()
                )
            )
        }
        out
    }.getOrNull()

    /** 天气（现实感知用）。拿不到返回 null（整行不显示，不显示 `--`）。*/
    data class Weather(val temp: Double, val desc: String, val humidity: Int, val wind: Double)

    fun weather(lat: Double, lon: Double): Weather? = runCatching {
        val (c, j) = get("/v1/weather?lat=$lat&lon=$lon", token())
        if (c !in 200..299) return null
        val d = j.optJSONObject("data") ?: return null
        val desc = d.optString("desc")
        if (desc.isBlank()) return null
        Weather(d.optDouble("temp"), desc, d.optInt("humidity"), d.optDouble("wind"))
    }.getOrNull()

    fun inboxUnread(): Int = runCatching { inbox().second }.getOrDefault(0)

    /** 标记站内信已读（`POST /v1/inbox/read`，同样用 `X-Account`）。*/
    fun inboxMarkRead(): Boolean = runCatching {
        val acc = email()
        if (acc.isEmpty()) return false
        val (c, j) = postWith("/v1/inbox/read", JSONObject(), mapOf("X-Account" to acc), null)
        c in 200..299 && j.optInt("code", 0) == 0
    }.getOrDefault(false)

    /** 人设广场一条。后端 `persona_public` 的真实字段：
     *  `tagline`（一句话）/ `avatar_url` / `adopt_count`（被领养次数）/ `is_official`。*/
    data class Persona(val id: String, val name: String, val tagline: String,
                       val avatar: String, val adopt: Int, val official: Boolean,
                       val relation: String)

    /**
     * 通讯录/会话列表真正该显示的人（2026-11-15 修）。
     *
     * 🔴 原来的坑：`/v1/psquare/mine` 返回的是 **`persona_public WHERE account_id=?`**，
     *    也就是「**我创建的人设**」，不是「我领养的」。而且 `ps_adopt` 只给
     *    `adopt_count` 加 1，**没有关系表** —— 领养关系一直只存在本地。
     *    结果就是通讯录把账号下所有人设全列出来了（用户：「你怎么给我把所有的人都加进来了」）。
     *
     * 现在的口径：**有联系的人才算联系人** ——
     *   · 本地记过领养的（`adoptedIds`）
     *   · 或者已经聊过的（本地有会话记录）
     * 两个都空（全新账号）才回落到列表前 20 个，免得空着一屏没法开始。
     */
    fun contacts(): List<Persona> {
        val all = personas()
        if (all.isEmpty()) return emptyList()
        val adopted = adoptedIds()
        val mine = all.filter { p ->
            adopted.contains(p.id) || loadConv(p.id).isNotEmpty()
        }
        return if (mine.isEmpty()) all.take(20) else mine
    }

    fun personas(mine: Boolean = false): List<Persona> {
        if (mine) return personasMine().first
        val path = "/v1/psquare/list"
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

    /**
     * 「我的角色」（服务端那一份）+ **错误原因**（2026-11-16，121）。
     *
     * `personas()` 把失败也吞成空列表 —— 自动恢复人设时要能给用户一句人话
     * （「网络异常（HTTP 502）」），不能"恢复失败"和"你本来就没有角色"长得一样。
     */
    fun personasMine(): Pair<List<Persona>, String> {
        val (code, json) = getWith("/v1/psquare/mine", mapOf("X-Account" to email()), token())
        if (code !in 200..299) return emptyList<Persona>() to "网络异常（HTTP $code）"
        val d = json.optJSONObject("data") ?: json
        val arr = d.optJSONArray("rows") ?: d.optJSONArray("items")
            ?: return emptyList<Persona>() to ""
        val out = ArrayList<Persona>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                Persona(
                    o.optString("id"), o.optString("name"),
                    o.optString("tagline").ifEmpty {
                        o.optString("personality").ifEmpty { o.optString("persona") }
                    },
                    o.optString("avatar_url").ifEmpty { o.optString("avatar") },
                    o.optInt("adopt_count"),
                    o.optInt("is_official") == 1,
                    o.optString("relation")
                )
            )
        }
        return out to ""
    }

    // ---------------- 主动唤醒（2026-11-16，132）----------------
    //
    // 服务端契约（team-lead 定的）：
    //   POST /v1/proactive/pref    {enabled, persona_id, min_interval_min, daily_max, quiet_start, quiet_end}
    //   GET  /v1/proactive/pending?persona_id=…   → {items:[{id, persona_id, text, at}]}
    //   POST /v1/proactive/ack     {ids:[…]}
    // 失败一律**静默**（返回空/false），由下一次轮询自然重试，不弹错、不重试风暴。

    /** 开/关某个角色的主动唤醒。默认参数就是产品定的 30 分钟 / 每天 5 条 / 23-8 免打扰。*/
    fun proactivePref(
        enabled: Boolean,
        pid: String,
        minIntervalMin: Int = 30,
        dailyMax: Int = 5,
        quietStart: Int = 23,
        quietEnd: Int = 8
    ): Boolean {
        val b = JSONObject().put("enabled", enabled)
        if (enabled) {
            b.put("persona_id", pid)
                .put("min_interval_min", minIntervalMin)
                .put("daily_max", dailyMax)
                .put("quiet_start", quietStart)
                .put("quiet_end", quietEnd)
        } else if (pid.isNotBlank()) {
            b.put("persona_id", pid)
        }
        val (code, json) = post("/v1/proactive/pref", b, token())
        return code in 200..299 && json.optInt("ok", 0) == 1
    }

    data class ProactiveMsg(val id: Long, val pid: String, val text: String)

    /** 拉某个角色待投递的主动消息（只拉当前打开的角色）。失败返回空列表。*/
    fun proactivePending(pid: String): List<ProactiveMsg> {
        if (token() == null || pid.isBlank()) return emptyList()
        val q = runCatching { java.net.URLEncoder.encode(pid, "UTF-8") }.getOrDefault(pid)
        val (code, json) = get("/v1/proactive/pending?persona_id=$q", token())
        if (code !in 200..299) return emptyList()
        val arr = json.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<ProactiveMsg>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val text = o.optString("text")
            if (text.isBlank()) continue
            out.add(
                ProactiveMsg(
                    id = o.optLong("id", 0L),
                    pid = o.optString("persona_id").ifBlank { pid },
                    text = text
                )
            )
        }
        return out
    }

    /** 投递确认（拿到的就别再推一次）。失败不管。*/
    fun proactiveAck(ids: List<Long>) {
        if (ids.isEmpty() || token() == null) return
        runCatching {
            val arr = org.json.JSONArray()
            ids.forEach { arr.put(it) }
            post("/v1/proactive/ack", JSONObject().put("ids", arr), token())
        }
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

    // ---------------- 创建人设（2026-11-24，对标 iOS createPersona）----------------
    //
    // 后端 `POST /v1/psquare/publish` 认 X-Account（不是 Bearer）。提交后走 AI 审核：
    // status="listing" = 已上广场；"rejected" = 没过，reason 给原因。
    // ⚠️ 这是**best-effort**：本地 `LocalPersonaStore` 先落盘（创建后立刻可见），
    //    这一步失败只影响"是否上公共广场"，不影响本地能用。

    data class PersonaCreateResult(
        val ok: Boolean,
        val id: String,
        val status: String,
        val reason: String
    ) {
        /** 审核通过、广场可见（status 可能是 listing / listed / approved）。*/
        val listed: Boolean get() = status.equals("listing", true) ||
            status.equals("listed", true) || status.equals("approved", true)
    }

    fun createPersona(
        name: String,
        tagline: String,
        personality: String,
        avatarUrl: String
    ): PersonaCreateResult {
        val acc = email()
        if (acc.isEmpty()) return PersonaCreateResult(false, "", "", "请先登录后再创建人设")
        val body = JSONObject()
            .put("name", name)
            .put("tagline", tagline)
            .put("personality", personality)
            .put("avatar_url", avatarUrl)
            .put("relation", "lover")
        val (code, json) = postWith(
            "/v1/psquare/publish", body, mapOf("X-Account" to acc), token()
        )
        if (code !in 200..299) {
            return PersonaCreateResult(
                false, "", "", json.optString("msg").ifEmpty { "网络异常（HTTP $code）" }
            )
        }
        val d = json.optJSONObject("data") ?: json
        return PersonaCreateResult(
            ok = true,
            id = d.optString("id"),
            status = d.optString("status"),
            reason = d.optString("reason").ifEmpty { json.optString("msg") }
        )
    }

    // ---------------- 聊天（2026-11-15）----------------
    //
    // 走 `/v1/llm/chat`（认用户 token、按真实 token 扣墨点）。
    // ⚠️ 别改回 `/v1/chat/completions` —— 那条是给 sk- API Key 用的，**不扣费**。
    // 安卓以前**根本没有聊天页**，这是第一版。

    /**
     * 一条消息。role = "user" / "assistant" / "system"。
     *
     * `who`（2026-11-16）：群聊里要知道这句是**哪个人设**说的 ——
     * 单聊用不到，所以给了默认空串，所有老调用点一行都不用改。
     *
     * `img`（2026-11-16）：表情包消息。非空时表示这条不是文字，而是一张图
     * （`/v1/media/…` 相对路径）。这种消息**不能原样发给模型** ——
     * `chat()` 里会把它转成 `[发了一个表情包]` 的文字，否则接口直接 400。
     */
    data class Msg(
        val role: String,
        val content: String,
        val who: String = "",
        val img: String = "",
        /**
         * 「从上下文移除」（2026-11-16）：消息**还在聊天记录里看得见**，
         * 但组 `messages` 发给模型时会被过滤掉 —— 专门解决"上下文拥堵"。
         * 落盘写 `"x": "1"`，老数据没有这个键 → 默认 false。
         */
        val skip: Boolean = false,
        /**
         * 引用回复（2026-11-16）：把被引用的那条**缩略**存下来（前 40 字），
         * 显示在自己这条气泡上方。存文本而不是索引 —— 被引用的那条可能后来被删掉。
         */
        val quote: String = "",
        /**
         * 「TA 主动找你」的消息（2026-11-16，132）。
         * 落盘写 `"p": "1"`；老数据没有这个键 → 默认 false。
         */
        val proactive: Boolean = false
    )

    /**
     * 发一轮对话，返回助手回复。
     * 失败返回 null，错误信息放进 [lastChatError]（界面直接显示，不吞掉）。
     */
    @Volatile
    var lastChatError: String = ""

    /**
     * 上一轮对话**实际扣了多少墨点**（来自 `/v1/llm/chat` 的 `usage.points`）。
     * 接口没给就是 0。界面可以顺手显示，让用户看得见"钱花在哪"。
     */
    @Volatile
    var lastChatPoints: Double = 0.0

    /** 扣完还剩多少墨点（`usage.balance`）。`-1` = 这次没拿到。*/
    @Volatile
    var lastChatBalance: Int = -1

    /** 上一轮从哪个池扣的：`member` / `points`（`usage.charge_from`，空 = 服务端没给）。*/
    @Volatile
    var lastChargeFrom: String = ""

    /** 会员本周额度还剩多少（`usage.quota_left`）。`-1` = 没拿到。*/
    @Volatile
    var lastQuotaLeft: Int = -1

    /**
     * 发一轮对话，返回助手回复。
     * 失败返回 null，错误信息放进 [lastChatError]（界面直接显示，不吞掉）。
     *
     * 🔴 2026-11-16 修**最严重的一个 bug**：这里原来打的是 `/v1/chat/completions`，
     * 那是**给 sk- API Key 用的**公开链路，**完全不扣墨点** ——
     * 用户：「你这个（墨点）好像都没扣过我的，我靠」。
     * 扣费实现在 `/v1/llm/chat`（认用户 token，末尾 `_settle()` 按真实 token 扣，
     * 余额不足返回 402）。单聊、群聊、日记都走这个函数，所以改一处就全生效。
     */
    fun chat(model: String, history: List<Msg>, systemPrompt: String = ""): String? {
        lastChatError = ""
        lastChatPoints = 0.0
        lastChatBalance = -1
        val arr = org.json.JSONArray()
        if (systemPrompt.isNotBlank()) {
            arr.put(JSONObject().put("role", "system").put("content", systemPrompt))
        }
        // 「从上下文移除」的消息（`skip = true`）**不发**给模型 ——
        // 用户长按选"从上下文移除"就是为了让它不再占 token、不再影响后续回答。
        // 注意：表情包/图片消息本来就转成占位文本，skip 判断放在转文本**之前**。
        // 上下文条数（2026-11-16）：只把最近 N 条发给模型，避免上下文越来越长、越来越贵。
        // 默认 12，跟改之前的行为一致（3–24 可调）。
        val win = com.aevis.android.core.ChatPrefs.ctxWindow
        history.filter { !it.skip }.takeLast(win).forEach {
            arr.put(
                JSONObject().put("role", it.role).put(
                    "content",
                    // 表情包消息（`img` 非空）**必须转成文字**再发。
                    // 接口只吃 "content" 字符串，把空 content 或 URL 塞进去会被拒（400）。
                    if (it.img.isNotEmpty())
                        if (it.content == "[图片]") "[发了一张图片]" else "[发了一个表情包]"
                    else it.content
                )
            )
        }
        // 【现实感知】环境三件套（2026-11-16）：时间 / 电量 / 网络（+ 可选城市）。
        // 全都在发请求这一刻现取，**不做监听、不常驻**（省电）。
        // 拿不到的字段**不写**（服务端那边也是"没拿到就不写、不猜"）。
        val env = envJson()

        // 每次真正发请求前，把这次用的完整 system 报给后台（变了才发）
        runCatching { reportPrompt(systemPrompt) }

        val body = JSONObject()
            .put("model", model)
            .put("messages", arr)
            // 174：把"上下文上限"也告诉服务端（客户端已 takeLast 截断，这是让它可感知）
            // 字段名用 `ctx`（服务端文档里没找到正式的，先用这个；你确认后我改）
            .put("ctx", win)
            .put("stream", false)
            .apply { if (env != null) put("env", env) }
            // 扣费来源（2026-11-16）：会员额度 / 墨点。
            // ⚠️ **只在用户显式选了「墨点优先」时才带这个字段** —— 默认（会员额度优先）就是
            // 服务端原来的行为，不带字段 = 老接口契约，避免服务端没上线时被未知字段打成 400。
            .apply {
                if (com.aevis.android.core.ChatPrefs.chargeSource == 1) {
                    put("charge_source", "points")
                }
            }

        // ⚠️ 扣费的那条接口（别改回 /v1/chat/completions，那条不扣墨点）
        var (code, json) = post("/v1/llm/chat", body, token())

        // 自动换线（2026-11-16；118 收紧到 **连续 2 次**）：
        // 只在 `code <= 0`（连不上 / 超时）时触发 —— 402 余额不足、401 登录过期换线路也没用。
        // 118：不再粗暴翻转 `preferDirect`，而是把"记住的线路"丢掉，让下一次 `call()`
        // 重新竞速 —— 竞速会自己挑出最快且真的通的那条。
        if (code <= 0 &&
            com.aevis.android.core.ChatPrefs.autoLine &&
            lineFailStreak >= 2
        ) {
            activeHost = null
            activeAt = 0L
            lineFailStreak = 0
            val r2 = post("/v1/llm/chat", body, token())
            code = r2.first
            json = r2.second
        }

        if (code !in 200..299) {
            // 这条接口的错误结构是 `{"code":4011,"msg":"..."}`，**不是** `{"error":{...}}`
            val biz = json.optInt("code", code)
            val msg = json.optJSONObject("error")?.optString("message").orEmpty()
                .ifBlank { json.optString("msg") }
            lastChatError = when {
                code == 402 || biz == 402 || msg.contains("余额") || msg.contains("墨点") ->
                    "墨点不够了，去商城充值"
                code == 401 || biz == 401 -> "登录过期，重新登录"
                msg.isNotBlank() -> msg
                else -> "请求失败（$code）"
            }
            return null
        }
        val choices = json.optJSONArray("choices")
        val msg = choices?.optJSONObject(0)?.optJSONObject("message")
        val text = msg?.optString("content").orEmpty()
        // 这次扣了多少 / 还剩多少（有就记下来，界面可以顺手显示；没有就保持 0 / -1）
        val usage = json.optJSONObject("usage")
        if (usage != null) {
            lastChatPoints = usage.optDouble("points", 0.0)
            lastChatBalance = usage.optInt("balance", -1)
            // 2026-11-16：从哪个池扣的 / 本周会员额度还剩多少（服务端新加，拿不到就空着）
            lastChargeFrom = usage.optString("charge_from")
            lastQuotaLeft = usage.optInt("quota_left", -1)
        }
        if (text.isBlank()) {
            lastChatError = "模型没返回内容"
            return null
        }
        return text
    }

    /**
     * 上传一张图片（2026-11-16）。
     *
     * 走 `POST /v1/media`（multipart，字段名 `file`），返回服务端**相对路径**
     * （`/v1/media/xxx.jpg`）—— 这个路径就是消息里的 `img`，后面渲染/发给模型都用它。
     * 失败返回 null（调用方 Toast，不要把空消息塞进列表）。
     */
    fun uploadImage(ctx: android.content.Context, uri: android.net.Uri): String? {
        val bytes = runCatching {
            ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        }.getOrNull() ?: return null
        if (bytes.isEmpty()) return null

        val boundary = "----aevis" + System.currentTimeMillis()
        var conn: java.net.HttpURLConnection? = null
        return try {
            conn = (java.net.URL(baseUrl() + "/v1/media").openConnection()
                    as java.net.HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 20000
                readTimeout = 40000
                doOutput = true
                setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
                token()?.let { setRequestProperty("Authorization", "Bearer $it") }
            }
            conn.outputStream.use { out ->
                val head = ("--$boundary\r\n"
                        + "Content-Disposition: form-data; name=\"file\"; filename=\"upload.jpg\"\r\n"
                        + "Content-Type: image/jpeg\r\n\r\n").toByteArray()
                out.write(head)
                out.write(bytes)
                out.write("\r\n--$boundary--\r\n".toByteArray())
                out.flush()
            }
            val code = conn.responseCode
            val body = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code !in 200..299) return null
            // 后端可能回 {"path":...} / {"data":{"url":...}} / 直接一个字符串，都兜住
            val txt = body.trim()
            if (txt.startsWith("/")) return txt.trim('"')
            val j = runCatching { JSONObject(txt) }.getOrNull() ?: return null
            val d = j.optJSONObject("data")
            val candidates = listOf(
                d?.optString("path").orEmpty(), d?.optString("url").orEmpty(),
                j.optString("path"), j.optString("url"), j.optString("data")
            )
            candidates.firstOrNull { it.startsWith("/") || it.startsWith("http") }
        } catch (e: Exception) {
            null
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

    // ---------------- 聊天云备份（2026-11-16）----------------
    //
    // 服务端：`GET /v1/chat/backup` 读、`POST /v1/chat/backup` 写（body `{"convs":{...}}`），
    // 一个账号一行**覆盖写**，上限 4MB（超了 413）。未登录返回 `{"code":4011,"msg":"请先登录"}`。
    //
    // 策略：**本地永远权威**。上行只在「本地有数据」时推，下行只在「本地一条会话都没有」时恢复
    // —— 否则换台手机一登录，云上的旧记录会把新聊的盖掉。

    /** 把本地所有会话打包成 `{ pid: [msg...] }`。*/
    fun packConvs(): JSONObject {
        val out = JSONObject()
        prefs().all.forEach { (k, v) ->
            if (!k.startsWith("conv_") || v !is String || v.isBlank()) return@forEach
            runCatching {
                out.put(k.removePrefix("conv_"), org.json.JSONArray(v))
            }
        }
        return out
    }

    /** 推一次云备份。失败返回 false（不抛 —— 备份失败不该影响聊天）。*/
    fun backupPush(): Boolean {
        val convs = packConvs()
        if (convs.length() == 0) return true
        val body = JSONObject().put("convs", convs)
        // 3.9MB 保险线：超过就先不传（服务端 4MB 会 413），别每次都白跑一趟
        if (body.toString().toByteArray().size > 3_900_000) return false
        val (code, json) = post("/v1/chat/backup", body, token())
        // 成功 = **HTTP 2xx 且 body.code == 0**（2026-11-16，92）。
        // 之前只看 2xx，服务端 502 兜底页/网关错误时会误判成"已同步"。
        val apiCode = json.optInt("code", -1)
        if (code in 200..299 && apiCode == 0) {
            lastBackupOkAt = System.currentTimeMillis()
            lastBackupBytes = body.toString().toByteArray().size.toLong()
            lastBackupError = ""
            return true
        }
        // 失败：HTTP 状态码 + 服务端 msg 都要留下（502 也原样显示）
        val srvMsg = json.optString("msg").orEmpty()
        // 413 = 云空间满了。服务端给的 msg 原样提示给用户（别吞成"备份失败"）。
        if (code == 413) {
            val msg = json.optString("msg").ifBlank { "空间满了，去云空间清理或扩容" }
            lastBackupError = msg
            runCatching {
                android.widget.Toast.makeText(appCtx, msg, android.widget.Toast.LENGTH_LONG).show()
            }
        } else {
            lastBackupError = buildString {
                append("HTTP ").append(code)
                if (code in 200..299 && apiCode >= 0) append(" · code ").append(apiCode)
                if (srvMsg.isNotBlank()) append(" · ").append(srvMsg)
            }
        }
        return false
    }

    /** 上一次备份失败的原因（413 = 空间满）。*/
    @Volatile
    var lastBackupError: String = ""

    /** 上一次成功同步的时间 / 大小（云空间页底部那行小字用）。*/
    @Volatile
    var lastBackupOkAt: Long = 0L

    @Volatile
    var lastBackupBytes: Long = 0L

    /** 30 秒内只推一次（每次发消息都推太费流量）。*/
    @Volatile
    private var lastBackupAt = 0L

    /** 绕过节流强制推一次（App 退到后台时用 —— 要离开了，不能再等 30 秒）。*/
    /** 有没有登录态（`token()` 是私有的，给 MainActivity 用这个）。*/
    fun tokenIsThere(): Boolean = runCatching { token() != null }.getOrDefault(false)

    fun backupPushNow() {
        lastBackupAt = System.currentTimeMillis()
        runCatching { backupPush() }
    }

    fun backupPushThrottled() {
        val now = System.currentTimeMillis()
        if (now - lastBackupAt < 30_000L) return
        lastBackupAt = now
        backupPush()
    }

    // ---------------- 个人账号卡（2026-11-16，92）----------------
    //
    // `GET /v1/account/card` → { public_id, email, email_bound, bindings:[{provider,nickname}] }
    // public_id 是给别人看的「Aevis 号」，等宽大字展示 + 可复制。

    data class Binding(val provider: String, val nickname: String)

    data class AccountCard(
        val publicId: String,
        val email: String,
        val emailBound: Boolean,
        val bindings: List<Binding>,
        val nickname: String = "",
        val avatar: String = ""
    )

    fun accountCard(): AccountCard? {
        val t = token() ?: return null
        val (code, json) = get("/v1/account/card", t)
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: return null
        val arr = d.optJSONArray("bindings")
        val list = ArrayList<Binding>()
        if (arr != null) {
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                list.add(Binding(o.optString("provider"), o.optString("nickname")))
            }
        }
        return AccountCard(
            d.optString("public_id"),
            d.optString("email"),
            d.optBoolean("email_bound", false),
            list,
            d.optString("nickname"),
            d.optString("avatar")
        )
    }

    /**
     * 把**完整 system** 报给后台（2026-11-16，102）：`POST /v1/prompt/report`（Bearer）。
     *
     * 只在 **md5 变化时**才发（进程内缓存上次 hash），失败静默、绝不阻塞聊天。
     * 这样后台能看到喂给模型的整体提示词：人设 + 规则 + 状态 + 现实感知。
     */
    @Volatile
    private var lastPromptHash: String = ""

    fun reportPrompt(sys: String) {
        if (sys.isBlank()) return
        runCatching {
            val h = md5Hex(sys)
            if (h == lastPromptHash) return
            val (c, j) = post(
                "/v1/prompt/report",
                JSONObject()
                    .put("hash", h)
                    .put("sys", sys.take(60000))
                    .put("ver", com.aevis.android.BuildConfig.VERSION_CODE.toString()),
                token()
            )
            if (c in 200..299 && j.optInt("code", 0) == 0) lastPromptHash = h
        }
    }

    /** 简易 md5（只用于"内容有没有变"的判断）。*/
    private fun md5Hex(s: String): String = runCatching {
        val d = java.security.MessageDigest.getInstance("MD5")
            .digest(s.toByteArray(Charsets.UTF_8))
        d.joinToString("") { "%02x".format(it) }
    }.getOrDefault(s.hashCode().toString())

    /**
     * 崩溃上报（2026-11-16，101）：`POST /v1/crash`，**不需要登录**。
     * 服务端写 `/opt/aevis/logs/crash.log`。
     */
    fun postCrash(tag: String, stack: String, device: String): Boolean = runCatching {
        val body = JSONObject()
            .put("tag", tag)
            .put("stack", stack.take(20000))
            .put("ver", com.aevis.android.BuildConfig.VERSION_CODE.toString())
            .put("device", device)
        val (c, j) = post("/v1/crash", body, null)
        c in 200..299 && j.optInt("code", 0) == 0
    }.getOrDefault(false)

    /** 清空云端备份（2026-11-16）：`DELETE /v1/chat/backup`。成功返回 true。*/
    fun deleteBackup(): Boolean {
        val t = token() ?: return false
        var conn: java.net.HttpURLConnection? = null
        return try {
            conn = (java.net.URL(baseUrl() + "/v1/chat/backup").openConnection()
                    as java.net.HttpURLConnection).apply {
                requestMethod = "DELETE"
                connectTimeout = 12000
                readTimeout = 30000
                setRequestProperty("Authorization", "Bearer $t")
            }
            conn.responseCode in 200..299
        } catch (e: Exception) {
            false
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

    /** 云上有几个会话（登录时用来问「云端有记录，恢复吗」）。失败/未登录返回 0。*/
    fun backupPeek(): Int = backupMeta()?.count ?: 0

    /**
     * 云备份的元信息（2026-11-16，116）。
     *
     * 服务端 `GET /v1/chat/backup` 现在除了 `convs` 还会带 `{count, bytes, at}`；
     * 老版本（或某些网关）可能只回 `convs`，所以这里两条路都兜：
     *   · `count` 没有就从 `convs.length()` 数；
     *   · `bytes` 没有就给 0（界面显示「大小未知」，不编数字）；
     *   · `at` 为 0 表示服务端没记时间 —— 这种情况不拿它跟本地比新旧。
     */
    data class BackupMeta(val count: Int, val bytes: Long, val at: Long)

    fun backupMeta(): BackupMeta? {
        if (token() == null) return null
        val (code, json) = get("/v1/chat/backup", token())
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: json
        // 123：payload 也可能是**扁平 map**（没有 convs 这层），用同一套归一函数数会话
        val convs = com.aevis.android.core.ChatArchive.convsOf(json)
        val count = d.optInt("count", convs?.length() ?: 0)
        val bytes = d.optLong("bytes", 0L)
        var at = d.optLong("at", 0L)
        // 秒/毫秒：1.7e9 以前的量级只可能是秒
        if (at in 1..1_700_000_000L) at *= 1000L
        return BackupMeta(count, bytes, at)
    }

    /** 本地最后一条聊天记录的时间（没有任何会话时返回 0）。*/
    fun lastLocalChatAt(): Long {
        var max = 0L
        prefs().all.forEach { (k, v) ->
            if (!k.startsWith("conv_at_")) return@forEach
            val t = (v as? Long) ?: return@forEach
            if (t > max) max = t
        }
        return max
    }

    /**
     * 上次恢复失败的原因（2026-11-16，116）。
     *
     * `backupPull` 的返回值只有"恢复了几个"，失败全返回 0 ——
     * 界面没法告诉用户是没登录、网关 502 还是返回体不对。所以这里记一条人话。
     */
    @Volatile
    var lastRestoreError: String = ""
        private set

    /**
     * 取本账号的**恢复码**（2026-11-16，119）。
     *
     * `POST /v1/chat/recover/code`（带 Bearer）→ `{"code":"AE7K-3M9Q"}`。
     * ⚠️ 成功时 `code` 是**字符串**，失败时 `code` 是**数字**（404 之类）——
     * 所以不能按 `optInt("code") == 0` 判成功，得看它是不是"长得像恢复码"的串。
     */
    fun recoverCode(): String? {
        val (http, json) = post("/v1/chat/recover/code", JSONObject(), token())
        if (http !in 200..299) return null
        val d = json.optJSONObject("data")
        val candidates = listOf(
            d?.optString("code").orEmpty(),
            d?.optString("recover_code").orEmpty(),
            json.optString("code")
        )
        return candidates.firstOrNull { it.length >= 6 && it.any { ch -> ch.isLetter() } }
    }

    /** 一个恢复码对应的备份概要。`hasBackup = false` 表示码对但没备份。*/
    data class RecoverStat(val hasBackup: Boolean, val bytes: Long, val at: Long)

    /**
     * 查这个恢复码有没有备份（`POST /v1/chat/recover/stat`）。
     * 返回 `(stat, 错误文案)`：stat 为 null 时看第二项。
     */
    fun recoverStat(code: String): Pair<RecoverStat?, String> {
        val (http, json) = post(
            "/v1/chat/recover/stat", JSONObject().put("code", normCode(code)), null
        )
        if (http !in 200..299) return null to "网络异常（HTTP $http）"
        // 失败时服务端回 {"code":404,"msg":"恢复码不存在"} —— code 是数字
        val biz = json.optInt("code", 0)
        if (biz != 0 && !json.has("has_backup")) {
            return null to json.optString("msg").ifBlank { "恢复码不存在" }
        }
        val d = json.optJSONObject("data") ?: json
        val has = d.optBoolean("has_backup", false)
        val bytes = d.optLong("bytes", 0L)
        var at = parseIsoTime(d.optString("at"))
        if (at == 0L) {
            // 也兼容数字时间戳（秒/毫秒）
            val raw = d.optLong("at", 0L)
            at = if (raw in 1..1_700_000_000L) raw * 1000L else raw
        }
        return RecoverStat(has, bytes, at) to ""
    }

    /**
     * 用恢复码拉回完整备份（`POST /v1/chat/recover`）。
     * 返回 `(backupJson, 错误文案)`，backupJson 是 `{"convs":{…}}` 这种完整 JSON 串。
     */
    fun recoverPull(code: String): Pair<String, String> {
        val (http, json) = post(
            "/v1/chat/recover", JSONObject().put("code", normCode(code)), null
        )
        if (http !in 200..299) return "" to "网络异常（HTTP $http）"
        val biz = json.optInt("code", 0)
        val d = json.optJSONObject("data") ?: json
        val backup = d.optString("backup")
        if (backup.isBlank()) {
            val msg = json.optString("msg").ifBlank {
                if (biz == 404) "恢复码不存在" else "这个恢复码还没有备份"
            }
            return "" to msg
        }
        return backup to ""
    }

    /**
     * 恢复码归一（2026-11-16，122）。
     *
     * 服务端做的是 `replace("-","").strip().upper()`，所以客户端**只需要吐出 8 位 A-Z0-9**：
     * 横杠、空格、小写、全角字符全部在这里吃掉。
     * ⚠️ 别在这儿做「必须 8 位/必须带横杠」这种校验 —— 那是界面的事，
     *    而且一旦校验错就会把合法输入挡在门外（122 就是这么报的"格式失败"）。
     */
    fun normCode(raw: String): String {
        val sb = StringBuilder(8)
        raw.forEach { ch ->
            val c = when {
                ch in '0'..'9' -> ch
                ch in 'A'..'Z' -> ch
                ch in 'a'..'z' -> ch - 32
                // 全角数字 / 大写 / 小写（中文输入法下很容易打出来）
                ch.code in 0xFF10..0xFF19 -> (ch.code - 0xFF10 + '0'.code).toChar()
                ch.code in 0xFF21..0xFF3A -> (ch.code - 0xFF21 + 'A'.code).toChar()
                ch.code in 0xFF41..0xFF5A -> (ch.code - 0xFF41 + 'A'.code).toChar()
                else -> null
            }
            if (c != null) sb.append(c)
        }
        return sb.toString()
    }

    /** `2026-11-16T15:36:45Z` / `2026-11-16T15:36:45+08:00` → 毫秒。解析不了返回 0。*/
    private fun parseIsoTime(s: String): Long {
        if (s.isBlank()) return 0L
        val pats = listOf(
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd HH:mm:ss"
        )
        pats.forEach { p ->
            val v = runCatching {
                val f = java.text.SimpleDateFormat(p, java.util.Locale.US)
                f.timeZone = java.util.TimeZone.getTimeZone("UTC")
                f.parse(s)?.time
            }.getOrNull()
            if (v != null && v > 0) return v
        }
        return 0L
    }

    /**
     * 拉云备份，返回恢复了几个会话。
     *
     * `force = false`（默认）：**只在本地一条会话都没有时**恢复 —— 防止换手机登录时
     * 云上的旧记录把新聊的盖掉。
     * `force = true`：用户明确点了「恢复」，照做。
     */
    fun backupPull(force: Boolean = false): Int {
        lastRestoreError = ""
        if (!force && prefs().all.keys.any { it.startsWith("conv_") }) return 0
        val (code, json) = get("/v1/chat/backup", token())
        if (code !in 200..299) {
            lastRestoreError = "网络异常（HTTP $code）"
            return 0
        }
        // 123：扁平 map / 带 convs 的壳 / data 包装，三种都认
        val convs = com.aevis.android.core.ChatArchive.convsOf(json)
        if (convs == null) {
            lastRestoreError = "云端没有可恢复的记录"
            return 0
        }
        var n = 0
        val ed = prefs().edit()
        convs.keys().forEach { pid ->
            val arr = convs.optJSONArray(pid) ?: return@forEach
            if (arr.length() == 0) return@forEach
            ed.putString(convKey(pid), arr.toString())
            n++
        }
        ed.apply()
        if (n == 0) lastRestoreError = "云端备份是空的"
        return n
    }

    // ---------------- 导出 / 导入聊天记录（2026-11-16）----------------
    //
    // 导出结构**和云备份的 `convs` 一致**（`{ pid: [msg...] }`），外加 `app` / `exported_at`，
    // 这样导出的文件既能自己留档，也能直接喂回导入。

    /** 导出用的 JSON 全文（结构同云备份）。*/
    fun exportConvsJson(): String {
        val o = JSONObject()
        o.put("app", "aevis-android")
        o.put("version", com.aevis.android.BuildConfig.VERSION_NAME)
        o.put("exported_at", System.currentTimeMillis() / 1000L)
        o.put("convs", packConvs())
        return o.toString()
    }

    /**
     * 导入：校验结构后**覆盖写**本地，再推一次云备份。返回导入的会话数，结构不对返回 -1。
     *
     * ⚠️ 先整体校验再写：不能读到一半发现结构不对，留下半套数据。
     */
    fun importConvsJson(text: String): Int {
        val o = runCatching { JSONObject(text) }.getOrNull() ?: return -1
        val convs = o.optJSONObject("convs") ?: return -1
        if (convs.length() == 0) return -1
        // 先校验：每个值必须是数组，且每条消息至少有 role/content
        val pids = convs.keys()
        while (pids.hasNext()) {
            val pid = pids.next()
            val arr = convs.optJSONArray(pid) ?: return -1
            for (i in 0 until arr.length()) {
                val m = arr.optJSONObject(i) ?: return -1
                if (!m.has("role") || !m.has("content")) return -1
            }
        }
        // 校验通过 → 覆盖写
        val ed = prefs().edit()
        prefs().all.keys.filter { it.startsWith("conv_") }.forEach { ed.remove(it) }
        var n = 0
        val it2 = convs.keys()
        while (it2.hasNext()) {
            val pid = it2.next()
            val arr = convs.optJSONArray(pid) ?: continue
            ed.putString(convKey(pid), arr.toString())
            ed.putLong(convAtKey(pid), System.currentTimeMillis())
            n++
        }
        ed.apply()
        runCatching { backupPush() }
        return n
    }

    // ---------------- 更新日志（2026-11-16）----------------
    //
    // `GET /v1/app/changelog` → { data: { items: [ { version, date, items: [...] } ] } }

    data class ChangeLog(val version: String, val date: String, val items: List<String>)

    fun changeLog(): List<ChangeLog> {
        val (code, json) = get("/v1/app/changelog", token())
        if (code !in 200..299) return emptyList()
        val arr = json.optJSONObject("data")?.optJSONArray("items") ?: return emptyList()
        val out = ArrayList<ChangeLog>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val lines = o.optJSONArray("items") ?: continue
            val ls = ArrayList<String>(lines.length())
            for (j in 0 until lines.length()) {
                val t = lines.optString(j)
                if (t.isNotBlank()) ls.add(t)
            }
            out.add(ChangeLog(o.optString("version"), o.optString("date"), ls))
        }
        return out
    }

    // ---------------- 云空间（2026-11-16）----------------
    //
    // `GET /v1/cloud/usage` → { used, quota, percent, chat_bytes, chat_at }
    // 默认每人 1GB；超了备份接口会回 413 + "空间满了，去云空间清理或扩容"。
    // 拿不到就返回 null，界面显示 `—`（**不显示 0** —— 0 会让人以为空间用光了）。

    data class CloudUsage(
        val used: Long,
        val quota: Long,
        val percent: Float,
        val chatBytes: Long,
        val chatAt: String
    )

    /**
     * 拿图片**原始字节**（2026-11-16，94）。
     * 头像要支持 GIF / animated WebP，`BitmapFactory` 会把动图解码成第一帧，
     * 所以这里给 `ImageDecoder.createSource(ByteBuffer)` 用。
     */
    fun fetchImageRaw(url: String): ByteArray? {
        var conn: java.net.HttpURLConnection? = null
        return try {
            val full = if (url.startsWith("http")) url else baseUrl() + url
            conn = (java.net.URL(full).openConnection() as java.net.HttpURLConnection).apply {
                connectTimeout = 10000
                readTimeout = 20000
                setRequestProperty("User-Agent", "AevisAndroid")
            }
            if (conn.responseCode !in 200..299) return null
            conn.inputStream.use { it.readBytes() }
        } catch (e: Exception) {
            null
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

    fun cloudUsage(): CloudUsage? {
        val t = token() ?: return null
        val (code, json) = get("/v1/cloud/usage", t)
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: return null
        return CloudUsage(
            d.optLong("used", 0L),
            d.optLong("quota", 0L),
            d.optDouble("percent", 0.0).toFloat(),
            d.optLong("chat_bytes", 0L),
            d.optString("chat_at")
        )
    }

    // ---------------- 现实感知（2026-11-16）----------------
    //
    // 让角色知道"真实世界的当下"：本机时间、电量、充没充电、什么网络、用户在哪个城市。
    // 用户可以在聊天页 ⋯ 里关掉（`ChatPrefs.realityAware`），关了就不传整个 `env`。
    // 全部**现取**，不注册监听器（常驻监听是耗电大户，而这条每次发消息取一次就够）。

    /** 电量百分比，拿不到 -1。*/
    private fun batteryPct(): Int = runCatching {
        val bm = appCtx.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
        bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
    }.getOrDefault(-1)

    /** 在充电吗（充电 / 已充满都算 true）。*/
    private fun charging(): Boolean = runCatching {
        val i = appCtx.registerReceiver(
            null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED)
        ) ?: return false
        val st = i.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1)
        st == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            st == android.os.BatteryManager.BATTERY_STATUS_FULL
    }.getOrDefault(false)

    /** "wifi" / "mobile" / "offline"。*/
    private fun netKind(): String = runCatching {
        val cm = appCtx.getSystemService(Context.CONNECTIVITY_SERVICE)
            as android.net.ConnectivityManager
        val n = cm.activeNetwork ?: return "offline"
        val cap = cm.getNetworkCapabilities(n) ?: return "offline"
        when {
            cap.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            cap.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            else -> "other"
        }
    }.getOrDefault("offline")

    /**
     * 组装 `env`；关掉现实感知时返回 null（= 请求里不带这个键）。
     * `city` 为空**不写这个键** —— 服务端会当"没给"，写空串反而可能被当成一个城市名去查天气。
     */
    private fun envJson(): JSONObject? {
        if (!com.aevis.android.core.ChatPrefs.realityAware) return null
        val tz = runCatching { java.util.TimeZone.getDefault().id }.getOrDefault("")
        val o = JSONObject()
            .put("ts", System.currentTimeMillis() / 1000L)
            .put("battery", batteryPct())
            .put("charging", charging())
            .put("net", netKind())
        if (tz.isNotBlank()) o.put("tz", tz)
        val city = com.aevis.android.core.ChatPrefs.city
        if (city.isNotBlank()) o.put("city", city)
        return o
    }

    // ---------------- 钱包（2026-11-16）----------------
    //
    // 服务端：`GET /v1/llm/wallet`（Bearer token）
    //   → { code, data: { points, member: { active, week_total, week_used, week_left, plan_end, week_start } } }
    // 会员改成按周发额度之后，「我还能聊多少」要看两个数：墨点 + 本周会员额度。
    // 失败返回 null（**不抛**），调用方退回 `Api.balance()` 只显示墨点。

    data class MemberQuota(
        val active: Boolean,
        val weekTotal: Int,
        val weekUsed: Int,
        val weekLeft: Int,
        val planEnd: String,
        val weekStart: String
    )

    data class Wallet(val points: Int, val member: MemberQuota?)

    fun wallet(): Wallet? {
        val t = token() ?: return null
        val (code, json) = get("/v1/llm/wallet", t)
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: return null
        val m = d.optJSONObject("member")
        return Wallet(
            d.optInt("points", 0),
            if (m == null) null else MemberQuota(
                m.optBoolean("active", false),
                m.optInt("week_total", 0),
                m.optInt("week_used", 0),
                m.optInt("week_left", 0),
                m.optString("plan_end"),
                m.optString("week_start")
            )
        )
    }

    // ---------------- 主页用量（2026-11-24，对标 iOS quotaState）----------------
    //
    // GET /v1/quota/state → data.quota { active, percent, left_pct, has_quota }。
    // 产品口径：主页用量卡只展示**百分比**，不写死数字、不按点数估算。
    // 取不到 → 返回 null，界面显示"—"，绝不回落成 92% / 6% 这种假数。

    data class QuotaState(
        val active: Boolean,
        val percent: Int,       // 本周已用百分比 0–100
        val leftPct: Int,       // 本周剩余百分比 0–100
        val hasQuota: Boolean,
        val resetAt: String = "",  // 重置时间（ISO-8601，取不到留空不显示）
        // 2026-11-25 服务端新增：本周剩余额度折成"还能聊多少条"（会员/免费都对）。
        // 0 = 老服务端没给，调用方回落到「免费基线 × 剩余百分比」。
        val estMessages: Int = 0
    )

    fun quotaState(): QuotaState? {
        val (code, json) = get("/v1/quota/state", token())
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: json
        val q = d.optJSONObject("quota") ?: d
        // 有些部署把字段直接铺在 data 上，没有 quota 这层，两种都兜一下
        val left = q.optInt("left_pct", 0)
        val reset = q.optString("reset_at")
            .ifEmpty { q.optString("next_reset") }
            .ifEmpty { q.optString("resetAt") }
            .ifEmpty { d.optString("reset_at") }
        return QuotaState(
            active = q.optBoolean("active", false),
            percent = q.optInt("percent", 0),
            leftPct = left,
            hasQuota = if (q.has("has_quota")) q.optBoolean("has_quota") else left > 0,
            resetAt = reset,
            estMessages = q.optInt("est_messages", 0).let {
                if (it > 0) it else d.optInt("est_messages", 0)
            }
        )
    }

    /** 广场数据带"是否联网成功"的返回：失败时 ok=false，list 保留旧值由调用方决定。*/
    data class ListResult<T>(val items: List<T>, val ok: Boolean)

    fun personasChecked(): ListResult<Persona> {
        val (code, json) = getWith(
            "/v1/psquare/list", mapOf("X-Account" to email()), token()
        )
        if (code !in 200..299) return ListResult(emptyList(), false)
        val d = json.optJSONObject("data") ?: return ListResult(emptyList(), false)
        val arr = d.optJSONArray("rows") ?: d.optJSONArray("items")
            ?: return ListResult(emptyList(), true)   // 200 但空 = 真的空，联网成功
        val out = ArrayList<Persona>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                Persona(
                    o.optString("id"), o.optString("name"),
                    o.optString("tagline").ifEmpty { o.optString("personality") },
                    o.optString("avatar_url"), o.optInt("adopt_count"),
                    o.optInt("is_official") == 1, o.optString("relation")
                )
            )
        }
        return ListResult(out, true)
    }

    fun emojiPacksChecked(): ListResult<EmojiPack> {
        val (code, json) = getWith("/v1/emoji/list", emptyMap(), token())
        if (code !in 200..299) return ListResult(emptyList(), false)
        val d = json.optJSONObject("data") ?: return ListResult(emptyList(), false)
        val arr = d.optJSONArray("rows") ?: return ListResult(emptyList(), true)
        val out = ArrayList<EmojiPack>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val items = o.optJSONArray("items")
            val urls = ArrayList<String>(items?.length() ?: 0)
            if (items != null) {
                for (j in 0 until items.length()) {
                    val u = items.optString(j)
                    if (u.isNotEmpty()) urls.add(u)
                }
            }
            out.add(
                EmojiPack(
                    o.optString("id"), o.optString("name"), o.optString("intro"),
                    o.optString("cover_url").ifEmpty { urls.firstOrNull().orEmpty() },
                    o.optInt("count").let { if (it > 0) it else urls.size },
                    o.optInt("is_official") == 1, urls
                )
            )
        }
        return ListResult(out, true)
    }

    // ---------------- 语音合成（2026-11-16）----------------
    //
    // 服务端现成接口（MiniMax 已配好）：
    //   POST /v1/tts/speech  {"input": "...", "voice": "<id>"} → **audio/mpeg 字节流**（不是 JSON！）
    //   GET  /v1/tts/voices  → 音色列表
    // 所以不能用 `post()`（那个会按 JSON 解析），这里单独走 HttpURLConnection。

    /** 音色列表：id → 显示名。失败返回空列表。*/
    fun ttsVoices(): List<Pair<String, String>> {
        val (code, json) = get("/v1/tts/voices", token())
        if (code !in 200..299) return emptyList()
        val arr = json.optJSONArray("data") ?: json.optJSONArray("voices") ?: return emptyList()
        val out = ArrayList<Pair<String, String>>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optString("id").ifBlank { o.optString("voice_id") }
            if (id.isBlank()) continue
            out.add(id to o.optString("name").ifBlank { id })
        }
        return out
    }

    /** 合成语音，返回 mp3 字节。失败返回 null（503 = 还没开通，调用方给一句人话）。*/
    fun ttsSpeech(text: String, voice: String): ByteArray? {
        if (text.isBlank()) return null
        var conn: java.net.HttpURLConnection? = null
        return try {
            conn = (java.net.URL(baseUrl() + "/v1/tts/speech").openConnection()
                    as java.net.HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15000
                readTimeout = 60000
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                token()?.let { setRequestProperty("Authorization", "Bearer $it") }
            }
            val body = JSONObject().put("input", text).put("voice", voice).toString()
            conn.outputStream.use { it.write(body.toByteArray()) }
            val code = conn.responseCode
            if (code !in 200..299) return null
            conn.inputStream.use { it.readBytes() }
        } catch (e: Exception) {
            null
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

    /** 当前默认音色：先看 `me()` 里的人设 voice，没有就用音色列表第一个（不硬编码名字）。*/
    fun defaultVoice(): String {
        val mine = cachedMe()?.voice.orEmpty()
        if (mine.isNotBlank()) return mine
        return ttsVoices().firstOrNull()?.first.orEmpty()
    }

    // ---------------- 支付会话（2026-11-15）----------------

    /**
     * 向**我们服务端**要一次性支付链接。
     *
     * 用户给的架构：App 先打我们服务端 → 服务端生成订单 + 一次性 token（5 分钟）→
     * 返回 `https://aevis.cn/pay/?t=xxx`。URL 里**不含用户名**，过期即销毁。
     */
    fun paySession(product: String): String? = paySessionInfo(product)?.first

    /**
     * 支付订单三元组（2026-11-25 聚合码）：(收银台 url, code_url, pay_link)。
     * `pay_link` 是服务端聚合短链，微信 / 支付宝扫**同一张码**按 UA 自动分流。
     * 空串 = 老服务端还没下发，退回 code_url / 收银台 url。
     */
    data class PaySessionInfo(val url: String, val codeUrl: String, val payLink: String) {
        /** 二维码真正应编码的内容：优先聚合短链。*/
        val qrContent: String get() = payLink.ifEmpty { codeUrl.ifEmpty { url } }
    }

    /** 下单，带聚合短链。老调用点 paySessionInfo 返回 Pair 的行为不变。*/
    fun paySessionInfoV2(product: String): PaySessionInfo? {
        val legacy = paySessionInfo(product) ?: return null
        // pay_link 从最后一次下单响应读 —— 见 paySessionInfo 内部解析
        return PaySessionInfo(legacy.first, legacy.second, lastPayLink)
    }

    /** 最近一次 paySession 的聚合短链（paySessionInfo 解析时填）。*/
    @Volatile
    var lastPayLink: String = ""

    /**
     * 下单（2026-11-16，100）：body 带 **uid + account(email)**（后端按这两个对账）。
     *
     * 返回 `(收银台 url, code_url)`；`code_url` 是微信 Native 的支付串（收银台改完才会有，
     * 现在一般是空串 → 界面退化成"打开收银台页面"）。
     * 失败返回 null，原因写进 [lastPayError]（界面要显示服务端 msg，不能只说"失败"）。
     */
    @Volatile
    var lastPayError: String = ""

    fun paySessionInfo(product: String): Pair<String, String>? {
        lastPayError = ""
        lastPayLink = ""
        val body = JSONObject().put("product", product)
        runCatching {
            val me = cachedMe() ?: me()
            if (me != null) {
                body.put("uid", me.uid)
                body.put("account", me.email)
            }
        }
        val (c, j) = post("/v1/pay/session", body, token())
        if (c !in 200..299) {
            lastPayError = "HTTP $c"
            return null
        }
        if (j.optInt("code", -1) != 0) {
            lastPayError = j.optString("msg").ifBlank { "下单失败" }
            return null
        }
        val d = j.optJSONObject("data") ?: return null
        val url = d.optString("url")
        if (!url.startsWith("http")) {
            lastPayError = "返回里没有收银台地址"
            return null
        }
        // 2026-11-25 聚合短链：微信 / 支付宝扫同一张码，按 UA 自动分流
        lastPayLink = d.optString("pay_link").ifEmpty { d.optString("payLink") }
        return url to d.optString("code_url")
    }

    // ---------------- 签到（2026-11-15）----------------

    data class CheckinState(
        val done: Boolean, val streak: Int, val monthCount: Int,
        val totalPoints: Int, val days: List<String>, val nextReward: Int
    )

    data class CheckinResult(val already: Boolean, val points: Int, val streak: Int)

    fun checkinStatus(): CheckinState? {
        val (c, j) = get("/v1/checkin/status", token())
        android.util.Log.e("AevisCheckin", "status code=" + c + " body=" + j.toString().take(200))
        if (c !in 200..299) return null
        val d = j.optJSONObject("data") ?: return null
        val arr = d.optJSONArray("days")
        val ds = ArrayList<String>()
        if (arr != null) for (i in 0 until arr.length()) ds.add(arr.optString(i))
        return CheckinState(
            done = d.optBoolean("done"),
            streak = d.optInt("streak"),
            monthCount = d.optInt("monthCount"),
            totalPoints = d.optInt("totalPoints"),
            days = ds,
            nextReward = d.optInt("nextReward", 1)
        )
    }

    fun checkin(): CheckinResult? {
        val (c, j) = post("/v1/checkin", JSONObject(), token())
        android.util.Log.e("AevisCheckin", "code=" + c + " body=" + j.toString().take(200))
        if (c !in 200..299) return null
        val d = j.optJSONObject("data") ?: return null
        return CheckinResult(
            already = d.optBoolean("already"),
            points = d.optInt("points"),
            streak = d.optInt("streak")
        )
    }

    // ---------------- 微信 ClawBot 绑定（2026-11-15）----------------

    /** 出码。服务端保证「一个账号只有一个有效码」，重出会顶掉旧的。返回二维码内容串。*/
    fun wxClawQr(): String? {
        val (c, j) = post("/v1/wxbot/claw/qr", org.json.JSONObject(), token())
        if (c !in 200..299) return null
        val d = j.optJSONObject("data") ?: return null
        return d.optString("url").takeIf { it.startsWith("http") }
    }

    /** 查扫码状态：wait / ok / expired / none。*/
    fun wxClawStatus(): String? {
        val (c, j) = get("/v1/wxbot/claw/status", token())
        if (c !in 200..299) return null
        val d = j.optJSONObject("data") ?: return null
        val st = d.optString("status").ifBlank { "wait" }
        if (st == "ok") {
            val bot = d.optString("bot_account")
            if (bot.isNotBlank()) {
                prefs().edit().putString("wx_bot", bot).apply()
            }
        }
        return st
    }

    /** 我当前的绑定：(bot_account, persona)，没绑过返回 ("","").*/
    fun wxMy(): Pair<String, String>? {
        val (c, j) = get("/v1/wxbot/my", token())
        if (c !in 200..299) return null
        val d = j.optJSONObject("data") ?: return Pair("", "")
        return Pair(d.optString("bot_account"), d.optString("persona"))
    }

    /** 绑定：选人设 + 选模型（模型就是扣费依据）。*/
    fun wxBind(persona: String, model: String): Boolean {
        val bot = prefs().getString("wx_bot", "").orEmpty()
        val body = JSONObject()
            .put("bot_account", bot.ifBlank { "clawbot" })
            .put("persona", persona)
            .put("model", model)
        val (c, _) = post("/v1/wxbot/bind", body, token())
        return c in 200..299
    }

    /** 二维码内容串 → Bitmap（本地画，不依赖第三方库）。*/
    fun qrToBitmap(content: String): android.graphics.Bitmap? = runCatching {
        val size = 640
        val bits = com.google.zxing.qrcode.QRCodeWriter()
            .encode(content, com.google.zxing.BarcodeFormat.QR_CODE, size, size)
        val bmp = android.graphics.Bitmap.createBitmap(size, size,
            android.graphics.Bitmap.Config.ARGB_8888)
        for (x in 0 until size) {
            for (y in 0 until size) {
                bmp.setPixel(x, y, if (bits[x, y]) android.graphics.Color.BLACK
                else android.graphics.Color.WHITE)
            }
        }
        bmp
    }.getOrNull()

    // ---------------- 模型状态（2026-11-15）----------------

    /** 一个可选模型：id、显示名、是否在线、可用率、单价（墨点/次，约）。*/
    data class ModelInfo(
        val id: String,
        val label: String,
        val online: Boolean,
        val uptime: Double,
        val points: Double
    )

    /**
     * 拉到可切换的模型 + 在线状态。
     *
     * 价格走 `/v1/llm/models`（用户可见价），状态走 `/v1/llm/status`（uptime）。
     * 两个都失败就退回本地写死的四个常用模型，保证弹窗永远有东西可选。
     */
    /**
     * 模型显示名兜底。
     *
     * ⚠️ 正常情况下用服务端 `label`（"DeepSeek 官方版" 这种，后台可改）。
     * 这个只在 label 为空时把 id 拼成能读的样子：`deepseek-flash` → `Deepseek Flash`。
     * 不要在这里写死中文名 —— 用户 2026-11-15 明确要求「同步官网的模型状态」。
     */
    fun displayName(id: String): String {
        val parts = id.split("-").filter { it.isNotBlank() }
        if (parts.isEmpty()) return id
        return parts.joinToString(" ") { p ->
            when {
                p.length <= 3 && (p.all { it.isDigit() || it == '.' } || p.all { it.isDigit() }) -> p
                p.lowercase() == "deepseek" -> "DeepSeek"
                else -> p.replaceFirstChar { it.uppercase() }
            }
        }
    }

    fun modelList(): List<ModelInfo> {
        // 在线状态
        val status = HashMap<String, Pair<Boolean, Double>>()
        runCatching {
            val (c, j) = get("/v1/llm/status", token())
            if (c in 200..299) {
                val d = j.optJSONObject("data") ?: j
                val arr = d.optJSONArray("rows") ?: d.optJSONArray("models")
                    ?: d.optJSONArray("data")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        val m = o.optString("model").ifBlank { o.optString("id") }
                        if (m.isBlank()) continue
                        status[m] = Pair(
                            o.optBoolean("online"),
                            o.optDouble("uptime", 100.0)
                        )
                    }
                }
            }
        }

        // 模型清单 + 后台配的 label + 单价
        //
        // ⚠️ 2026-11-15 修：这个接口返回的是 `data.models`（不是 `rows`），
        //    字段是驼峰（`perCallPoints` / `inputPointsPerM`），`label` 服务端**一直都有**
        //    （"DeepSeek 官方版" 这种）。之前解析错了，所以界面上显示的是我们自己编的
        //    「快速版/免费版」，跟官网对不上。
        val out = ArrayList<ModelInfo>()
        runCatching {
            val (c, j) = get("/v1/llm/models", token())
            if (c in 200..299) {
                val arr = j.optJSONObject("data")?.optJSONArray("models")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        val id = o.optString("id")
                        if (id.isBlank()) continue
                        val perCall = o.optDouble("perCallPoints", 0.0)
                        val inPerM = o.optDouble("inputPointsPerM", 0.0)
                        val st = status[id]
                        out.add(
                            ModelInfo(
                                id = id,
                                label = o.optString("label").ifBlank { displayName(id) },
                                online = st?.first ?: true,
                                uptime = st?.second ?: 100.0,
                                points = if (perCall > 0) perCall else inPerM / 1000.0 * 2.0
                            )
                        )
                    }
                }
            }
        }

        if (out.isEmpty()) {
            // 接口全挂时的兜底，保证弹窗/页面不至于空着
            return FALLBACK_MODELS.map {
                ModelInfo(it, displayName(it), true, 100.0, 0.0)
            }
        }
        return out.sortedBy { m ->
            when (m.id) {
                "deepseek-flash" -> 0
                "deepseek-web" -> 1
                "deepseek-v4-pro" -> 2
                "deepseek-reasoner" -> 3
                else -> 10
            }
        }
    }

    // ---------------- 商城商品（2026-11-24，对标 iOS ShopProduct）----------------
    //
    // 服务端驱动：会员几档、多少钱、按次套餐、权益文案全从 /v1/shop/products 读，
    // 客户端**不写死价格**（iOS 2.8 明确：档位数量与价格由服务端决定）。
    data class ShopProduct(
        val id: String,
        val title: String,
        val days: Int,
        val priceCents: Int,
        val weekTotal: Int = 0,
        val percent: Int = 0,
        val label: String = "",
        val kind: String = "member",   // "member" / "uses"
        val uses: Int = 0,
        val listPriceCents: Int = 0,   // 面价（划线原价）；0 = 没给
        val discountPercent: Int = 100,
        val benefits: List<String> = emptyList(),
        val grantPoints: Int = 0,
        val freeMinutes: Int = 0,
        val signinBonus: Int = 0,
        val usesPerYuan: Int = 0,
        val minSellUses: Int = 0
    )

    /** GET /v1/shop/products（无需 token）。失败返回空列表。*/
    fun shopProducts(): List<ShopProduct> {
        val (code, json) = get("/v1/shop/products", null)
        if (code !in 200..299) return emptyList()
        val d = json.optJSONObject("data") ?: json
        val arr = d.optJSONArray("items") ?: d.optJSONArray("rows") ?: return emptyList()
        val out = ArrayList<ShopProduct>(arr.length())
        for (i in 0 until arr.length()) {
            val r = arr.optJSONObject(i) ?: continue
            val id = r.optString("id").ifEmpty { r.optInt("id").toString() }
            if (id.isBlank() || id == "0") continue
            val benefits = ArrayList<String>()
            r.optJSONArray("benefits")?.let { ba ->
                for (k in 0 until ba.length()) benefits.add(ba.optString(k))
            }
            out.add(
                ShopProduct(
                    id = id, title = r.optString("title"), days = r.optInt("days"),
                    priceCents = r.optInt("price_cents"), weekTotal = r.optInt("week_total"),
                    percent = r.optInt("percent"), label = r.optString("label"),
                    kind = r.optString("kind", "member"), uses = r.optInt("uses"),
                    listPriceCents = r.optInt("list_price_cents"),
                    discountPercent = r.optInt("discount_percent", 100),
                    benefits = benefits, grantPoints = r.optInt("grant_points"),
                    freeMinutes = r.optInt("free_minutes"),
                    signinBonus = r.optInt("signin_bonus"),
                    usesPerYuan = r.optInt("uses_per_yuan"),
                    minSellUses = r.optInt("min_sell_uses")
                )
            )
        }
        return out
    }

    // ---------------- 模型状态（2026-11-24，对标官网 / iOS /v1/models/status）----------------
    //
    // 用户：「模型状态你不应该都是能看到历史的一个记录吗？你现在只有一个小圆点」。
    // 改成读 `/v1/models/status`（官网/iOS 同源，无需 token），每行带历史探测序列 +
    // 四态当前状态。解析口径严格照 iOS ServerStatusView.build / liveStatus。

    /** 每行模型状态。`samples` = 历史竖条（true 绿 / false 红）；空 = 没数据画灰占位。*/
    data class ModelStatus(
        val model: String,
        val state: Int,          // 0 正常 / 1 波动 / 2 异常 / 3 未监控（无 providers）
        val samples: List<Boolean>,
        val rangeLabel: String,  // "近 30 分钟" / "近 24 小时" / ""
        val rate: Double,        // 0..1 可用率
        val avgLatencySec: Double?,
        val recentSource: String,
        val coverageMinutes: Int,
        val officialState: String,   // 官方状态 state（stale=false 才有）
        val officialDetail: String
    ) {
        companion object {
            const val OK = 0
            const val UNSTABLE = 1
            const val DOWN = 2
            const val UNKNOWN = 3
        }
    }

    /** GET /v1/models/status，无需 token。失败返回 null（调用方用 relayStatus 缓存兜底）。*/
    fun modelsStatus(): List<ModelStatus>? {
        val (code, json) = get("/v1/models/status", null)
        if (code !in 200..299) return null
        val arr = json.optJSONObject("data")?.optJSONArray("rows")
            ?: json.optJSONArray("rows")
            ?: return null
        val out = ArrayList<ModelStatus>(arr.length())
        for (i in 0 until arr.length()) {
            val row = arr.optJSONObject(i) ?: continue
            val model = row.optString("model")
            if (model.isBlank()) continue

            // 当前状态：providers[].alive（任一存活）。alive 但 fail_count>0 = 波动。
            val providers = row.optJSONArray("providers")
            var state = ModelStatus.UNKNOWN
            if (providers != null && providers.length() > 0) {
                var alive = 0
                var failSum = 0
                for (k in 0 until providers.length()) {
                    val p = providers.optJSONObject(k) ?: continue
                    if (p.optBoolean("alive", false)) {
                        alive++
                        failSum += p.optInt("fail_count", 0)
                    }
                }
                state = when {
                    alive == 0 -> ModelStatus.DOWN
                    failSum > 0 -> ModelStatus.UNSTABLE
                    else -> ModelStatus.OK
                }
            }

            // 历史：recent 近 30 分钟逐点（>=0.5 判绿）；没有则用 history 30 分钟分桶
            val samples = ArrayList<Boolean>()
            var okSum = 0
            var totalSum = 0
            var range = ""
            val recent = row.optJSONArray("recent")
            if (recent != null && recent.length() > 0) {
                for (k in 0 until recent.length()) {
                    val ok = recent.optDouble(k, 0.0) >= 0.5
                    samples.add(ok)
                    if (ok) okSum++
                    totalSum++
                }
                range = "近 30 分钟"
            }
            if (samples.isEmpty()) {
                val history = row.optJSONArray("history")
                if (history != null) {
                    for (k in 0 until history.length()) {
                        val h = history.optJSONObject(k) ?: continue
                        val t = h.optInt("total", 0)
                        if (t <= 0) continue   // 空桶跳过，别把"没探测过"画成红
                        val ok = h.optInt("ok", 0)
                        okSum += ok
                        totalSum += t
                        samples.add(ok >= t)   // 一桶全成功才绿
                    }
                    if (totalSum > 0) range = "近 24 小时"
                }
            }
            val rate = if (totalSum > 0) (okSum.toDouble() / totalSum).coerceIn(0.0, 1.0) else 0.0

            // 官方状态：stale=false 才显示（过期结论不摆给用户）
            var officialState = ""
            var officialDetail = ""
            val official = row.optJSONObject("official_status")
            if (official != null && !official.optBoolean("stale", false)) {
                officialState = official.optString("state")
                officialDetail = official.optString("detail")
            }

            val latency = if (row.isNull("avg_latency_sec")) null
                          else row.optDouble("avg_latency_sec", Double.NaN).let {
                              if (it.isNaN()) null else it
                          }
            out.add(
                ModelStatus(
                    model = model,
                    state = state,
                    samples = samples,
                    rangeLabel = range,
                    rate = rate,
                    avgLatencySec = latency,
                    recentSource = row.optString("recent_source"),
                    coverageMinutes = row.optInt("coverage_minutes", 0),
                    officialState = officialState,
                    officialDetail = officialDetail
                )
            )
        }
        return out
    }

    private val FALLBACK_MODELS = listOf(
        "deepseek-flash", "deepseek-web", "deepseek-v4-pro", "deepseek-reasoner"
    )

    /** 长 id → 界面上好认的短名。内部标识不直接给用户看。*/
    fun shortLabel(id: String): String = when (id) {
        "deepseek-flash" -> "快速版"
        "deepseek-web" -> "免费版"
        "deepseek-v4-pro" -> "高级版"
        "deepseek-reasoner" -> "深思版"
        "deepseek-chat" -> "标准版"
        else -> id
    }

    /** 会话记录（本地存，`pid` 是人设 id）。*/
    /**
     * 枚举**所有有消息的 pid**（2026-11-17，P0 诊断 + 孤儿救济用）。
     * 会话存在 prefs 的 `conv_<pid>` 键里，不是文件 —— 所以这里扫 prefs，不扫目录。
     */
    fun allConvPids(): List<String> = runCatching {
        prefs().all.keys
            .filter { it.startsWith("conv_") && !it.startsWith("conv_at_") }
            .map { it.removePrefix("conv_") }
            .filter { it.isNotBlank() }
    }.getOrDefault(emptyList())

    private fun convKey(pid: String) = "conv_" + pid

    fun loadConv(pid: String): List<Msg> {
        val raw = prefs().getString(convKey(pid), "") ?: return emptyList()
        if (raw.isBlank()) return emptyList()
        return runCatching {
            val arr = org.json.JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                // `w` 是群聊的发言人（人设 id）；`i` 是表情包图片路径。
                // 老数据没这两个字段 → 空串，正好是默认值
                Msg(
                    o.optString("role"), o.optString("content"),
                    o.optString("w"), o.optString("i"),
                    o.optString("x") == "1",
                    o.optString("q"),
                    o.optString("p") == "1"
                )
            }
        }.getOrDefault(emptyList())
    }

    fun saveConv(pid: String, list: List<Msg>) {
        val arr = org.json.JSONArray()
        list.forEach {
            val o = JSONObject().put("role", it.role).put("content", it.content)
                .put("w", it.who)
            // 只有表情包消息才写 `i`，普通文字消息不多存一个空键（老版本读回来也不受影响）
            if (it.img.isNotEmpty()) o.put("i", it.img)
            // 「从上下文移除」的标记（不写 false，省空间）
            if (it.skip) o.put("x", "1")
            if (it.quote.isNotEmpty()) o.put("q", it.quote)
            // 主动唤醒来的一条（132），不写 false 省空间
            if (it.proactive) o.put("p", "1")
            arr.put(o)
        }
        prefs().edit().putString(convKey(pid), arr.toString())
            // 顺手记「最后一次说话的时间」：聊天列表要按它混排（群 + 人一起倒序）
            .putLong(convAtKey(pid), System.currentTimeMillis())
            .apply()
        // 云备份（2026-11-16）：30 秒节流、后台线程推一次。
        // 放后台是因为 saveConv 是在 UI 线程调的，不能让它等网络。
        runCatching { Thread { runCatching { backupPushThrottled() } }.start() }
        // 常驻通知的正文 = 最近一条消息摘要（2026-11-16）
        runCatching {
            val last = list.lastOrNull()
            if (last != null) {
                com.aevis.android.core.AeviService.lastPreview =
                    if (last.content == "[图片]") "[图片]"
                    else if (last.img.isNotEmpty()) "[表情]"
                    else last.content.take(40)
                com.aevis.android.core.AeviService.refresh(appCtx)
            }
        }
    }

    private fun convAtKey(pid: String) = "conv_at_" + pid

    /** 这个会话最后一次落盘的时间。没聊过返回 0。*/
    fun convAt(pid: String): Long = prefs().getLong(convAtKey(pid), 0L)

    fun clearConv(pid: String) {
        prefs().edit().remove(convKey(pid)).remove(convAtKey(pid)).apply()
    }

    /**
     * 表情包一套。后端 `emoji_pack` + `emoji_item`（`items` 是图 URL 数组）。
     *
     * `items`（2026-11-16 补）：`/v1/emoji/list` 每一行**自带**这一套里所有的图 URL
     * （相对路径，如 `/v1/media/9801….jpg`），以前解析时丢掉了 —— 结果就是
     * App 里只能看到一套封面，点进去没有内容可发。放最后 + 默认空列表，老调用点不受影响。
     */
    data class EmojiPack(
        val id: String,
        val name: String,
        val intro: String,
        val cover: String,
        val count: Int,
        val official: Boolean,
        val items: List<String> = emptyList()
    )

    fun emojiPacks(): List<EmojiPack> {
        val (code, json) = getWith("/v1/emoji/list", emptyMap(), token())
        if (code !in 200..299) return emptyList()
        val d = json.optJSONObject("data") ?: return emptyList()
        val arr = d.optJSONArray("rows") ?: return emptyList()
        val out = ArrayList<EmojiPack>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val items = o.optJSONArray("items")
            // items 是这一套里所有图的相对路径；顺序就是后端的顺序（别 shuffle，用户认得位置）
            val urls = ArrayList<String>(items?.length() ?: 0)
            if (items != null) {
                for (j in 0 until items.length()) {
                    val u = items.optString(j)
                    if (u.isNotEmpty()) urls.add(u)
                }
            }
            out.add(
                EmojiPack(
                    o.optString("id"), o.optString("name"), o.optString("intro"),
                    o.optString("cover_url").ifEmpty { urls.firstOrNull().orEmpty() },
                    o.optInt("count").let { if (it > 0) it else urls.size },
                    o.optInt("is_official") == 1,
                    urls
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
        // ⚠️ 2026-11-15：服务端 `data` 直接就是数字（`points_store.balance(uid)`），
        // 不是 `{balance: n}`。之前只按对象解析，所以主页永远显示「读取中…」。
        val d = json.opt("data") ?: return null
        if (d is Number) return d.toInt().takeIf { it >= 0 }
        val o = json.optJSONObject("data") ?: return null
        // 🔴 2026-11-15 根因：服务端 `balance()` 返回的是
        //    {"ok":true,"points":499,"yuan":4.99} —— 字段叫 **points**，不是 balance。
        //    客户端一直读 balance，所以主页永远「读取中…」（改了两次解析都没对）。
        o.optInt("points", -1).takeIf { it >= 0 }?.let { return it }
        o.optInt("balance", -1).takeIf { it >= 0 }?.let { return it }
        return null
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
                // 2026-11-25：北京为主 —— 只试一条的话那条挂云更新就断了
                var res = callOnce(FASTLINE, "GET", "/v1/app/config", null, token())
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
    fun baseUrl(): String {
        // 118：优先用"实际记住的那条"（竞速赢家），没有才回落到用户选择 / 老的两态
        val h = activeHost
        if (h != null && activeIsFresh()) return h
        return endpoints().firstOrNull { it.id == pinnedLine }?.host
            ?: (if (preferDirect) DIRECT else FASTLINE)
    }

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
        // 118：先走"实际在用的那条"（竞速赢家 / 用户选择），再按线路表兜底。
        // 顺序试而不是并发，是 105 那轮踩过的坑（Channel 版实测一张图都出不来）；
        // 图片是小文件，多试一次的代价只是一次超时。
        val primary = baseUrl()
        val order = (listOf(primary) + endpoints().map { it.host } +
            listOf(DIRECT, FASTLINE, API2LINE)).distinct().take(4)
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
        // R-02：头像按 512 采样解码（原来解全尺寸，列表里几十张就 OOM）
        return conn.getInputStream().use { decodeSampled(it, 512, 512) }
    }

    /**
     * 手动切线路（关于页里点一下在 直连 / 中转 之间换）。
     * 112：先取消「钉住某条线路」—— 不然点了这一下，标签还是钉住的那条，看着像没反应。
     */
    fun switchLine(): String {
        pinnedLine = 0
        preferDirect = !preferDirect
        return lineName()
    }

    // ---------------- 线路状态（2026-11-16）----------------
    //
    // 2026-11-25：用户可见的 API 线路只有北京（`FASTLINE`）。
    // 网络层内部仍保留直连 / 自签常量做兜底，但不作为可选线路展示。

    /**
     * 一条**可以被界面看到**的线路。
     *
     * ⚠️ 2026-11-16 收紧：这里**没有 host、没有端口、没有域名**。
     * 用户原话：「不要暴露真实 IP…用主域名，不用完整域名，不用暴露」——
     * 真机上把 `103.236.72.107:54319` 摆在用户眼前既不专业也不安全。
     * `FASTLINE` / `DIRECT` 这些常量**只允许存在于网络层**，
     * 界面 / 日志 / 错误提示一律用 `label`。
     */
    data class Line(
        val id: Int,          // 跟下面的 `endpoints()` 一一对应，只用来做「面板里哪一行」的稳定 key
        val label: String,
        val note: String,
        val chat: Boolean     // 能不能跑对话
    )

    /**
     * 一条可用的线路端点（2026-11-16，112）。
     *
     * **线路表就是这一张数组** —— 用户要求「有几条显示几条，不许藏」，
     * 所以 UI 只遍历 `lines()`，加一条这里多一行，界面自动多一行，不用改 UI 代码。
     * `host` 只在网络层用，界面拿到的 `Line` 里没有地址（不暴露域名/IP）。
     */
    private data class Endpoint(
        val id: Int,
        val host: String,
        val labelKey: String,
        val noteKey: String
    )

    /**
     * 当前对外提供服务的线路（2026-11-25：用户明确「服务器就只有北京」）。
     *
     * 界面可选线路只保留一条：北京隧道反代（`FASTLINE`，≈0.20s）。
     * 直连 / 备用 / 原主站入口都从**用户可选列表**里移除（网络层内部兜底常量仍保留，
     * 但不再作为可选线路显示）。界面只显示 label，不露 IP / 端口。
     */
    private fun endpoints(): List<Endpoint> = listOf(
        Endpoint(1, FASTLINE, "北京", "隧道反代")
    )

    fun lines(): List<Line> = endpoints().map {
        Line(it.id, com.aevis.android.core.I18n.tr(it.labelKey),
            com.aevis.android.core.I18n.tr(it.noteKey), true)
    }

    /** 2026-11-25：用户明确「服务器只有北京」，只有一个可选线路（id 1）；此常量保留仅为兼容旧引用。*/
    private const val DEFAULT_LINE_ID = 1

    /**
     * 用户手动选的线路 id；`0` = 自动（**竞速**：直连 vs 北京，谁先通走谁）。
     * 2026-11-25：服务器只有北京一条，`pinnedLine` 实际只可能是 0（自动）或 1（北京）。
     * 网络层仍保留直连/备用常量做内部兜底，但它们不再出现在 `lines()` 的可选列表里。
     */
    @Volatile
    private var pinnedLine: Int = 0

    fun currentLineId(): Int = pinnedLine

    fun setLineById(id: Int) {
        pinnedLine = id
        // 换了线路就把"记住的那条"也作废，下一次请求立刻按新选择走
        activeHost = null
        activeAt = 0L
    }

    /** 实际在用的线路 id（0 = 还没跑过请求 / 不知道）。界面用它点亮勾选，别显示 A 实际用 B。*/
    fun activeLineId(): Int =
        endpoints().firstOrNull { it.host == activeHost }?.id ?: 0

    /** 当前在用的对话线路名字。优先报**实际**那条，其次才是用户选的。*/
    fun lineLabel(): String {
        val byActive = endpoints().firstOrNull { it.host == activeHost }
        if (byActive != null) return com.aevis.android.core.I18n.tr(byActive.labelKey)
        val e = endpoints().firstOrNull { it.id == pinnedLine }
        if (e != null) return com.aevis.android.core.I18n.tr(e.labelKey)
        // 2026-11-25：只有北京一条线路，兜底报北京
        return com.aevis.android.core.I18n.tr("北京")
    }

    /** 当前正在用的是不是直连。*/
    fun currentDirect(): Boolean = preferDirect

    // ---------------- 线路竞速（2026-11-16，118）----------------
    //
    // 目标：冷启动第一条消息别再等"逐个试" —— 同时向「首选 + 一条备用」发轻探针
    // （`/v1/app/config`），谁先 200 就用谁，另一条立刻 disconnect()。
    //
    // 三条规矩：
    //   ① 竞速只在「没有记住的线路」或「记住的那条连续 2 次失败」时做；
    //      成功后 5 分钟内直接走记住的那条，不重复竞速（省一个请求）。
    //   ② 单次失败先**重试同一条**，连续 2 次才换线（偶发抖动不跳线）。
    //   ③ 所有结果打 `AevisLine` 日志（`竞速结果 = 直连 · 最佳 120ms`），便于现场判断。

    @Volatile
    private var activeHost: String? = null

    @Volatile
    private var activeAt: Long = 0L

    /** 记住的线路能用多久（毫秒）。*/
    private const val RACE_TTL = 5 * 60_000L

    /** 竞速探针超时：比正常请求短，慢的那条本来也该让位。*/
    private const val RACE_TIMEOUT = 4000

    private fun labelOf(host: String): String =
        endpoints().firstOrNull { it.host == host }?.let {
            com.aevis.android.core.I18n.tr(it.labelKey)
        } ?: "未知线路"

    /**
     * 同时打两条线的轻探针，返回先通的那条（都不通返回 null）。
     *
     * 用裸 `Thread` 而不是协程：`call()` 是**阻塞**函数，调用方本来就在 IO 线程，
     * 这里再套 `runBlocking` 只会多一层调度；线程 + CountDownLatch 最直白。
     */
    private fun race(candidates: List<String>): String? {
        val pool = candidates.distinct().take(2)
        if (pool.isEmpty()) return null
        if (pool.size == 1) {
            val only = pool[0]
            val ok = runCatching {
                val c = (URL(only + "/v1/app/config").openConnection() as HttpURLConnection)
                c.requestMethod = "GET"
                c.connectTimeout = RACE_TIMEOUT
                c.readTimeout = RACE_TIMEOUT
                val code = c.responseCode
                runCatching { c.disconnect() }
                code > 0
            }.getOrDefault(false)
            return if (ok) only else null
        }

        val done = java.util.concurrent.CountDownLatch(1)
        val win = java.util.concurrent.atomic.AtomicReference<String?>(null)
        val t0 = System.currentTimeMillis()
        pool.forEach { host ->
            Thread {
                var c: HttpURLConnection? = null
                try {
                    c = (URL(host + "/v1/app/config").openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = RACE_TIMEOUT
                        readTimeout = RACE_TIMEOUT
                        // 让晚到的那条尽快收摊
                        useCaches = false
                    }
                    val code = c.responseCode
                    if (code > 0) {
                        win.compareAndSet(null, host)
                        done.countDown()
                    }
                } catch (_: Exception) {
                    // 这条慢/挂了 —— 不打扰另一条
                } finally {
                    if (win.get() != host) runCatching { c?.disconnect() }
                }
            }.apply { isDaemon = true }.start()
        }
        val ok = runCatching {
            done.await((RACE_TIMEOUT + 500).toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
        }.getOrDefault(false)
        val winner = if (ok) win.get() else null
        if (winner != null) {
            activeHost = winner
            activeAt = System.currentTimeMillis()
            lineFailStreak = 0
            android.util.Log.i(
                "AevisLine",
                "竞速结果 = ${labelOf(winner)} ${System.currentTimeMillis() - t0}ms（对手 ${pool.size - 1} 条）"
            )
        } else {
            android.util.Log.w("AevisLine", "竞速失败：${pool.size} 条都没通")
        }
        return winner
    }

    /** 记住的那条现在还信不信得过。*/
    private fun activeIsFresh(): Boolean {
        val h = activeHost ?: return false
        if (System.currentTimeMillis() - activeAt >= RACE_TTL) return false
        // 用户手动换了线路 → 记住的那条必须属于新选择
        val pinned = pinnedLine
        if (pinned != 0 && endpoints().firstOrNull { it.id == pinned }?.host != h) return false
        return true
    }

    /** 指定切到哪条（老接口，`true`=直连；新代码请用 `setLineById`）。*/
    fun setLine(direct: Boolean) {
        preferDirect = direct
    }

    /** 探测失败的类别（2026-11-16，114）——界面据此显示「超时 / TLS 失败 / HTTP 5xx」。*/
    enum class PingFail {
        NONE,      // 通
        TIMEOUT,   // 6 秒没响应（连接或读）
        TLS,       // SSLHandshakeException / 证书链不认
        HTTP,      // 连上了但服务端 5xx
        NET        // 其它网络错（DNS、断网、连接被拒…）
    }

    /**
     * 一次线路探测的结果（2026-11-16，114）。
     *
     * 以前只返回 `Long`（-1 = 失败），界面只能说「超时」—— 用户拿截图来问，
     * 谁也分不清是弱网、证书没信任、还是服务端 500。现在把 `fail` 和 `detail`
     * 一起带回去，界面四态显示，一眼定位。
     */
    data class PingResult(
        val ms: Long,
        val fail: PingFail = PingFail.NONE,
        val detail: String = ""
    )

    /**
     * 测一条线路的往返耗时（ms）。
     *
     * 打的是最轻的 `/v1/app/config`（不需要登录、响应体很小）。
     * 114 放宽了门槛：**连接 4s / 读取 6s / 总超时 6s** ——
     * 中转那条 curl 1.4s，但 App 里要 TLS 握手 + 首字节，弱网下 3s 很容易被误判成超时。
     * 这样「真慢」和「真死」才分得开。
     * ⚠️ 只在打开线路面板时测，**不要常驻轮询** —— 那是纯浪费流量和电。
     * ⚠️ 界面里每条线路各自一个 `LaunchedEffect(id)` 调它 → **天然并发**，
     *    不会串行把 6 秒叠加成 18 秒。
     */
    fun pingLineById(id: Int): PingResult {
        val host = endpoints().firstOrNull { it.id == id }?.host
            ?: return PingResult(-1, PingFail.NET, "未配置")
        val t0 = System.currentTimeMillis()
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(host + "/v1/app/config").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 4000
                readTimeout = 6000
            }
            val code = conn.responseCode
            val dt = System.currentTimeMillis() - t0
            when {
                dt >= 6000 -> PingResult(-1, PingFail.TIMEOUT)
                // 4xx 也算通：链路和证书都活着，只是这个探针路径不被允许
                code >= 500 -> PingResult(dt, PingFail.HTTP, code.toString())
                else -> PingResult(dt)
            }
        } catch (e: javax.net.ssl.SSLException) {
            // SSLHandshakeException / 证书链不认 —— 自签证书没进 network_security_config 就是这一档
            PingResult(-1, PingFail.TLS, e.javaClass.simpleName)
        } catch (e: java.security.cert.CertificateException) {
            PingResult(-1, PingFail.TLS, e.javaClass.simpleName)
        } catch (e: java.net.SocketTimeoutException) {
            PingResult(-1, PingFail.TIMEOUT)
        } catch (e: Exception) {
            PingResult(-1, PingFail.NET, e.javaClass.simpleName)
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

    fun pingLine(direct: Boolean): Long {
        // 2026-11-25：非直连改测北京
        val host = if (direct) DIRECT else FASTLINE
        val t0 = System.currentTimeMillis()
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(host + "/v1/app/config").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 3000
                readTimeout = 3000
            }
            conn.responseCode          // 拿到状态码就算通（4xx 也说明链路活着）
            val dt = System.currentTimeMillis() - t0
            if (dt >= 3000) -1L else dt
        } catch (e: Exception) {
            -1L
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

    /**
     * 更新检查（2026-11-16 修正）。
     *
     * 之前打的是 `/v1/app/version?platform=&build=` —— 那个路径服务端没有，永远 404，
     * 所以**从来没弹过更新**（用户问「旧版本更新弹窗会有吗」）。
     * 真正可用的是：
     *   `GET /v1/app/update?platform=android&version=1.0.0`
     *   → { code, data: { current, update, force, latest, minVersion, notes, ipaUrl } }
     * ⚠️ 字段名是 `latest` / `ipaUrl`，不是 `latest_version` / `ipa_url`。
     */
    data class UpdateInfo(
        val update: Boolean,
        val force: Boolean,
        val latest: String,
        val notes: String,
        val url: String
    )

    fun checkUpdate(): UpdateInfo? {
        val (code, json) = getWith(
            "/v1/app/update?platform=android&version=" + com.aevis.android.BuildConfig.VERSION_NAME,
            emptyMap(), token()
        )
        if (code !in 200..299) return null
        val d = json.optJSONObject("data") ?: return null
        return UpdateInfo(
            update = d.optBoolean("update", false),
            force = d.optBoolean("force", false),
            latest = d.optString("latest"),
            notes = d.optString("notes"),
            url = d.optString("ipaUrl")
        )
    }

    /** 当前对话线路的名字（跟 [lineLabel] 同一口径，别在这里另写一套）。
     *  2026-11-16：文案从「线路一 · 直连」改成「直连」—— 用户要求不暴露内部细节。*/
    fun lineName(): String = lineLabel()

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

    /**
     * 退出登录（2026-11-16 改）。
     *
     * **先推云备份再清本地** —— 不做这一步，用户一退出登录本地 `conv_*` 就被清空，
     * 聊天记录永久没了（以前就是这样）。推失败也照样退，不能把用户卡在登录态。
     * 「账号隔离」= 服务端按账号一行存 + 本地退出即清空。
     */
    fun signOut() {
        if (token() != null) runCatching { backupPush() }
        prefs().edit().clear().apply()
    }

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

    // ---------------- 增长 / 链接热更新（2026-11-25，对标 iOS GrowthAPI）----------------
    //
    // 服务端四个链接可后台热更新，客户端**不写死 URL**：每次进页面 force 拉一次，
    // 断网用本地缓存兜底。取不到就显示"暂无"，不编造活动 / 群链接。

    data class GrowthConfig(
        val groupJoinUrl: String = "",
        val wechatWorkUrl: String = "",
        val activityUrl: String = "",
        val inviteBaseUrl: String = "",
        val ok: Boolean = false
    ) {
        val hasAny: Boolean get() =
            groupJoinUrl.isNotEmpty() || wechatWorkUrl.isNotEmpty() ||
                activityUrl.isNotEmpty() || inviteBaseUrl.isNotEmpty()
    }

    data class GrowthActivity(
        val id: String, val title: String, val summary: String,
        val url: String, val rewardPoints: Int,
        val startAt: String, val endAt: String
    )

    data class InviteResult(val ok: Boolean, val points: Int, val message: String)

    data class ChatLogEntry(
        val id: String, val role: String, val content: String, val createdAt: String
    )

    /** 拉增长链接配置（ok=false 表示网络失败，调用方用缓存）。*/
    fun growthConfig(): GrowthConfig {
        val (code, json) = get("/v1/growth/config", token())
        if (code !in 200..299) return GrowthConfig()
        val d = json.optJSONObject("data") ?: json
        return GrowthConfig(
            groupJoinUrl = d.optString("groupJoinUrl"),
            wechatWorkUrl = d.optString("wechatWorkUrl"),
            activityUrl = d.optString("activityUrl"),
            inviteBaseUrl = d.optString("inviteBaseUrl"),
            ok = true
        )
    }

    fun growthActivities(): List<GrowthActivity> {
        val (code, json) = get("/v1/growth/activities", token())
        if (code !in 200..299) return emptyList()
        val d = json.optJSONObject("data") ?: json
        val arr = d.optJSONArray("rows") ?: return emptyList()
        val out = ArrayList<GrowthActivity>(arr.length())
        for (i in 0 until arr.length()) {
            val r = arr.optJSONObject(i) ?: continue
            val id = r.optString("id").ifEmpty { r.optInt("id").toString() }
            if (id.isBlank() || id == "0") continue
            out.add(
                GrowthActivity(
                    id = id, title = r.optString("title"), summary = r.optString("summary"),
                    url = r.optString("url"), rewardPoints = r.optInt("rewardPoints"),
                    startAt = r.optString("startAt"), endAt = r.optString("endAt")
                )
            )
        }
        return out
    }

    fun bindInvite(code: String): InviteResult {
        val trimmed = code.trim()
        if (trimmed.isEmpty()) return InviteResult(false, 0, "请先填写邀请码")
        val (c, j) = post("/v1/growth/invite/bind", JSONObject().put("code", trimmed), token())
        if (c !in 200..299) return InviteResult(false, 0, "网络异常（HTTP $c）")
        val d = j.optJSONObject("data") ?: j
        return InviteResult(
            ok = d.optBoolean("ok", false),
            points = d.optInt("points", 0),
            message = d.optString("message").ifEmpty { j.optString("msg") }
        )
    }

    /** 对话日志第一页。cursor 翻页由调用方另发（这里只做第一页 + 可选 cursor）。*/
    fun chatLogs(cursor: String = "", limit: Int = 20): Pair<List<ChatLogEntry>, String> {
        var path = "/v1/chat/logs?limit=$limit"
        if (cursor.isNotEmpty()) {
            path += "&cursor=" + java.net.URLEncoder.encode(cursor, "UTF-8")
        }
        val (code, json) = get(path, token())
        if (code !in 200..299) return emptyList<ChatLogEntry>() to ""
        val d = json.optJSONObject("data") ?: json
        val arr = d.optJSONArray("rows") ?: return emptyList<ChatLogEntry>() to ""
        val out = ArrayList<ChatLogEntry>(arr.length())
        for (i in 0 until arr.length()) {
            val r = arr.optJSONObject(i) ?: continue
            out.add(
                ChatLogEntry(
                    id = r.optString("id").ifEmpty { r.optInt("id").toString() },
                    role = r.optString("role"), content = r.optString("content"),
                    createdAt = r.optString("createdAt")
                )
            )
        }
        return out to d.optString("nextCursor")
    }

    /** 需要额外头的 POST（站内信认 `X-Account`）。*/
    private fun postWith(
        path: String,
        body: JSONObject?,
        headers: Map<String, String>,
        token: String?
    ): Pair<Int, JSONObject> {
        var last: Pair<Int, JSONObject> = -1 to JSONObject().put("msg", "网络异常")
        // 2026-11-25：两条候选改直连 / 北京
        for (base in listOf(if (preferDirect) DIRECT else FASTLINE,
                            if (preferDirect) FASTLINE else DIRECT)) {
            val r = callOnce(base, "POST", path, body, token, headers)
            if (r.first > 0) return r
            last = r
        }
        return last
    }

    private fun post(path: String, body: JSONObject?, token: String?): Pair<Int, JSONObject> =
        call("POST", path, body, token)

    private fun get(path: String, token: String?): Pair<Int, JSONObject> =
        call("GET", path, null, token)

    /** 需要额外头的 GET（站内信认 `X-Account`，不认 Bearer）。 */
    private fun getWith(path: String, headers: Map<String, String>,
                        token: String?): Pair<Int, JSONObject> {
        var last: Pair<Int, JSONObject> = -1 to JSONObject().put("msg", "网络异常")
        // 2026-11-25：两条候选改直连 / 北京
        for (base in listOf(if (preferDirect) DIRECT else FASTLINE,
                            if (preferDirect) FASTLINE else DIRECT)) {
            val r = callOnce(base, "GET", path, null, token, headers)
            if (r.first > 0) return r
            last = r
        }
        return last
    }

    private fun call(method: String, path: String, body: JSONObject?,
                     token: String?): Pair<Int, JSONObject> {
        val eps = endpoints()
        val pinnedHost = eps.firstOrNull { it.id == pinnedLine }?.host
        val fresh = activeIsFresh()

        var last: Pair<Int, JSONObject> = -1 to JSONObject().put("msg", "网络异常")

        /** 打一条线；成功就记住它并返回。失败顺手记下最后一次错误。*/
        fun tryHost(host: String): Pair<Int, JSONObject>? {
            val r = callOnce(host, method, path, body, token)
            if (r.first <= 0) {
                last = r
                return null
            }
            if (activeHost != host) {
                android.util.Log.i("AevisLine", "线路切换到 ${labelOf(host)}")
            }
            activeHost = host
            activeAt = System.currentTimeMillis()
            lineFailStreak = 0
            preferDirect = (host == DIRECT)
            return r
        }

        // ---------- ① 记住的那条：失败先重试一次（偶发抖动不跳线）----------
        if (fresh) {
            // R-08：别用 `!!` —— 进程内还没记忆线路时这里会直接崩，改成走候选
            // R-08：没有记忆线路时抛出去，交给外层 runCatching 走候选列表
            val host = activeHost ?: error("no active host yet")
            tryHost(host)?.let { return it }
            // 单次失败：先重试同一条
            tryHost(host)?.let { return it }
            // 两次都失败 → 这条不可信了，丢掉记忆，往下走其它候选
            android.util.Log.w("AevisLine", "连续 2 次失败，弃用 ${labelOf(host)}")
            activeHost = null
            activeAt = 0L
            lineFailStreak++
        }

        // ---------- ② 没有可用记忆 ----------
        // 自动模式（pinned == 0）：**竞速**「直连（首选）+ 北京（备用）」，谁先通走谁；
        // 手动选了某条：不再竞速（用户明确表态，不能偷偷换成别的），严格走它，
        // 连挂两次才由下面的兜底链接管。
        val primary = pinnedHost ?: eps.firstOrNull()?.host
        var winner: String? = null
        if (pinnedHost != null) {
            android.util.Log.i("AevisLine", "用户指定线路 = ${labelOf(pinnedHost)}（不竞速）")
            tryHost(pinnedHost)?.let { return it }
            tryHost(pinnedHost)?.let { return it }
            android.util.Log.w("AevisLine", "手动线路 ${labelOf(pinnedHost)} 连续 2 次失败，改走备用")
        } else if (primary != null) {
            val backup = eps.firstOrNull { it.host != primary }?.host
            winner = race(listOfNotNull(primary, backup))
            if (winner != null) {
                tryHost(winner)?.let { return it }
            }
        }

        // ---------- ③ 竞速赢家也失败（或竞速没结果）：按顺序兜底，每条只试一次 ----------
        val order = ArrayList<String>(6)
        if (winner != null) order.add(winner)
        if (primary != null && !order.contains(primary)) order.add(primary)
        for (e in eps) if (!order.contains(e.host)) order.add(e.host)
        // 2026-11-25：兜底改直连 / 北京
        if (preferDirect) {
            if (!order.contains(DIRECT)) order.add(DIRECT)
            if (!order.contains(FASTLINE)) order.add(FASTLINE)
        } else {
            if (!order.contains(FASTLINE)) order.add(FASTLINE)
            if (!order.contains(DIRECT)) order.add(DIRECT)
        }
        for (b in cloudBases) {
            if (order.size >= 5) break
            if (!order.contains(b)) order.add(b)
        }

        for (base in order) {
            val r = callOnce(base, method, path, body, token)
            if (r.first > 0) {
                activeHost = base
                activeAt = System.currentTimeMillis()
                preferDirect = (base == DIRECT)
                lineFailStreak = 0
                return r
            }
            last = r
        }
        // 所有候选线路都没打通 → 记一次失败；连续两轮失败就清掉记忆（下次重新竞速）
        lineFailStreak++
        if (lineFailStreak >= 2) {
            activeHost = null
            activeAt = 0L
        }
        android.util.Log.w("AevisLine", "全部线路失败（连续 $lineFailStreak 次）")
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
