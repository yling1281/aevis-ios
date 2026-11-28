

def epay_mapi(out_trade_no, pay_type="wxpay", money_yuan=1.0, name="Aevis 积分",
              notify_path="/v1/points/epay/notify", clientip="", return_path="/pay/return"):
    """API 模式下单（mapi.php）—— 返回二维码内容，不再跳网页收银台。

    与 `epay_pay_url`（submit.php）的区别：
      · 走 `/mapi.php`，返回 JSON：`{"code":1,"trade_no":..,"payurl":..,"qrcode":..}`
      · `qrcode` 是**动态码 URL**（形如 https://qrs-wxgzh-web.vbill.cn/wxSweep?id=…），
        客户端把这条 URL 画成二维码即可，用户微信扫码直接进支付页；
      · **`clientip` 必填**：易支付对 mapi 做「非空 + 格式」校验，空着会返回
        `{"code":-1,"msg":"用户IP地址(clientip)不能为空"}`（submit.php 不校验，所以老逻辑没暴露）。

    调用方（Flask 路由）负责把 `X-Forwarded-For` 第一段 / `remote_addr` 传进来。
    返回：解析后的 dict；网络异常返回 `{"code": -1, "msg": "网关请求失败: ..."}`。
    """
    import json as _json
    import urllib.parse as _up
    import urllib.request as _ur

    cfg = epay_config()
    if not (cfg["pid"] and cfg["key"]):
        return {"code": -1, "msg": "未配置易支付 pid/key"}

    ptype = pay_type if pay_type in EPAY_TYPES else "wxpay"
    params = {
        "pid": cfg["pid"],
        "type": ptype,
        "out_trade_no": str(out_trade_no),
        "notify_url": cfg["public_base"] + notify_path,
        "return_url": cfg["public_base"] + return_path,
        "name": name,
        "money": "%.2f" % float(money_yuan),
        # 易支付 mapi 强制要求，空串会被拒
        "clientip": (clientip or "").strip(),
        "device": "mobile",
        "sitename": cfg["sitename"],
    }
    params["sign"] = epay_sign(params, cfg["key"])
    params["sign_type"] = "MD5"

    body = _up.urlencode(params).encode("utf-8")
    req = _ur.Request(cfg["gateway"] + "/mapi.php", data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "aevis-service/1.0",
    })
    try:
        with _ur.urlopen(req, timeout=20) as r:
            txt = r.read().decode("utf-8", "replace")
    except Exception as e:
        return {"code": -1, "msg": "网关请求失败: %s" % e}
    try:
        return _json.loads(txt)
    except Exception:
        return {"code": -1, "msg": "网关返回非 JSON: %s" % txt[:200]}
