import sys, time, json
sys.path.insert(0,'/opt/aevis/service')
import aevis_points_shop as ps
for t in ("wxpay","alipay"):
    r = ps.epay_mapi("PROBE%d%s" % (int(time.time()), t[:2]), t, 1.00,
                     "Aevis probe", clientip="103.236.72.107")
    print("=== %s code=%s" % (t, r.get("code")))
    print(json.dumps(r, ensure_ascii=False)[:260])
