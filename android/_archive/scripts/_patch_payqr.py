import io, re

P = '/opt/aevis/service/aevis_points_shop.py'
s = io.open(P, encoding='utf-8').read()

# ---------------- 1) 追加模块级 epay_mapi ----------------
if 'def epay_mapi(' not in s:
    s += '''

def epay_mapi(order_no, amount_cents, points, pay_type, clientip,
              platform="app"):
    """API 模式下单（mapi.php）—— 返回二维码内容，不跳网页收银台。

    与 `_pay_url`（submit.php）的唯一区别是接口和返回字段：
      · `/mapi.php` 返回 JSON：`{"code":1,"trade_no":..,"qrcode":..,"payurl":..}`
      · `qrcode` 是**动态码 URL**（形如 https://qrs-wxgzh-web.vbill.cn/wxSweep?id=…）
      · **`clientip` 必填**：mapi 会校验（空串 → {"code":-1,"msg":"用户IP地址(clientip)不能为空"}）；
        submit.php 不校验，所以老逻辑里 clientip 是空串也没事。
      · **不要传 `device`**：实测传 mobile/pc 会返回 `pay/wxjspay/<no>/` 那种 JSAPI 页，
        扫码打不开；不传才是 wxSweep 公众号码。这条是踩过的坑，别"优化"回去。
    """
    import json as _json
    import urllib.request as _ur

    cfg = epay_config()
    if not (cfg.get("pid") and cfg.get("key")):
        return {"code": -1, "msg": "易支付未配置"}

    pf = (platform or "app").strip().lower()
    if pf in ("ios", "android", "app"):
        return_url = "aevis://pay?order=" + order_no
    else:
        web = (os.getenv("AEVIS_WEB_BASE") or "https://aevis.cn").rstrip("/")
        return_url = web + "/recharge?pt=" + order_no

    params = {
        "pid": cfg["pid"],
        "type": pay_type if pay_type in ("wxpay", "alipay") else "wxpay",
        "out_trade_no": order_no,
        "notify_url": cfg["public_base"] + "/v1/points/epay/notify",
        "return_url": return_url,
        "name": "Aevis 积分 %d 分" % int(points),
        "money": "%.2f" % (amount_cents / 100.0),
        "sitename": cfg["sitename"],
        "clientip": (clientip or "").strip(),
    }
    params["sign"] = epay_sign(params, cfg["key"])
    params["sign_type"] = "MD5"

    body = urllib.parse.urlencode(params).encode("utf-8")
    req = _ur.Request(cfg["gateway"] + "/mapi.php", data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "aevis-service/1.0",
    })
    try:
        with _ur.urlopen(req, timeout=15) as r:
            txt = r.read().decode("utf-8", "replace")
    except Exception as e:
        return {"code": -1, "msg": "网关请求失败: %s" % e}
    try:
        return _json.loads(txt)
    except Exception:
        return {"code": -1, "msg": "网关返回非 JSON: %s" % txt[:200]}
'''
    io.open(P, 'w', encoding='utf-8').write(s)
    print('1) epay_mapi appended')
else:
    print('1) epay_mapi already exists')

# ---------------- 2) 新增 /v1/points/recharge/qr 路由 ----------------
anchor = '''        r = store.create_recharge(u, b.get("package") or b.get("pkg_code") or "",
                                  b.get("payType") or b.get("pay_type") or "wxpay",
                                  platform)
        return ok(r) if r.get("ok") else err(r["msg"], r["code"])
'''
new_block = anchor + '''
    @bp.post("/v1/points/recharge/qr")
    def recharge_qr():
        """API 模式：返回二维码内容（App 内扫码，不跳浏览器）。"""
        u = token_uid()
        if not u:
            return err("请先登录", 401, 401)
        b = request.get_json(silent=True) or {}
        pkg = b.get("pkg") or b.get("pkgCode") or b.get("package") or ""
        ptype = (b.get("type") or b.get("payType") or "wxpay").strip().lower()
        if ptype not in ("wxpay", "alipay"):
            return err("不支持的支付方式", 400, 400)
        # 真实客户端 IP：nginx 透传的 X-Forwarded-For 第一段，取不到再用 remote_addr
        xff = (request.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
        clientip = xff or (request.remote_addr or "")
        platform = (b.get("platform")
                    or request.headers.get("X-Client-Platform") or "app")
        r = store.create_recharge(u, pkg, ptype, platform)
        if not r.get("ok"):
            return err(r["msg"], r.get("code") or 4000)
        m = epay_mapi(r["orderNo"], r["amountCents"], r["points"], ptype,
                      clientip, platform)
        if m.get("code") != 1:
            # 网关原话直接回给前端（「下单频率过快」「域名没过白」都靠它显示）
            return err(m.get("msg") or "下单失败", 4101, 200)
        return ok({
            "orderNo": r["orderNo"],
            "amountYuan": r["amountYuan"],
            "points": r["points"],
            "channel": ptype,
            "qrContent": m.get("qrcode") or m.get("payurl") or "",
            "payurl": m.get("payurl") or "",
        })
'''
assert anchor in s, 'recharge_create anchor missing'
assert '/v1/points/recharge/qr' not in s, 'route already exists'
s = s.replace(anchor, new_block, 1)
io.open(P, 'w', encoding='utf-8').write(s)
print('2) /v1/points/recharge/qr added')
