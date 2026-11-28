import sys, json, sqlite3, glob, os
sys.path.insert(0,'/opt/aevis/service')
import aevis_points_shop as ps
store = getattr(ps,'store',None)
print('store=%s' % type(store).__name__)
# 找一个真实 uid：直接读库（只读）
db=None
for cand in ('DB','db','DB_PATH'):
    v=getattr(ps,cand,None)
    if isinstance(v,str): db=v
print('db_path=%s' % db)
uid=None
try:
    path = db or '/opt/aevis/data/aevis.db'
    con=sqlite3.connect('file:%s?mode=ro'%path, uri=True)
    row=con.execute("SELECT id FROM auth_account ORDER BY id LIMIT 1").fetchone()
    uid=row[0] if row else None
    print('uid=%s' % uid)
except Exception as e:
    print('db_read_fail: %s' % str(e)[:120])
if uid and store:
    r=store.create_recharge(uid,'pt_1','wxpay')
    print('create_ok=%s orderNo=%s cents=%s points=%s' % (r.get('ok'), r.get('orderNo'), r.get('amountCents'), r.get('points')))
    if r.get('ok'):
        from aevis_shop import epay_mapi
        m=epay_mapi(r['orderNo'],'wxpay',r['amountCents']/100.0,"Aevis 积分 %d 分"%r['points'],clientip='103.236.72.107')
        print('mapi_code=%s qrcode=%s' % (m.get('code'), (m.get('qrcode') or '')[:110]))
        st=store.recharge_status(uid, r['orderNo'])
        print('state=%s' % st.get('state'))
