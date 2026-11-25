package com.aevis.android.core

import android.content.Context
import com.aevis.android.data.Api
import org.json.JSONArray
import org.json.JSONObject

/**
 * 冷启动硬缓存预加载（2026-11-25，对标 iOS HardCache）。
 *
 * 登录进主界面后后台预拉：广场人设 / 表情包 / 商品 / 额度 / 余额 / 会员态，落盘加密缓存。
 * 各页面冷启动先读缓存**立刻显示**，再联网刷新；断网用缓存、不白屏。
 *
 * 广场/表情用 [PlazaCache]；商品/额度/钱包用本文件的通用槽（同样走 [SecureCache]）。
 * 写失败静默，绝不影响功能。
 */
object ColdCache {
    private const val K_PRODUCTS = "cold_products_v1"
    private const val K_QUOTA = "cold_quota_v1"
    private const val K_WALLET = "cold_wallet_v1"

    /** 后台预拉所有数据（在 IO 线程调用）。单项失败不影响其它项。*/
    fun prefetch(ctx: Context) {
        // 广场 + 表情
        runCatching {
            val p = Api.personasChecked()
            val e = Api.emojiPacksChecked()
            if (p.ok || e.ok) {
                val cached = PlazaCache.load(ctx)
                PlazaCache.save(
                    ctx,
                    PlazaCache.Payload(
                        personas = if (p.ok) p.items else cached.personas,
                        packs = if (e.ok) e.items else cached.packs,
                        signature = PlazaCache.signature(
                            if (p.ok) p.items else cached.personas,
                            if (e.ok) e.items else cached.packs
                        ),
                        checkedAt = System.currentTimeMillis()
                    )
                )
            }
        }
        // 商品
        runCatching {
            val list = Api.shopProducts()
            if (list.isNotEmpty()) saveProducts(ctx, list)
        }
        // 额度
        runCatching { Api.quotaState()?.let { saveQuota(ctx, it) } }
        // 余额 + 会员态
        runCatching { Api.wallet()?.let { saveWallet(ctx, it) } }
    }

    // ---------------- 商品 ----------------
    fun saveProducts(ctx: Context, list: List<Api.ShopProduct>) {
        runCatching {
            val arr = JSONArray()
            list.forEach {
                arr.put(
                    JSONObject()
                        .put("id", it.id).put("title", it.title).put("days", it.days)
                        .put("price_cents", it.priceCents).put("week_total", it.weekTotal)
                        .put("percent", it.percent).put("label", it.label).put("kind", it.kind)
                        .put("uses", it.uses).put("list_price_cents", it.listPriceCents)
                        .put("discount_percent", it.discountPercent)
                        .put("grant_points", it.grantPoints).put("free_minutes", it.freeMinutes)
                        .put("signin_bonus", it.signinBonus).put("uses_per_yuan", it.usesPerYuan)
                        .put("min_sell_uses", it.minSellUses)
                )
            }
            SecureCache.putText(ctx, K_PRODUCTS, arr.toString())
        }
    }

    fun loadProducts(ctx: Context): List<Api.ShopProduct> {
        val raw = SecureCache.getText(ctx, K_PRODUCTS) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            val out = ArrayList<Api.ShopProduct>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                out.add(
                    Api.ShopProduct(
                        id = o.optString("id"), title = o.optString("title"),
                        days = o.optInt("days"), priceCents = o.optInt("price_cents"),
                        weekTotal = o.optInt("week_total"), percent = o.optInt("percent"),
                        label = o.optString("label"), kind = o.optString("kind", "member"),
                        uses = o.optInt("uses"), listPriceCents = o.optInt("list_price_cents"),
                        discountPercent = o.optInt("discount_percent", 100),
                        grantPoints = o.optInt("grant_points"), freeMinutes = o.optInt("free_minutes"),
                        signinBonus = o.optInt("signin_bonus"),
                        usesPerYuan = o.optInt("uses_per_yuan"), minSellUses = o.optInt("min_sell_uses")
                    )
                )
            }
            out
        }.getOrDefault(emptyList())
    }

    // ---------------- 额度 ----------------
    fun saveQuota(ctx: Context, q: Api.QuotaState) {
        runCatching {
            SecureCache.putText(
                ctx, K_QUOTA,
                JSONObject()
                    .put("active", q.active).put("percent", q.percent).put("left_pct", q.leftPct)
                    .put("has_quota", q.hasQuota).put("reset_at", q.resetAt)
                    .put("est_messages", q.estMessages).toString()
            )
        }
    }

    fun loadQuota(ctx: Context): Api.QuotaState? {
        val raw = SecureCache.getText(ctx, K_QUOTA) ?: return null
        return runCatching {
            val o = JSONObject(raw)
            Api.QuotaState(
                active = o.optBoolean("active"), percent = o.optInt("percent"),
                leftPct = o.optInt("left_pct"), hasQuota = o.optBoolean("has_quota"),
                resetAt = o.optString("reset_at"), estMessages = o.optInt("est_messages")
            )
        }.getOrNull()
    }

    // ---------------- 钱包（余额 + 会员态）----------------
    fun saveWallet(ctx: Context, w: Api.Wallet) {
        runCatching {
            val o = JSONObject().put("points", w.points)
            val m = w.member
            if (m != null) {
                o.put(
                    "member", JSONObject()
                        .put("active", m.active).put("week_total", m.weekTotal)
                        .put("week_used", m.weekUsed).put("week_left", m.weekLeft)
                        .put("plan_end", m.planEnd).put("week_start", m.weekStart)
                )
            }
            SecureCache.putText(ctx, K_WALLET, o.toString())
        }
    }

    fun loadWallet(ctx: Context): Api.Wallet? {
        val raw = SecureCache.getText(ctx, K_WALLET) ?: return null
        return runCatching {
            val o = JSONObject(raw)
            val m = o.optJSONObject("member")
            Api.Wallet(
                points = o.optInt("points"),
                member = if (m == null) null else Api.MemberQuota(
                    active = m.optBoolean("active"), weekTotal = m.optInt("week_total"),
                    weekUsed = m.optInt("week_used"), weekLeft = m.optInt("week_left"),
                    planEnd = m.optString("plan_end"), weekStart = m.optString("week_start")
                )
            )
        }.getOrNull()
    }
}
