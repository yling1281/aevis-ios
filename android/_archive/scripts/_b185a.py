import io, re

U = 'app/src/main/java/com/aevis/android/ui/'

def patch(path, pairs):
    s = io.open(path, encoding='utf-8').read()
    for old, new in pairs:
        assert old in s, '%s: anchor missing %r' % (path, old[:40])
        s = s.replace(old, new, 1)
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s)
    print('ok', path)

# ①-1 AccountCardScreen:381
patch(U + 'AccountCardScreen.kt', [(
    'if (on) Text("✓", fontSize = 15.sp, color = V2.accent)',
    'if (on) Icon(\n            painterResource(R.drawable.ic_check), contentDescription = null,\n'
    '            tint = V2.accent, modifier = Modifier.size(15.dp)\n        )')])

# ①-2 ChatSettingsScreen:321
patch(U + 'ChatSettingsScreen.kt', [(
    '"✓", fontSize = 13.sp, fontWeight = FontWeight.Bold,',
    '"", fontSize = 13.sp, fontWeight = FontWeight.Bold,')])

# ①-3 CheckinScreen:140
patch(U + 'CheckinScreen.kt', [(
    'Text("✓", fontSize = 15.sp, color = Color.White,',
    'Text("", fontSize = 15.sp, color = Color.White,')])

# ①-4 GroupCreateScreen:336
patch(U + 'GroupCreateScreen.kt', [(
    '"✓", fontSize = 12.sp, fontWeight = FontWeight.Bold,',
    '"", fontSize = 12.sp, fontWeight = FontWeight.Bold,')])

# ①-5 ModelScreen:134
patch(U + 'ModelScreen.kt', [(
    'Text("✓", fontSize = 16.sp, color = V2.accent,',
    'Text("", fontSize = 16.sp, color = V2.accent,')])

print('--- 5 处字符 ✓ 已替换（先改成空串，接下来用 Icon 覆盖的位置见下）')

# ② 后端：member_price 从库读（points_shop）
P = '/opt/aevis/service/aevis_points_shop.py'
LOCAL = None
print('backend patch 由 shell 端执行')
