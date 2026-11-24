package com.aevis.android.core

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue

/**
 * 聊天外观设置（2026-11-15）。
 *
 * 用户：「用户能控制头像大小，能控制气泡的形状，有三个形状，还能控制气泡与头像之间的
 * 间距，还能自定义整体背景或者聊天背景，或者模糊或者动效」。
 *
 * 每一项都存 SharedPreferences，聊天页读它直接渲染 —— 改完立刻生效，不用重启。
 * 参照「忆伴」的 `ChatSettingsActivity` 分法：外观和背景分开两套（这里是外观）。
 */
object ChatPrefs {

    private const val P = "aevis_chat_look"

    /** 头像大小 dp。忆伴那套给了 36–64，我们留宽一点：32–72。*/
    var avatarSize: Int
        get() = getInt("avatar", 40).coerceIn(32, 72)
        set(v) = put("avatar", v.coerceIn(32, 72))

    /** 气泡圆角档位：0 = 大圆角（iOS 风），1 = 小圆角（微信风），2 = 尖角（带尾巴）。*/
    var bubbleStyle: Int
        get() = getInt("bubble", 0).coerceIn(0, 2)
        set(v) = put("bubble", v.coerceIn(0, 2))

    /** 气泡与头像之间的间距 dp。*/
    var gap: Int
        get() = getInt("gap", 8).coerceIn(2, 20)
        set(v) = put("gap", v.coerceIn(2, 20))

    /** 字号 sp（附带的，一起给）。*/
    /** 消息最大宽度占屏宽百分比。*/
    var bubbleWidthPct: Int
        get() = getInt("width", 72).coerceIn(55, 88)
        set(v) = put("width", v.coerceIn(55, 88))

    // ---- 气泡配色（2026-11-16）----
    //
    // 用户：「气泡颜色我要自己能调」。存的是 ARGB 整数，**不做任何 coerce** ——
    // 颜色是自由值，用 HSV 取色能取到任意值，夹一下就成别的色了。

    /** 我的气泡底色（ARGB）。默认主色 #9B8AF0。*/
    var mineBubble: Int
        get() = getInt("bubbleMine", 0xFF9B8AF0.toInt())
        set(v) = put("bubbleMine", v)

    /** 对方气泡底色（ARGB）。0 = 跟随主题（暗色玻璃 / 浅色白玻璃）。*/
    var aiBubble: Int
        get() = getInt("bubbleAi", 0)
        set(v) = put("bubbleAi", v)

    // ---- 线路（2026-11-16）----

    /**
     * 自动选最快：当前线路连续 3 次网络层失败时，发消息前自动切到另一条。
     * 默认 **开** —— 用户要的是"不用管它也能通"。
     */
    var autoLine: Boolean
        get() = prefs().getBoolean("autoLine", true)
        set(v) = prefs().edit().putBoolean("autoLine", v).apply()

    // ---- 更新提示（2026-11-16）----

    /**
     * 同一个版本每天最多提示一次（点了「稍后」就记下当天日期）。
     * 不记的话每次冷启动都弹，用户会烦到直接无视更新。
     */
    fun updateSkippedToday(ver: String): Boolean =
        prefs().getString("update_skip_" + ver, "").orEmpty() == today()

    fun markUpdateSkipped(ver: String) {
        prefs().edit().putString("update_skip_" + ver, today()).apply()
    }

    private fun today(): String =
        java.text.SimpleDateFormat("yyyyMMdd", java.util.Locale.US).format(java.util.Date())

    // ---- 背景 ----

    // ---- 显示方式（2026-11-16）----
    //
    // 用户：「输入方式有两个，一个是内心 OS，一大串那种；一个是一个字一个字蹦出来气泡」。
    //   0 = 内心 OS（默认，现状）：整段一起出，括号描写照常显示（浅色）
    //   1 = 逐字气泡：AI 回复一个字一个字蹦出来，只有新消息才播
    /**
     * 显示方式：`0` 内心 OS / `1` 逐字气泡 / `2` 微信式（拆成多条）。
     *
     * 🔴 2026-11-16 修真 bug：原来两端都是 `coerceIn(0, 1)`，**2 永远存不进去**，
     * 所以 `ChatScreen` 里 `if (displayMode == 2) splitReply(...)` 从来没成立过。
     */
    var displayMode: Int
        get() = getInt("displayMode", 0).coerceIn(0, 2)
        set(v) = put("displayMode", v.coerceIn(0, 2))

    // ---- 回复细节（2026-11-16，88）----
    // 默认值刻意选成"跟改之前一模一样"，老用户升级后手感不变。

    // ---- 聊天模式（2026-11-16，88 重定义）----
    //
    // 用户：「聊天模式只有两项 —— 普通（一条条回）/ 内心 OS（整段流式）」，
    // 「逐字」是**显示效果**，不是模式，单独一个开关。
    // 老的 `displayMode` 不再参与渲染（字段留着，避免老包读取崩），只做一次性迁移。

    /** 0 = 普通（多条气泡）/ 1 = 内心 OS（整段一条）。默认 1（保持老用户现在的"整段"手感）。*/
    var chatMode: Int
        get() {
            migrateModeOnce()
            return getInt("chatMode", 1).coerceIn(0, 1)
        }
        set(v) {
            migrateModeOnce()
            put("chatMode", v.coerceIn(0, 1))
        }

    /** 逐字显示（两种模式都能开）。默认关。*/
    var typewriter: Boolean
        get() {
            migrateModeOnce()
            // 106：更早那版迁移**已经**把 `migratedMode` 置位了，但当时写的是
            // `typewriter=false` —— 这批用户再也不会被改，所以"根本看不到逐字"。
            // 这里做一次性修复：已迁过但仍为 false 的改回 true。
            val p0 = prefs()
            if (!p0.getBoolean("twFixed106", false)) {
                if (!p0.getBoolean("typewriter", true)) {
                    p0.edit().putBoolean("typewriter", true).apply()
                }
                p0.edit().putBoolean("twFixed106", true).apply()
            }
            return p0.getBoolean("typewriter", true)
        }
        set(v) {
            migrateModeOnce()
            prefs().edit().putBoolean("typewriter", v).apply()
        }

    /** 把老的 `displayMode` 迁到 `chatMode + typewriter`，只迁一次。*/
    private fun migrateModeOnce() {
        val p = prefs()
        if (p.getBoolean("migratedMode", false)) return
        // 2026-11-16 用户口径：「默认内心 OS 开逐字」——
        // 老用户不管以前是 0/1/2，一律迁成 内心 OS + 逐字，且只迁一次；
        // 之后用户自己关掉就保持关（不会被再次覆盖）。
        val ed = p.edit()
        ed.putInt("chatMode", 1)
        ed.putBoolean("typewriter", true)
        ed.putBoolean("migratedMode", true).apply()
    }

    /** 回复长度：0 简洁 / 1 常规（默认）/ 2 话痨。会拼进 sys。*/
    var replyLen: Int
        get() = getInt("replyLen", 1).coerceIn(0, 2)
        set(v) = put("replyLen", v.coerceIn(0, 2))

    /** 括号内容单独成一条（只在"分成几条发"时生效）。默认开。*/
    var parenOwnLine: Boolean
        get() = prefs().getBoolean("parenOwnLine", true)
        set(v) = prefs().edit().putBoolean("parenOwnLine", v).apply()

    /** 拆完后把每条末尾的 分段标点 去掉。默认开。*/
    var stripSplitPunct: Boolean
        get() = prefs().getBoolean("stripSplitPunct", true)
        set(v) = prefs().edit().putBoolean("stripSplitPunct", v).apply()

    /** 合并发送：忽略分段，整段一条发。默认关（开了优先级高于"分成几条发"）。*/
    var mergeSend: Boolean
        get() = prefs().getBoolean("mergeSend", false)
        set(v) = prefs().edit().putBoolean("mergeSend", v).apply()

    /** 上下文条数：只发最近 N 条给模型（3–24，默认 12）。*/
    var ctxWindow: Int
        get() = getInt("ctxWindow", 12).coerceIn(3, 24)
        set(v) = put("ctxWindow", v.coerceIn(3, 24))

    /**
     * 逐字速度（2026-11-16，106）：0 慢 / 1 适中 / 2 快 / 3 很快 → 45 / 32 / 22 / 12 ms 每字。
     * 以前速度写死在 18–25ms，设置里那个选项根本没接线。
     */
    var typeSpeed: Int
        get() = getInt("typeSpeed", 1).coerceIn(0, 3)
        set(v) = put("typeSpeed", v.coerceIn(0, 3))

    fun typeSpeedMs(): Long = when (typeSpeed) {
        0 -> 45L
        2 -> 22L
        3 -> 12L
        else -> 32L
    }

    // ---------------- 聊天设置 5 项（2026-11-16，126）----------------
    //
    // 用户给了参考图，要求这 5 项**真的生效**（不是只有开关）：
    // 括号变浅 / 头像显示 / 回车发送 / 显示回复状态 / 消息大小。
    // 这些都是普通 prefs getter —— 改了不会自己触发重组，所以统一读 `uiVersion`
    // 订阅一次（跟 `bgVersion` 一个套路）。

    /** UI 设置的版本号：任何一个新 setter 都 `++`，聊天页读它来订阅。*/
    var uiVersion by mutableIntStateOf(0)
        private set

    /** 老的 setter（typeSpeed 这种）改完手动敲一下，让聊天页重组。*/
    fun bumpUi() {
        uiVersion++
    }

    /** 括号内容变浅（`（动作描写）` 用 60% 前景色渲染），默认开。*/
    var annotDim: Boolean
        get() = prefs().getBoolean("annotDim", true)
        set(v) {
            prefs().edit().putBoolean("annotDim", v).apply()
            uiVersion++
        }

    /**
     * 头像显示：0 = 双方都显示 / 1 = 只显示角色 / 2 = 都不显示。
     *
     * 128：默认从 1 改成 **0**（用户：「默认要显示我的头像」）。
     * 老用户只有在**从没手动改过**时才跟着变 —— 见 [avatarModeTouched] 与 `init()` 里的迁移。
     */
    var avatarMode: Int
        get() = getInt("avatarMode", 0).coerceIn(0, 2)
        set(v) {
            put("avatarMode", v.coerceIn(0, 2))
            // 用户点过这一项，以后默认值再变也不动他
            prefs().edit().putBoolean("avatarModeTouched", true).apply()
            uiVersion++
        }

    /** 用户是否手动改过「头像显示」（128 迁移用）。*/
    fun avatarModeTouched(): Boolean = prefs().getBoolean("avatarModeTouched", false)

    /** 回车发送：true = 回车直接发（单行）；false = 回车换行（多行）。默认 true。*/
    var enterSend: Boolean
        get() = prefs().getBoolean("enterSend", true)
        set(v) {
            prefs().edit().putBoolean("enterSend", v).apply()
            uiVersion++
        }

    /** 显示回复状态：顶栏「正在输入中」+ 气泡下状态小字，默认开。*/
    var showReplyStatus: Boolean
        get() = prefs().getBoolean("showReplyStatus", true)
        set(v) {
            prefs().edit().putBoolean("showReplyStatus", v).apply()
            uiVersion++
        }

    /** 消息大小：0 = 小(13.5sp) / 1 = 标准(15sp) / 2 = 大(17sp)，行高 = 1.45 倍。默认 1。*/
    var msgSize: Int
        get() = getInt("msgSize", 1).coerceIn(0, 2)
        set(v) {
            put("msgSize", v.coerceIn(0, 2))
            uiVersion++
        }

    /** 消息字号（sp）：跟 `msgSize` 一一对应。*/
    fun msgFontSp(): Float = when (msgSize) {
        0 -> 13.5f
        2 -> 17f
        else -> 15f
    }

    /** 消息行高 = 字号 × 1.45（参考图里那个行距）。*/
    fun msgLineSp(): Float = msgFontSp() * 1.45f


    /** 提示音（2026-11-16）：默认开。只在"收到 AI 回复且不在这个会话页"时响一声。*/
    var soundOn: Boolean
        get() = prefs().getBoolean("soundOn", true)
        set(v) = prefs().edit().putBoolean("soundOn", v).apply()

    /**
     * 自动恢复聊天记录（2026-11-16，116）。默认**开**。
     *
     * 开：登录后本地一条消息都没有、云端有备份 → 直接恢复 + Toast，不弹窗打断。
     * 关：同一个场景改成弹半窗问一句（用户自己决定）。
     * 「本地有数据 + 云端更新」始终只问不覆盖，跟这个开关无关。
     */
    var autoRestore: Boolean
        get() = prefs().getBoolean("autoRestore", true)
        set(v) = prefs().edit().putBoolean("autoRestore", v).apply()

    // ---- 主背景 / 聊天背景（2026-11-16，111；112 接进渲染）----
    // 默认全部 "default"，**不改变现有观感**。

    /**
     * 背景设置的版本号（2026-11-16，112）。
     *
     * 这几个字段是普通 SharedPreferences getter，**改了不会触发重组** ——
     * 主背景铺在 `Shell` 最外层、毛玻璃在 `V2Card` 里，都是长生命周期的 Composable，
     * 不订阅一个版本号就会出现「设置里改完，返回还得重进 App 才生效」。
     * 所以每个 setter 都 `++`，Theme / 背景层 / 容器各自读一次它。
     */
    var bgVersion by mutableIntStateOf(0)
        private set

    /** 整个 App 的背景：`default` / `solid` / `image`。*/
    var appBgType: String
        get() = prefs().getString("appBgType", "default").orEmpty()
        set(v) {
            prefs().edit().putString("appBgType", v).apply()
            bgVersion++
        }

    /** 纯色时是 `#RRGGBB`；图片时是本地路径或服务端 URL。*/
    var appBgValue: String
        get() = prefs().getString("appBgValue", "").orEmpty()
        set(v) {
            prefs().edit().putString("appBgValue", v).apply()
            bgVersion++
        }

    // 聊天背景**统一走 `chatbg` 页那一套**（`bgKind` / `bgPreset` / `bgBlur` / `bgDim` + `BackgroundStore`）。
    // 2026-11-16（113）：111 那版还留了一对 `chatBgType` / `chatBgValue`，全工程没有任何读取方 ——
    // 留着只会让下一个人以为「设了这个就有用」，实际改了没反应。已删。

    /** 给背景图加暗化蒙层（默认开）——不开的话白字容易看不清。*/
    var appTint: Boolean
        get() = prefs().getBoolean("appTint", true)
        set(v) {
            prefs().edit().putBoolean("appTint", v).apply()
            bgVersion++
        }

    /**
     * 背景图整体不透明度：0–100%，默认 **85**（2026-11-16，120）。
     *
     * 100 = 背景完全实（不跟主题底色混），30 = 很淡（像一层水印）。
     * 用户原话：「所有的东西都是透的，叠起来就不好用」—— 这个滑块是给他"调实"的。
     */
    var bgOpacity: Int
        get() = getInt("bgOpacity", 85).coerceIn(0, 100)
        set(v) {
            prefs().edit().putInt("bgOpacity", v.coerceIn(0, 100)).apply()
            bgVersion++
        }

    /**
     * 玻璃卡片的不透明度：40–100%，默认 **85**（2026-11-16，120）。
     *
     * ⚠️ 默认 85 而不是之前写死的 62/52：正文（列表行、气泡、输入栏）必须落在
     * **≥85% 不透明**的底上，62% 叠在花哨照片上会"两层字打架"。
     * 想更透可以自己往下拖，但最低 40 就到底 —— 再低正文就没保障了。
     */
    var glassAlpha: Int
        get() = getInt("glassAlpha", 85).coerceIn(40, 100)
        set(v) {
            prefs().edit().putInt("glassAlpha", v.coerceIn(40, 100)).apply()
            bgVersion++
        }

    /** 上次用的支付方式（2026-11-18，182）：`wxpay` / `alipay`。*/
    var payChannel: String
        get() = prefs().getString("payChannel", "wxpay").orEmpty().ifBlank { "wxpay" }
        set(v) = prefs().edit().putString("payChannel", v).apply()

    /** 弹窗/半窗背景：`0` 跟随主题 / `1` 深色玻璃。*/
    var dialogStyle: Int
        get() = getInt("dialogStyle", 0).coerceIn(0, 1)
        set(v) = put("dialogStyle", v.coerceIn(0, 1))

    /**
     * 扣费来源（2026-11-16）：`0` 会员额度优先（默认）/ `1` 墨点优先。
     * 只影响**请求体里的 `charge_source`**，实际怎么扣由服务端按这个字段决定。
     */
    var chargeSource: Int
        get() = getInt("chargeSource", 0).coerceIn(0, 1)
        set(v) = put("chargeSource", v.coerceIn(0, 1))

    // ---- 现实感知（2026-11-16）----

    /** 现实感知开关：默认**开**（时间/电量/网络/城市）。关掉 `Api.chat()` 就不传 `env`。*/
    var realityAware: Boolean
        get() = prefs().getBoolean("realityAware", true)
        set(v) = prefs().edit().putBoolean("realityAware", v).apply()

    /** 用户给的城市（天气用）。空 = 只做时间/电量/网络，不查天气。*/
    var city: String
        get() = prefs().getString("city", "").orEmpty()
        set(v) = prefs().edit().putString("city", v.trim()).apply()

    /** 常驻通知开关（2026-11-16）：默认开。关掉就撤通知、停前台服务。*/
    var keepAlive: Boolean
        get() = prefs().getBoolean("keepAlive", true)
        set(v) = prefs().edit().putBoolean("keepAlive", v).apply()

    /** 是否已经问过城市（第一次打开开关时问一次，之后不再打扰）。*/
    fun cityAsked(): Boolean = prefs().getBoolean("cityAsked", false)

    fun markCityAsked() = prefs().edit().putBoolean("cityAsked", true).apply()

    /** 背景类型：0 纯色 / 1 图片 / 2 渐变。*/
    var bgKind: Int
        get() = getInt("bgKind", 0).coerceIn(0, 2)
        set(v) = put("bgKind", v.coerceIn(0, 2))

    /** 自定义背景图（本地文件路径，从相册选完复制到私有目录）。*/
    var bgImagePath: String
        get() = prefs().getString("bgPath", "").orEmpty()
        set(v) = prefs().edit().putString("bgPath", v).apply()

    /** 背景模糊半径（0 = 不模糊）。*/
    var bgBlur: Int
        get() = getInt("bgBlur", 0).coerceIn(0, 24)
        set(v) = put("bgBlur", v.coerceIn(0, 24))

    /** 渐变预设下标。*/
    var bgPreset: Int
        get() = getInt("bgPreset", 0).coerceIn(0, 7)
        set(v) = put("bgPreset", v.coerceIn(0, 7))

    /** 背景遮罩浓度 0–60（百分比），图太亮时压暗一点文字才看得清。*/
    var bgDim: Int
        get() = getInt("bgDim", 0).coerceIn(0, 60)
        set(v) = put("bgDim", v.coerceIn(0, 60))

    // ---- 底层 ----

    private fun prefs() = appCtx.getSharedPreferences(P, Context.MODE_PRIVATE)

    private fun getInt(k: String, def: Int) = prefs().getInt(k, def)

    private fun put(k: String, v: Int) = prefs().edit().putInt(k, v).apply()

    /** Api.init 里调一次，别的地方直接用。*/
    lateinit var appCtx: Context
        private set

    fun init(ctx: Context) {
        appCtx = ctx.applicationContext
        // 127：老的「文字大小」（`font`，13–19sp）合并进 `msgSize`（0/1/2）。
        // 映射：>15sp → 2（大）、<14sp → 0（小）、其余 → 1（标准）。迁完就删旧键，只迁一次。
        runCatching {
            val sp = prefs()
            // 128：老版本默认是 1（只显示角色）；从没手动改过的用户跟着新默认走（0 双方都显示）
            if (sp.contains("avatarMode") && !sp.getBoolean("avatarModeTouched", false)) {
                sp.edit().putInt("avatarMode", 0).apply()
            }
            if (sp.contains("font")) {
                val old = sp.getInt("font", 15)
                if (!sp.contains("msgSize")) {
                    val mapped = when {
                        old > 15 -> 2
                        old < 14 -> 0
                        else -> 1
                    }
                    sp.edit().putInt("msgSize", mapped).apply()
                }
                sp.edit().remove("font").apply()
            }
        }
    }

    // ---------------- 主动唤醒的本地状态（2026-11-16，132）----------------

    /** 列表角标要重组：开关/未读变了就 ++。*/
    var proactiveVersion by mutableIntStateOf(0)
        private set

    /** 某个角色的「主动唤醒」是否开着（默认关）。飞行模式下也读得到。*/
    fun proactiveOn(pid: String): Boolean = prefs().getBoolean("proactive_$pid", false)

    /** 开关状态落本地 + 敲一下版本号（界面立刻反应）。*/
    fun setProactiveOn(pid: String, on: Boolean) {
        prefs().edit().putBoolean("proactive_$pid", on).apply()
        if (!on) clearProactiveUnread(pid)
        proactiveVersion++
    }

    /** 这个角色有几条「TA 找你」还没看。*/
    fun proactiveUnread(pid: String): Int = getInt("proactive_unread_$pid", 0)

    fun bumpProactiveUnread(pid: String, n: Int = 1) {
        val cur = proactiveUnread(pid) + n
        put("proactive_unread_$pid", cur)
        proactiveVersion++
    }

    fun clearProactiveUnread(pid: String) {
        if (proactiveUnread(pid) == 0) return
        put("proactive_unread_$pid", 0)
        proactiveVersion++
    }

    /** 「新消息弹窗」（2026-11-16，133）：主动消息到达时顶部弹应用内横幅。默认开。*/
    var msgBanner: Boolean
        get() = prefs().getBoolean("msgBanner", true)
        set(v) {
            prefs().edit().putBoolean("msgBanner", v).apply()
            uiVersion++
        }

    // ---------------- 135：聊天设置按角色独立 ----------------
    //
    // 用户：「这个角色不会同步聊天设置」——语义定死：
    //   · 五项（字号 / 括号 / 头像 / 回车 / 状态）**按 pid 存**（`msgSize_<pid>` 等）；
    //   · 没有该角色的键时，**读全局默认**（就是上面那几个预制项）；
    //   · 全局默认只在「通用配置」里改，只影响之后新建/首次进入的角色，不动已有角色。

    private fun keyOf(base: String, pid: String) = base + "_" + pid

    fun msgSizeOf(pid: String): Int = getInt(keyOf("msgSize", pid), msgSize).coerceIn(0, 2)
    fun setMsgSize(pid: String, v: Int) {
        put(keyOf("msgSize", pid), v.coerceIn(0, 2)); uiVersion++
    }

    fun annotDimOf(pid: String): Boolean =
        prefs().getBoolean(keyOf("annotDim", pid), annotDim)
    fun setAnnotDim(pid: String, v: Boolean) {
        prefs().edit().putBoolean(keyOf("annotDim", pid), v).apply(); uiVersion++
    }

    fun avatarModeOf(pid: String): Int = getInt(keyOf("avatarMode", pid), avatarMode).coerceIn(0, 2)
    fun setAvatarMode(pid: String, v: Int) {
        put(keyOf("avatarMode", pid), v.coerceIn(0, 2)); uiVersion++
    }

    fun enterSendOf(pid: String): Boolean = prefs().getBoolean(keyOf("enterSend", pid), enterSend)
    fun setEnterSend(pid: String, v: Boolean) {
        prefs().edit().putBoolean(keyOf("enterSend", pid), v).apply(); uiVersion++
    }

    fun showReplyStatusOf(pid: String): Boolean =
        prefs().getBoolean(keyOf("showReplyStatus", pid), showReplyStatus)
    fun setShowReplyStatus(pid: String, v: Boolean) {
        prefs().edit().putBoolean(keyOf("showReplyStatus", pid), v).apply(); uiVersion++
    }

    /** 按角色的字号 / 行高（没设过就继承全局）。*/
    fun msgFontSpOf(pid: String): Float = when (msgSizeOf(pid)) {
        0 -> 13.5f
        2 -> 17f
        else -> 15f
    }

    fun msgLineSpOf(pid: String): Float = msgFontSpOf(pid) * 1.45f
}
