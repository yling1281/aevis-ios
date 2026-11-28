import io
P='/opt/aevis/service/aevis_points_shop.py'
s=io.open(P,encoding='utf-8').read()
i=s.find('\n\ndef epay_mapi(')
assert i>0, 'dup block not found'
s=s[:i]+'\n'
# 路由改为用 aevis_shop 的那一份（避免两处签名逻辑）
s=s.replace('''        m = epay_mapi(r["orderNo"], r["amountCents"], r["points"], ptype,
                      clientip, platform)''','''        from aevis_shop import epay_mapi      # 签名逻辑只保留 aevis_shop 那一个副本
        m = epay_mapi(r["orderNo"], ptype, r["amountCents"] / 100.0,
                      "Aevis 积分 %d 分" % r["points"], clientip=clientip)''',1)
io.open(P,'w',encoding='utf-8').write(s)
print('dedupe ok; epay_mapi local removed')
