import io

p = r'F:/WorkBuddy/2026-10-17-23-43-43/aevis-ios/android/app/src/main/java/com/aevis/android/ui/ChatScreen.kt'
s = io.open(p, encoding='utf-8').read()

# ---------- 1) 展开态的清洗：改成正规的正则，而不是 removePrefix/removeSuffix ----------
old = """                // 展开时给人看的也洗一遍：去掉 LaTeX 包裹，只留内容
                buf.add(
                    l.trim().removePrefix("\\$").removeSuffix("\\$")
                        .removePrefix("\\\\text{").removeSuffix("}").trim()
                )"""
assert old in s, 'cleanup anchor missing'
new = """                // 展开态渲染前的清洗（2026-11-16 二次修）：
                // 真机上展开后还是 `$\\text{性器状态: 绛红充血极度挺立}$` ——
                // 原来用 removePrefix/removeSuffix 只能扒最外一层，模型写的是
                // `$\\text{…}$` 套在行里，前后还有空格，硬扒就漏了。改成正则。
                buf.add(cleanBlockLine(l.trim()))"""
s = s.replace(old, new, 1)

# ---------- 2) 清洗函数 + 括号/正文的浅色不要浅到看不见 ----------
s += '''
/**
 * 折叠条**展开后**给人看的那几行，渲染前洗一遍（2026-11-16）。
 *
 * 1. `$\\text{xxx}$` / `\\text{xxx}` → `xxx`
 * 2. 其它 LaTeX 命令 `\\foo{xxx}` → `xxx`
 * 3. markdown 记号 `**` / `__` / 反引号 全去掉（气泡里是说明文字，不该出现记号）
 */
internal fun cleanBlockLine(raw: String): String {
    var t = raw
    // $\\text{…}$ —— `$` 可有可无，允许前后空白
    t = Regex("\\\\$?\\\\s*\\\\\\\\text\\\\{([^}]*)\\\\}\\\\s*\\\\$?").replace(t, "$1")
    // 其它 \\foo{…}
    t = Regex("\\\\\\\\[a-zA-Z]+\\\\{([^}]*)\\\\}").replace(t, "$1")
    // markdown
    t = t.replace("**", "").replace("__", "").replace("`", "")
    return t.trim()
}
'''

# ---------- 3) 括号色：浅色主题下 0.55 太淡，读起来像"丢字"，抬到 0.72 ----------
old3 = "textColor.copy(alpha = 0.55f)"
new3 = ("// 2026-11-16：0.55 在浅色气泡上太淡，用户会以为「中间的字丢了」——\n"
        "                                    // 仍然比正文淡，但保证能读。\n"
        "                                    textColor.copy(alpha = 0.72f)")
assert old3 in s
s = s.replace(old3, new3, 1)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('format cleanup + dim alpha patched')
