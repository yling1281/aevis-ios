import io

P = '/opt/aevis/service/aevis_points_shop.py'
s = io.open(P, encoding='utf-8').read()

anchor = 'MEMBER_DAYS = {"member_7d": 7, "member_30d": 30, "member_90d": 90}'
assert anchor in s, 'anchor missing'

if 'def member_price_cents' not in s:
    add = anchor + '''


def member_price_cents(plan):
    """会员现金价：优先读后台 `aevis_pay_cfg` 的 member.price_7d/30d/90d，回落常量。"""
    key = "member.price_" + plan.replace("member_", "")
    try:
        v = (epay_db().get(key) or "").strip()
    except Exception:
        v = ""
    if v.isdigit():
        return int(v)
    return MEMBER_PRICE_CENTS.get(plan, 0)'''
    s = s.replace(anchor, add, 1)
    print('member_price_cents 已加')
else:
    print('member_price_cents 已存在')

old = '        cents = MEMBER_PRICE_CENTS[plan]'
if old in s:
    s = s.replace(old, '        cents = member_price_cents(plan)   # 从后台配置读，改价即时生效', 1)
    print('建单处已改为读配置')
else:
    print('建单处已是 member_price_cents（或锚点变了）')

io.open(P, 'w', encoding='utf-8').write(s)
print('written')
