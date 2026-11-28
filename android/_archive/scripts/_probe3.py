import sys, time, json
sys.path.insert(0,'/opt/aevis/service')
import aevis_points_shop as ps
for t in ("wxpay","alipay"):
    no = "PROBE" + str(int(time.time())) + t[:2]
    r = ps.epay_mapi(no, t, 1.00, "Aevis probe", clientip="103.236.72.107")
    print("=== %s  code=%s" % (t, r.get("code")))
    print("raw:", json.dumps(r, ensure_ascii=False)[:300])
