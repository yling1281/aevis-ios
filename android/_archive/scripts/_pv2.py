import sys, sqlite3, time
sys.path.insert(0,'/opt/aevis/service')
import aevis_points_shop as ps
con = sqlite3.connect('/opt/aevis/data/aevis.db')
con.execute("INSERT OR REPLACE INTO aevis_pay_cfg(k,v,updated_at) VALUES(?,?,?)",
            ('member.price_30d', '10', 'test'))
con.commit(); con.close()
print('写入 10 分，等 35s 过缓存…')
time.sleep(35)
print('30d =', ps.member_price_cents('member_30d'))
con = sqlite3.connect('/opt/aevis/data/aevis.db')
con.execute("DELETE FROM aevis_pay_cfg WHERE k=?", ('member.price_30d',))
con.commit(); con.close()
print('已恢复；再等 35s…')
time.sleep(35)
print('30d =', ps.member_price_cents('member_30d'))
