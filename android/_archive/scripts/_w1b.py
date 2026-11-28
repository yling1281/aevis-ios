import io

base = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/'

# ---------- 1) 默认值：chatMode=1（内心 OS）+ typewriter=true；迁移一律按这个来 ----------
p = base + 'core/ChatPrefs.kt'
s = io.open(p, encoding='utf-8').read()

s = s.replace('''        get() {
            migrateModeOnce()
            return getInt("chatMode", 1).coerceIn(0, 1)
        }''','''        get() {
            migrateModeOnce()
            return getInt("chatMode", 1).coerceIn(0, 1)
        }''')

s = s.replace('''        get() {
            migrateModeOnce()
            return prefs().getBoolean("typewriter", false)
        }''','''        get() {
            migrateModeOnce()
            // 用户：「默认内心 OS 开逐字」——新装用户默认开
            return prefs().getBoolean("typewriter", true)
        }''')

old_mig = '''        val old = p.getInt("displayMode", 0)
        val ed = p.edit()
        when (old) {
            0 -> { ed.putInt("chatMode", 1); ed.putBoolean("typewriter", false) }
            1 -> { ed.putInt("chatMode", 1); ed.putBoolean("typewriter", true) }
            2 -> { ed.putInt("chatMode", 0); ed.putBoolean("typewriter", false) }
            else -> { ed.putInt("chatMode", 1); ed.putBoolean("typewriter", false) }
        }
        ed.putBoolean("migratedMode", true).apply()'''
new_mig = '''        // 2026-11-16 用户口径：「默认内心 OS 开逐字」——
        // 老用户**不管以前是 0/1/2，一律**迁成 内心 OS + 逐字，并且只迁一次；
        // 之后用户自己在设置里关掉，就保持关（不会再被迁移覆盖）。
        val ed = p.edit()
        ed.putInt("chatMode", 1)
        ed.putBoolean("typewriter", true)
        ed.putBoolean("migratedMode", true).apply()'''
assert old_mig in s, 'migration block missing'
s = s.replace(old_mig, new_mig, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('defaults + migration updated')

# ---------- 2) 云同步：ON_STOP 强制推 + 失败可见 ----------
p2 = base + 'data/Api.kt'
s2 = io.open(p2, encoding='utf-8').read()

# 2a) backupPush 记录成功时间/大小；失败码
old = '''        val (code, json) = post("/v1/chat/backup", body, token())'''
if old not in s2:
    import re
    m = re.search(r'val \(code, json\) = post\("/v1/chat/backup"[^\n]*\n', s2)
    print('push post line:', m.group(0) if m else 'NOT FOUND')
s2 = s2.replace('''        if (code in 200..299) return true''','''        if (code in 200..299) {
            lastBackupOkAt = System.currentTimeMillis()
            lastBackupBytes = body.toString().toByteArray().size.toLong()
            lastBackupError = ""
            return true
        }''', 1)

s2 = s2.replace('''    /** 上一次备份失败的原因（413 = 空间满）。*/
    @Volatile
    var lastBackupError: String = ""''','''    /** 上一次备份失败的原因（413 = 空间满）。*/
    @Volatile
    var lastBackupError: String = ""

    /** 上一次成功同步的时间 / 大小（云空间页底部那行小字用）。*/
    @Volatile
    var lastBackupOkAt: Long = 0L

    @Volatile
    var lastBackupBytes: Long = 0L''', 1)

# 2b) 强制推（ON_STOP 用，绕过节流）
s2 = s2.replace('''    fun backupPushThrottled() {''','''    /** 绕过节流强制推一次（App 退到后台时用 —— 要离开了，不能再等 30 秒）。*/
    fun backupPushNow() {
        lastBackupAt = System.currentTimeMillis()
        runCatching { backupPush() }
    }

    fun backupPushThrottled() {''', 1)

io.open(p2, 'w', encoding='utf-8', newline='\n').write(s2)
print('backup push metadata + force push')
