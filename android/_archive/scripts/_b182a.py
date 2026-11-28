import io

B = 'app/src/main/java/com/aevis/android/'

# ---------------- 1) Api：会员扫码下单 ----------------
A = B + 'data/Api.kt'
a = io.open(A, encoding='utf-8').read()
if 'fun memberQr' not in a:
    anchor = '''    /** `GET /v1/points/recharge/<no>` —— 读 `status`（没有就退 `state`）。*/'''
    add = '''    /** 会员扫码下单（2026-11-18，182）：`POST /v1/pay/member/qr {plan}`。*/
    data class MemberQr(
        val orderNo: String,
        val plan: String,
        val days: Int,
        val amountYuan: String,
        val qrContent: String
    )

    fun memberQr(plan: String): MemberQr? {
        lastPayError = ""
        val (c, j) = post(
            "/v1/pay/member/qr", JSONObject().put("plan", plan), token()
        )
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

''' + anchor
    assert anchor in a, 'rechargeStatus anchor missing'
    a = a.replace(anchor, add, 1)
    io.open(A, 'w', encoding='utf-8', newline='\n').write(a)
    print('1) Api.memberQr 已加')

# ---------------- 2) RechargeScreen：两段式 + 弹层 ----------------
R = B + 'ui/RechargeScreen.kt'
r = io.open(R, encoding='utf-8').read()

# 2a) PointPacks 里加状态与弹层宿主
old = '''    val packs = listOf(
        Triple("pt_1", "1 元", 100),
        Triple("pt_6", "6 元", 600),
        Triple("pt_18", "18 元", 1800),
        Triple("pt_30", "30 元", 3000),
        Triple("pt_68", "68 元", 6800),
        Triple("pt_128", "128 元", 12800)
    )'''
new = '''    val packs = listOf(
        Triple("pt_1", "1 元", 100),
        Triple("pt_6", "6 元", 600),
        Triple("pt_18", "18 元", 1800),
        Triple("pt_30", "30 元", 3000),
        Triple("pt_68", "68 元", 6800),
        Triple("pt_128", "128 元", 12800)
    )

    // 182：扫码支付 —— 方式芯片（微信/支付宝都可用）+ 会员三档 + 统一弹层
    var channel by remember {
        mutableStateOf(
            com.aevis.android.core.ChatPrefs.prefsPublic()
                .getString("payChannel", "wxpay") ?: "wxpay"
        )
    }
    var paying by remember { mutableStateOf(false) }
    var payInfo by remember { mutableStateOf<PayInfo?>(null) }'''
assert old in r, 'packs anchor missing'
r = r.replace(old, new, 1)

# 2b) 行点击：改走 qr 接口（积分）
old_click = '''                    .tapable { payOrder(ctx, scope, code) }'''
new_click = '''                    .tapable {
                        if (paying) return@tapable
                        paying = true
                        scope.launch(Dispatchers.IO) {
                            val o = runCatching { Api.rechargeQr(code, channel) }.getOrNull()
                            withContext(Dispatchers.Main) {
                                paying = false
                                if (o != null) {
                                    payInfo = PayInfo(
                                        orderNo = o.orderNo, title = "Aevis 积分 ${o.points}",
                                        amountYuan = o.amountYuan, qty = "${o.points} 积分",
                                        qrContent = o.qrContent, kind = "points"
                                    )
                                } else {
                                    Toast.makeText(
                                        ctx, Api.lastPayError.ifBlank { "下单失败" },
                                        Toast.LENGTH_LONG
                                    ).show()
                                }
                            }
                        }
                    }'''
assert old_click in r, 'row click anchor missing'
r = r.replace(old_click, new_click, 1)

io.open(R, 'w', encoding='utf-8', newline='\n').write(r)
print('2a/2b 完成（方式状态 + 积分走 qr）')
