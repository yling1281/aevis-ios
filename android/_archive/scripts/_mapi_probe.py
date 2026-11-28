import sys, json, time
sys.path.insert(0, '/opt/aevis/service')
import aevis_shop as s
r = s.epay_mapi('Q%d' % int(time.time()), 'wxpay', 1.00, 'Aevis 积分', clientip='103.236.72.107')
print('code=%s' % r.get('code'))
print('msg=%s' % str(r.get('msg'))[:100])
print('trade_no=%s' % str(r.get('trade_no'))[:40])
print('qrcode=%s' % str(r.get('qrcode'))[:120])
