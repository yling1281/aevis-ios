import io

P = '/opt/aevis/service/aevis_points_shop.py'
s = io.open(P, encoding='utf-8').read()

# ---------- 1) 会员现金价（模块级） ----------
if 'MEMBER_PRICE_CENTS' not in s:
    anchor = 'def epay_mapi(out_trade_no, pay_type="wxpay", money_yuan=1.0, name="Aevis 积分",'
    consts = '''# 会员**现金价**（2026-11-18）：与"积分兑换"那套（700/2500/6750 积分）
# 是两条不同的账，别混用。后台想改价时优先读 aevis_pay_cfg，回落这里的默认值。
MEMBER_PRICE_CENTS = {"member_7d": 600, "member_30d": 1800, "member_90d": 4500}
MEMBER_DAYS = {"member_7d": 7, "member_30d": 30, "member_90d": 90}


def _mb_ensure(c):
    """会员单表（MB 前缀）。只加不删，state: pending → paid。"""
    c.execute(
        "CREATE TABLE IF NOT EXISTS aevis_mb_order("
        "order_no TEXT PRIMARY KEY, uid INTEGER, plan TEXT, days INTEGER,"
        "amount_cents INTEGER, state TEXT DEFAULT 'pending', created_at INTEGER)"
    )


def _mb_new_no():
    import random
    import time as _t
    return "MB" + _t.strftime("%y%m%d%H%M%S", _t.localtime()) + \\
        "%04X" % random.randint(0, 0xFFFF)


''' + anchor
    assert anchor in s
    s = s.replace(anchor, consts, 1)
    print('1) 会员价常量 + MB 表助手 已加')

# ---------- 2) 两个路由（挂在现有 bp 上，紧邻 recharge_records） ----------
anchor2 = '''    @bp.get("/v1/points/recharge/records")'''
routes = '''    # ---------------- 会员扫码支付（2026-11-18）：MB 前缀 ----------------
    @bp.post("/v1/pay/member/qr")
    def member_qr():
        u = token_uid()
        if not u:
            return err("请先登录", 401, 401)
        b = request.get_json(silent=True) or {}
        plan = (b.get("plan") or b.get("pkg") or "").strip()
        if plan not in MEMBER_PRICE_CENTS:
            return err("不支持的会员档位", 400, 400)
        cents = MEMBER_PRICE_CENTS[plan]
        days = MEMBER_DAYS[plan]
        xff = (request.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
        clientip = xff or (request.remote_addr or "")
        order_no = _mb_new_no()
        c = store._conn()
        try:
            _mb_ensure(c)
            c.execute(
                "INSERT INTO aevis_mb_order(order_no,uid,plan,days,amount_cents,state,created_at)"
                " VALUES(?,?,?,?,?,'pending',?)",
                (order_no, u, plan, days, cents, int(__import__('time').time())))
            c.commit()
        finally:
            c.close()
        m = epay_mapi(order_no, "wxpay", cents / 100.0,
                      "Aevis 会员 %d 天" % days, clientip=clientip)
        if m.get("code") != 1:
            return err(m.get("msg") or "下单失败", 4101, 200)
        return ok({
            "orderNo": order_no,
            "plan": plan,
            "days": days,
            "amountYuan": "%.2f" % (cents / 100.0),
            "qrContent": m.get("qrcode") or m.get("payurl") or "",
            "payurl": m.get("payurl") or "",
        })

    @bp.get("/v1/pay/member/<order_no>")
    def member_one(order_no):
        u = token_uid()
        if not u:
            return err("请先登录", 401, 401)
        c = store._conn()
        try:
            _mb_ensure(c)
            r = c.execute("SELECT * FROM aevis_mb_order WHERE order_no=?",
                          (order_no,)).fetchone()
        finally:
            c.close()
        if not r:
            return err("订单不存在", 404, 404)
        if int(r["uid"]) != int(u):
            return err("订单不属于当前账号", 403, 403)
        return ok({
            "orderNo": r["order_no"], "plan": r["plan"], "days": int(r["days"]),
            "amountYuan": "%.2f" % (int(r["amount_cents"]) / 100.0),
            "status": r["state"], "state": r["state"],
        })

''' + anchor2
assert anchor2 in s, 'records anchor missing'
assert '/v1/pay/member/qr' not in s, 'routes already exist'
s = s.replace(anchor2, routes, 1)
io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('2) member/qr + member/<no> 路由已加')
