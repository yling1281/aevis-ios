import io

# ---------- Api: signOut 先备份 + backupPull(force) + backupPeek ----------
p = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/data/Api.kt'
s = io.open(p, encoding='utf-8').read()

old_signout = '    fun signOut() { prefs().edit().clear().apply() }'
new_signout = '''    /**
     * 退出登录（2026-11-16 改）。
     *
     * **先推云备份再清本地** —— 不做这一步的话，用户一退出登录，本地 `conv_*` 全被清空，
     * 聊天记录就永久没了（以前就是这样）。推失败也照样退，不能把用户卡在登录态。
     * 「账号隔离」靠两件事：服务端按账号一行存 + 本地退出即清空。
     */
    fun signOut() {
        if (token() != null) runCatching { backupPush() }
        prefs().edit().clear().apply()
    }'''
assert old_signout in s
s = s.replace(old_signout, new_signout, 1)

old_pull = '''    /** 拉云备份，**只在本地没有会话时**恢复。返回恢复了几个会话。*/
    fun backupPull(): Int {
        if (prefs().all.keys.any { it.startsWith("conv_") }) return 0'''
new_pull = '''    /**
     * 拉云备份。返回恢复了几个会话。
     *
     * `force = false`（默认）：**只在本地一条会话都没有时**恢复 —— 防止换手机登录时
     * 云上的旧记录把新聊的盖掉。
     * `force = true`：用户明确点了「恢复」，照做。
     */
    fun backupPull(force: Boolean = false): Int {
        if (!force && prefs().all.keys.any { it.startsWith("conv_") }) return 0'''
assert old_pull in s
s = s.replace(old_pull, new_pull, 1)

# 云上有没有记录（登录时问一句用）
anchor = '''    /** 拉云备份。返回恢复了几个会话。'''
peek = '''    /** 云上有几个会话（登录时用来问「云端有记录，恢复吗」）。失败/未登录返回 0。*/
    fun backupPeek(): Int {
        if (token() == null) return 0
        val (code, json) = get("/v1/chat/backup", token())
        if (code !in 200..299) return 0
        val convs = json.optJSONObject("data")?.optJSONObject("convs")
            ?: json.optJSONObject("convs") ?: return 0
        return convs.length()
    }

''' + anchor
assert anchor in s
s = s.replace(anchor, peek, 1)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('Api patched')
