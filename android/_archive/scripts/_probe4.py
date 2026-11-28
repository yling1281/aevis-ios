import sys, time, json, urllib.parse, urllib.request
sys.path.insert(0,'/opt/aevis/service')
from aevis_shop import epay_config, epay_sign
cfg = epay_config()
def run(tag, ret, extra=None, typ="alipay"):
    p = {"pid": cfg["pid"], "type": typ, "out_trade_no": "PROBE%d" % int(time.time()*1000 % 1e10),
         "notify_url": cfg["public_base"] + "/v1/points/epay/notify",
         "return_url": ret, "name": "Aevis probe", "money": "1.00",
         "clientip": "103.236.72.107"}
    if extra: p.update(extra)
    p["sign"] = epay_sign(p, cfg["key"]); p["sign_type"] = "MD5"
    body = urllib.parse.urlencode(p).encode()
    req = urllib.request.Request(cfg["gateway"] + "/mapi.php", data=body,
        headers={"Content-Type":"application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=20) as r:
        txt = r.read().decode()
    try: j = json.loads(txt)
    except Exception: j = {"raw": txt[:120]}
    print(tag, "code=%s" % j.get("code"), (j.get("qrcode") or j.get("payurl") or j.get("msg") or "")[:95])
run("A lead参数(/pay/return)  ", "https://aevis.cn/pay/return")
run("B /recharge            ", "https://aevis.cn/recharge")
run("C /recharge+sitename   ", "https://aevis.cn/recharge", {"sitename": cfg["sitename"]})
