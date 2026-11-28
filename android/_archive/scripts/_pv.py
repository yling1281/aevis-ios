import sys, sqlite3
sys.path.insert(0,'/opt/aevis/service')
import aevis_points_shop as ps
print('默认 30d =', ps.member_price_cents('member_30d'))
con = sqlite3.connect('/opt/aevis/data/aevis.db')
con.execute("INSERT OR REPLACE INTO aevis_pay_cfg(k,v,updated_at) VALUES(?,?,?)",
            ('member.price_30d', '10', 'test'))
con.commit(); con.close()
print('改成 10 分后 =', ps.member_price_cents('member_30d'))
con = sqlite3.connect('/opt/aevis/data/aevis.db')
con.execute("DELETE FROM aevis_pay_cfg WHERE k=?", ('member.price_30d',))
con.commit(); con.close()
print('恢复后 =', ps.member_price_cents('member_30d'))
