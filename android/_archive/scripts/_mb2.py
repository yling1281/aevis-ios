import io

P = '/opt/aevis/service/aevis_points_shop.py'
s = io.open(P, encoding='utf-8').read()

# ---------- 1) 表加列（trade_no / paid_at），幂等 ----------
if 'def _mb_ensure' in s and 'paid_at' not in s.split('def _mb_ensure')[1][:800]:
    old = '''def _mb_ensure(c):
    """会员单表（MB 前缀）。只加不删，state: pending → paid。"""
    c.execute(
        "CREATE TABLE IF NOT EXISTS aevis_mb_order("
        "order_no TEXT PRIMARY KEY, uid INTEGER, plan TEXT, days INTEGER,"
        "amount_cents INTEGER, state TEXT DEFAULT 'pending', created_at INTEGER)"
    )'''
    new = '''def _mb_ensure(c):
    """会员单表（MB 前缀）。只加不删，state: pending → paid。"""
    c.execute(
        "CREATE TABLE IF NOT EXISTS aevis_mb_order("
        "order_no TEXT PRIMARY KEY, uid INTEGER, plan TEXT, days INTEGER,"
        "amount_cents INTEGER, state TEXT DEFAULT 'pending', created_at INTEGER,"
        "trade_no TEXT DEFAULT '', paid_at TEXT DEFAULT '')"
    )
    # 老表补列（幂等）：已经建过不带这两列的版本
    for col in ("trade_no TEXT DEFAULT ''", "paid_at TEXT DEFAULT ''"):
        try:
            c.execute("ALTER TABLE aevis_mb_order ADD COLUMN " + col)
        except Exception:
            pass'''
    assert old in s, '_mb_ensure anchor'
    s = s.replace(old, new, 1)
    print('1) 表结构补齐（trade_no/paid_at）')

# ---------- 2) settle_member（模块级，贴 create 逻辑） ----------
if 'def settle_member(' not in s:
    anchor = 'def _mb_new_no():'
    fn = '''def settle_member(conn, order_no, trade_no, paid_money=None):
    """会员单入账（幂等）：state=paid 直接 already；金额差 >1 分拒绝。

    入账只调 `aevis_pay._extend_membership`（复用现成逻辑，不另写一套）。
    """
    import time as _t
    _mb_ensure(conn)
    row = conn.execute("SELECT * FROM aevis_mb_order WHERE order_no=?",
                       (order_no,)).fetchone()
    if not row:
        return {"ok": False, "code": 4432, "msg": "订单不存在"}
    if (row["state"] or "") == "paid":
        return {"ok": True, "already": True, "days": int(row["days"])}
    if paid_money not in (None, ""):
        try:
            got = int(round(float(paid_money) * 100))
        except (TypeError, ValueError):
            return {"ok": False, "code": 4434, "msg": "金额格式不对"}
        if abs(got - int(row["amount_cents"])) > 1:
            return {"ok": False, "code": 4434, "msg": "金额不符"}
    try:
        from aevis_pay import _extend_membership
        _extend_membership(conn, int(row["uid"]), int(row["days"]), order_no)
    except Exception as e:
        return {"ok": False, "code": 5001, "msg": "延长会员失败: %s" % e}
    conn.execute(
        "UPDATE aevis_mb_order SET state='paid', trade_no=?, paid_at=? WHERE order_no=?",
        (trade_no or "", _t.strftime("%Y-%m-%d %H:%M:%S"), order_no))
    conn.commit()
    return {"ok": True, "days": int(row["days"])}


''' + anchor
    assert anchor in s
    s = s.replace(anchor, fn, 1)
    print('2) settle_member 已加')

# ---------- 3) notify 分流 ----------
old_notify = '''    r = store.settle_recharge(order_no, trade_no, params.get("money"))
    if r.get("ok"): return "success"
    return "fail: %s" % r.get("msg", ""), 400'''
new_notify = '''    # 分流（2026-11-18）：MB* 是会员单，走 settle_member（同样幂等）；其余走积分入账
    if order_no.startswith("MB"):
        c2 = store._conn()
        try:
            r = settle_member(c2, order_no, trade_no, params.get("money"))
        finally:
            c2.close()
    else:
        r = store.settle_recharge(order_no, trade_no, params.get("money"))
    if r.get("ok"): return "success"
    return "fail: %s" % r.get("msg", ""), 400'''
if old_notify in s:
    s = s.replace(old_notify, new_notify, 1)
    print('3) notify 已加 MB 分流')
else:
    print('3) notify anchor MISSING -> 未改')

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('done')
