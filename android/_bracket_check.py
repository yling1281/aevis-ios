"""Android Kotlin 括号/引号配平词法扫描（android-parity 一致性审查用）。

按文件逐字扫描，跳过：
- 行注释 // ...、块注释 /* ... */（可嵌套）
- 普通字符串 "..."（含转义）、字符字面量 '...'
- Kotlin 三引号字符串 \"\"\"...\"\"\"

统计 { } ( ) [ ] 是否配平，并报告未闭合 / 多余的位置（行号）。
只做词法层面检查，不替代 kotlinc 编译。
"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "app", "src", "main", "java")

PAIRS = {'}': '{', ')': '(', ']': '['}
OPENS = set(PAIRS.values())


def scan(path):
    with open(path, encoding='utf-8') as fh:
        s = fh.read()
    n = len(s)
    stack = []
    issues = []
    i = 0
    line = 1
    while i < n:
        ch = s[i]
        nxt = s[i + 1] if i + 1 < n else ''
        if ch == '\n':
            line += 1
        # 行注释
        if ch == '/' and nxt == '/':
            i += 2
            while i < n and s[i] != '\n':
                i += 1
            continue
        # 块注释（Kotlin 允许嵌套）
        if ch == '/' and nxt == '*':
            depth = 1
            i += 2
            while i < n and depth > 0:
                if s[i] == '\n':
                    line += 1
                if s[i] == '/' and i + 1 < n and s[i + 1] == '*':
                    depth += 1
                    i += 2
                    continue
                if s[i] == '*' and i + 1 < n and s[i + 1] == '/':
                    depth -= 1
                    i += 2
                    continue
                i += 1
            continue
        # 三引号字符串
        if s.startswith('"""', i):
            i += 3
            while i < n and not s.startswith('"""', i):
                if s[i] == '\n':
                    line += 1
                if s[i] == '\\' and i + 1 < n:
                    i += 2
                    continue
                i += 1
            i = min(i + 3, n)
            continue
        # 普通字符串
        if ch == '"':
            i += 1
            while i < n:
                if s[i] == '\\':
                    i += 2
                    continue
                if s[i] == '"':
                    i += 1
                    break
                if s[i] == '\n':
                    line += 1
                i += 1
            continue
        # 字符字面量（含转义，如 '\'' / '\\'）
        if ch == "'":
            i += 1
            while i < n:
                if s[i] == '\\':
                    i += 2
                    continue
                if s[i] == "'":
                    i += 1
                    break
                if s[i] == '\n':
                    line += 1
                i += 1
            continue
        if ch in OPENS:
            stack.append((ch, line))
        elif ch in PAIRS:
            if stack and stack[-1][0] == PAIRS[ch]:
                stack.pop()
            else:
                issues.append("L%d: 多余的 '%s'（栈顶=%s）" %
                              (line, ch, stack[-1][0] if stack else '空'))
        i += 1
    for ch, ln in stack:
        issues.append("L%d: 未闭合 '%s'" % (ln, ch))
    return issues


def main():
    files = []
    for dirpath, _, names in os.walk(ROOT):
        for name in names:
            if name.endswith('.kt'):
                files.append(os.path.join(dirpath, name))
    files.sort()
    bad = 0
    for f in files:
        issues = scan(f)
        rel = os.path.relpath(f, os.path.dirname(ROOT))
        if issues:
            bad += 1
            print("[FAIL] %s" % rel)
            for it in issues[:20]:
                print("   " + it)
        else:
            print("[OK]   %s" % rel)
    print("\n扫描 %d 个 .kt 文件，%d 个不平衡。" % (len(files), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
