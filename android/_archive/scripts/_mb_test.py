import sys, os, time, json, urllib.parse, urllib.request
sys.path.insert(0,'/opt/aevis/service')
import aevis_points_shop as ps
from aevis_shop import epay_config, epay_sign

DB = None
# 找一个真实 uid
import sqlite3, glob
for cand in glob.glob('/opt/aevis/**/*.db', recursive=True)[:6]:
    try:
        con = sqlite3.connect('file:%s?mode=ro' % cand, uri=True)
        row = con.execute("SELECT id FROM auth_account ORDER BY id LIMIT 1").fetchone()
        if row:
            uid = row[0]; DB = cand; break
    except Exception:
        pass
else:
    print('no db'); sys.exit(0)
print('db=%s uid=%s' % (DB, uid))

sys.path.insert(0,'/opt/aevis/service')
import importlib
ps2 = importlib.import_module('aevis_points_shop')
# 用一个假 store 取连接
class S:
    db_path = DB
    def _conn(self):
        c = sqlite3.connect(self.db_path, timeout=10); c.row_factory = sqlite3.Row; return c
st = S()

no = ps2._mb_new_no()
c = st._conn()
ps2._mb_ensure(c)
c.execute("INSERT INTO aevis_mb_order(order_no,uid,plan,days,amount_cents,state,created_at)"
          " VALUES(?,?,?,?,?,'pending',?)", (no, uid, 'member_7d', 7, 600, int(time.time())))
c.commit()
print('order=%s' % no)

cfg = epay_config()
params = {'pid': cfg['pid'], 'out_trade_no': no, 'trade_no': 'TESTTRADE1',
          'trade_status': 'TRADE_SUCCESS', 'money': '6.00', 'type': 'wxpay'}
params['sign'] = epay_sign(params, cfg['key']); params['sign_type'] = 'MD5'
body = urllib.parse.urlencode(params).encode()
def notify():
    req = urllib.request.Request('http://127.0.0.1:8788/v1/points/epay/notify', data=body,
                                 headers={'Content-Type':'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, r.read().decode()[:40]
print('notify#1', notify())
row = c.execute("SELECT state,trade_no,paid_at FROM aevis_mb_order WHERE order_no=?", (no,)).fetchone()
print('state=%s trade=%s paid_at=%s' % (row['state'], row['trade_no'], row['paid_at']))
print('notify#2(幂等)', notify())
c.close()
