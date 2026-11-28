import io
SHP='/opt/aevis/service/aevis_shop.py'
PTS='/opt/aevis/service/aevis_points_shop.py'

shop=io.open(SHP,encoding='utf-8').read()
i=shop.find('\n\ndef epay_mapi(')
assert i>0, 'shop epay_mapi not found'
fn=shop[i:]
shop=shop[:i]+'\n'
io.open(SHP,'w',encoding='utf-8').write(shop)
print('shop: epay_mapi removed, %d chars' % len(fn))

pts=io.open(PTS,encoding='utf-8').read()
assert 'def epay_mapi(' not in pts
pts=pts.rstrip('\n')+'\n'+fn
# 路由改为本地调用（唯一副本在 points_shop）
pts=pts.replace('''        from aevis_shop import epay_mapi      # 签名逻辑只保留 aevis_shop 那一个副本
        m = epay_mapi(r["orderNo"], ptype, r["amountCents"] / 100.0,
                      "Aevis 积分 %d 分" % r["points"], clientip=clientip)''','''        m = epay_mapi(r["orderNo"], ptype, r["amountCents"] / 100.0,
                      "Aevis 积分 %d 分" % r["points"], clientip=clientip)''',1)
# recharge_one 补 status 别名
old='''        r = store.recharge_status(u, order_no)
        return ok(r) if r.get("ok") else err(r["msg"], r["code"])'''
new='''        r = store.recharge_status(u, order_no)
        if r.get("ok"):
            r["status"] = r.get("state")     # 前端统一读 status（网页版/App 都按这个）
        return ok(r) if r.get("ok") else err(r["msg"], r["code"])'''
assert old in pts
pts=pts.replace(old,new,1)
io.open(PTS,'w',encoding='utf-8').write(pts)
print('points_shop: epay_mapi moved in + status alias added')
