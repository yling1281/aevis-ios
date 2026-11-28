import io

p = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/ui/Screens.kt'
s = io.open(p, encoding='utf-8').read()

# 1) 路由：区分"从群里进来"和"从聊天列表进来"（导航栈是单层的，page 只有一个）
old = '''        route.startsWith("groupprofile:") ->
            GroupProfileScreen(
                gid = route.removePrefix("groupprofile:"),
                onBack = back
            )'''
new = '''        route.startsWith("groupprofile:") -> {
            // ⚠️ 这套导航是**单层**的（只有 `page` 一个槽，不是栈）：
            // 从群聊 `go("groupprofile:…")` 进来后，`back()` 会把 page 清空 →
            // 直接回到 tab 根页（聊天列表），**不会**回到群聊。
            // 所以用后缀标记来源：群聊进来的带 `@group`，返回时自己 go 回群聊。
            val raw = route.removePrefix("groupprofile:")
            val fromGroup = raw.endsWith("@group")
            val gid = raw.removeSuffix("@group")
            GroupProfileScreen(
                gid = gid,
                onBack = { if (fromGroup) go("group:" + gid) else back() }
            )
        }'''
assert old in s, 'groupprofile route anchor missing'
s = s.replace(old, new, 1)

# 2) 群聊里的入口带 @group
old2 = '''                onOpenProfile = { go("groupprofile:" + it) }'''
new2 = '''                // 带 @group：群资料返回时回到群聊（导航是单层的，见上面路由里的说明）
                onOpenProfile = { go("groupprofile:" + it + "@group") }'''
assert old2 in s, 'onOpenProfile call anchor missing'
s = s.replace(old2, new2, 1)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('groupprofile back-to-group fixed')
