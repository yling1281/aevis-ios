import sys, json, time, hashlib, urllib.request, urllib.parse

sys.path.insert(0, '/opt/aevis/service')
import aevis_shop as shop   # noqa

cfg = shop.epay_config()
gw = (cfg.get('gateway') or '').rstrip('/')
pid = str(cfg.get('pid') or '')
key = cfg.get('key') or ''
print('gateway=%s pid=%s key_len=%d' % (gw, pid, len(key)))

out_no = 'probe%d' % int(time.time())
params = {
    'pid': pid,
    'type': 'wxpay',
    'out_trade_no': out_no,
    'notify_url': 'https://aevis.cn/prod-api/aevis/v1/points/epay/notify',
    'return_url': 'https://aevis.cn/pay/return',
    'name': 'Aevis 积分',
    'money': '1.00',
    'clientip': '103.236.72.107',
}
raw = '&'.join('%s=%s' % (k, params[k]) for k in sorted(params))
sign = hashlib.md5((raw + key).encode('utf-8')).hexdigest().lower()
params['sign'] = sign
params['sign_type'] = 'MD5'

body = urllib.parse.urlencode(params).encode()
req = urllib.request.Request(gw + '/mapi.php', data=body,
                             headers={'Content-Type': 'application/x-www-form-urlencoded'})
try:
    with urllib.request.urlopen(req, timeout=25) as r:
        txt = r.read().decode('utf-8', 'replace')
except Exception as e:
    print('HTTP_ERROR:', type(e).__name__, str(e)[:200])
    sys.exit(0)

print('resp_len=%d' % len(txt))
try:
    j = json.loads(txt)
    print('code=%s msg=%s' % (j.get('code'), (j.get('msg') or '')[:120]))
    print('payurl=%s' % (j.get('payurl') or '')[:120])
    q = j.get('qrcode') or ''
    print('qrcode_len=%d qrcode=%s' % (len(q), q[:120]))
except Exception:
    print('raw=%s' % txt[:300])
