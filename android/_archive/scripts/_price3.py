import io
P = '/opt/aevis/service/aevis_points_shop.py'
s = io.open(P, encoding='utf-8').read()
old = '''    key = "member.price_" + plan.replace("member_", "")
    try:
        v = (epay_db().get(key) or "").strip()
    except Exception:
        v = ""'''
new = '''    key = "member.price_" + plan.replace("member_", "")
    # ⚠️ 不能用 `epay_db()`：它只捞 `epay.*` 前缀的键（见 aevis_shop.py:211 注释），
    # 我们自己写的 `member.price_*` 读不到。这里直连库读，且**不带缓存**（改价即时生效）。
    v = ""
    try:
        import sqlite3 as _sq
        import os as _os
        c = _sq.connect(_os.getenv("AEVIS_DB", "/opt/aevis/data/aevis.db"), timeout=5)
        try:
            row = c.execute("SELECT v FROM aevis_pay_cfg WHERE k=?", (key,)).fetchone()
            if row and row[0] is not None:
                v = str(row[0]).strip()
        finally:
            c.close()
    except Exception:
        v = ""'''
assert old in s, 'body anchor missing'
s = s.replace(old, new, 1)
io.open(P, 'w', encoding='utf-8').write(s)
print('member_price_cents 改为直连库读')
