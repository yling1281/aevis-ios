import sys, time, json
sys.path.insert(0,'/opt/aevis/service')
import aevis_points_shop as ps
time.sleep(50)   # 冷却，验证"短时间连下多单被降级"的假设
for t in ("wxpay","alipay"):
    r = ps.epay_mapi("P%d%s" % (int(time.time()), t[:2]), t, 1.00, "Aevis 积分", clientip="103.236.72.107")
    print("%s code=%s -> %s" % (t, r.get("code"), (r.get("qrcode") or r.get("payurl") or r.get("msg") or "")[:95]))
    time.sleep(12)
