import sys, json
sys.path.insert(0, '/opt/aevis/service')
import aevis_points_shop as ps
# 取一个真实账号做探针（只读 SELECT，不写账号表）
import app as _app  # noqa  (确保 DB 初始化)
DB = None
for cand in ('DB', 'db', 'DATABASE'):
    if hasattr(_app, cand):
        DB = getattr(_app, cand); break
print('db_attr=%s' % type(DB).__name__ if DB is not None else 'db_attr=NONE')
