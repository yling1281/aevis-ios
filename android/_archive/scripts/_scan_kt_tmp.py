import os
import re
import collections

root = 'app/src/main/java'
decl = collections.defaultdict(list)
brace = []
for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith('.kt'):
            continue
        p = os.path.join(dp, f)
        s = open(p, encoding='utf-8', errors='replace').read()
        depth = 0
        line = 1
        i = 0
        state = 'code'
        while i < len(s):
            c = s[i]
            n = s[i + 1] if i + 1 < len(s) else ''
            if c == '\n':
                line += 1
            if state == 'line_comment':
                if c == '\n':
                    state = 'code'
            elif state == 'block_comment':
                if c == '*' and n == '/':
                    state = 'code'
                    i += 1
            elif state == 'str':
                if c == '\\':
                    i += 1
                elif c == '"':
                    state = 'code'
            elif state == 'code':
                if c == '/' and n == '/':
                    state = 'line_comment'
                    i += 1
                elif c == '/' and n == '*':
                    state = 'block_comment'
                    i += 1
                elif c == '"':
                    state = 'str'
                elif c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth < 0:
                        brace.append((p, line, 'extra }'))
                        depth = 0
            i += 1
        if depth != 0:
            brace.append((p, 'EOF', 'depth=' + str(depth)))
        for m in re.finditer(
            r'^(class|object|interface|data class|sealed class|enum class|annotation class|value class)\s+(\w+)',
            s, re.M):
            decl[(m.group(1) + ' ' + m.group(2))].append(p)

print('=== BRACE ISSUES ===')
for x in brace:
    print(x)
print('=== DUPLICATE TOP-LEVEL TYPES ===')
for k, v in decl.items():
    if len(v) > 1:
        print(k, '->', v)
tot = sum(1 for dp, dn, fn in os.walk(root) for f in fn if f.endswith('.kt'))
print('=== total kt scanned ===', tot)
