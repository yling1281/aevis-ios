import io, os

base = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/'

# ---- 0) 删掉本地关键词表 ----
p_old = base + 'core/StatusOf.kt'
if os.path.exists(p_old):
    os.remove(p_old)
    print('deleted StatusOf.kt')

# ---- 1) ChatScreen ----
p = base + 'ui/ChatScreen.kt'
s = io.open(p, encoding='utf-8').read()

# 1a) 头部：状态改成"从 store 读 + 回落在线"
old = '''    // 当前状态（2026-11-16）：每 40–90 秒换一次说法，顶栏那行要"会动"；
    // 空闲时长 = 离这个会话最后一次落盘多久（没记录就当很久）。
    var statusTick by remember { mutableIntStateOf(0) }'''
new = '''    // 当前状态（2026-11-16 改）：**由模型自己给**（回复末尾带 [[状态]] 行，客户端解析后删掉那行）。
    // 这里只负责读；`statusVer` 在每轮回复后 +1 触发重读。
    var statusVer by remember { mutableIntStateOf(0) }
    var statusTick by remember { mutableIntStateOf(0) }'''
assert old in s, 'status head anchor missing'
s = s.replace(old, new, 1)

# 1b) 去掉推断块，改成读 store
old2 = '''    // ---------- 当前状态：按聊天记录实时推断（2026-11-16）----------
    // 用户：「左上角头像上面的状态是根据聊天记录实时进行的」。
    // 纯本地关键词扫描（`core/StatusOf.kt`），不花 token；命中就用，没命中退回时间/空闲那套。
    // key 带上最后一条的内容长度：新消息进来（哪怕条数不变）也会重算。
    val statusLines = remember(msgs.size, msgs.lastOrNull()?.content) {
        msgs.map { com.aevis.android.core.StatusOf.Line(it.role, it.content) }
    }
    val inferredStatus = remember(statusLines) {
        com.aevis.android.core.StatusOf.infer(statusLines)
    }
    val status = inferredStatus ?: remember(statusTick, idleMin) { statusOf(idleMin, statusTick) }
    // 给「聊天设置页 → 显示」那行看依据（纯展示，不影响判断）
    SideEffect {
        com.aevis.android.core.StatusOf.lastLabel = status
        com.aevis.android.core.StatusOf.lastScanned =
            com.aevis.android.core.StatusOf.scannedCount(statusLines)
    }'''
new2 = '''    // ---------- 当前状态：来自 StatusStore（模型给的）----------
    // 从没有过状态（老会话）→ 显示「在线」，**不跑任何本地推断**。
    val stored = remember(statusVer, statusTick, pid) {
        com.aevis.android.core.StatusStore.get(pid)
    }
    val statusText = stored?.first ?: tr("在线")
    val statusAge = stored?.let { com.aevis.android.core.StatusStore.agoMinutes(it.second) } ?: -1L
    // 超 30 分钟：文案后面加「· 30 分钟前」（不把字变没）
    val status = if (statusAge > 30L) tr("%s · %d 分钟前", statusText, statusAge) else statusText'''
assert old2 in s, 'inference block missing'
s = s.replace(old2, new2, 1)

# 1c) sys 里注入上次状态（原来直接拼 $status，现在来源是模型上次给的，可能是「在线」）
old3 = '''                append("\\n【当前状态】你现在$status。")'''
new3 = '''                // 上次模型自己给的状态（没有就是「在线」），喂回去让它连贯
                append("\\n【当前状态】你现在$statusText。")'''
assert old3 in s, 'sys status anchor missing'
s = s.replace(old3, new3, 1)

# 1d) sys 末尾加【状态标记】指令（硬性禁止之后）
old4 = '''                append("违反这条视为格式错误。")'''
new4 = '''                append("违反这条视为格式错误。")
                // 🔵 状态标记（2026-11-16）：让模型在回复最后单独一行给出"此刻的心情/动作"。
                // 这是**额外输出几个字**，比再发一次请求便宜得多。
                append("\\n【状态标记】每次回复的最后单独一行，输出：\\n")
                append("[[状态]]这里写你此刻的心情或动作（2–6 个字，不要标点，不要解释，不要换行）\\n")
                append("这一行是给系统读的，用户看不到，不要在任何别的地方提到它。")'''
assert old4 in s, 'hard ban anchor missing'
s = s.replace(old4, new4, 1)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('ChatScreen status(head/sys) patched')
