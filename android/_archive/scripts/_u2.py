import io

base = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/'

# 1) Api.chat：按 ctxWindow 截断 history
p = base + 'data/Api.kt'
s = io.open(p, encoding='utf-8').read()
old = '''        history.filter { !it.skip }.forEach {'''
new = '''        // 上下文条数（2026-11-16）：只把最近 N 条发给模型，避免上下文越来越长、越来越贵。
        // 默认 12，跟改之前的行为一致（3–24 可调）。
        val win = com.aevis.android.core.ChatPrefs.ctxWindow
        history.filter { !it.skip }.takeLast(win).forEach {'''
assert old in s
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('ctxWindow applied')

# 2) sys 加【回复长度】
p2 = base + 'ui/ChatScreen.kt'
s2 = io.open(p2, encoding='utf-8').read()
old2 = '''                // 上次模型自己给的状态（没有就是「在线」），喂回去让它连贯
                append("\\n【当前状态】你现在$statusText。")'''
new2 = '''                // 上次模型自己给的状态（没有就是「在线」），喂回去让它连贯
                append("\\n【当前状态】你现在$statusText。")
                // 回复长度（2026-11-16）：三档，直接影响模型的篇幅
                append(
                    when (com.aevis.android.core.ChatPrefs.replyLen) {
                        0 -> "\\n【回复长度】简洁：一两句，不铺陈。"
                        2 -> "\\n【回复长度】话痨：可以多写几句，但别写成小说。"
                        else -> "\\n【回复长度】常规：按对话自然长度。"
                    }
                )'''
assert old2 in s2, 'sys status anchor missing'
s2 = s2.replace(old2, new2, 1)
io.open(p2, 'w', encoding='utf-8', newline='\n').write(s2)
print('replyLen in sys')
