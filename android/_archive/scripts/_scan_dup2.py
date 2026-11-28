import os
import re
import collections

root = 'app/src/main/java'
sig = collections.defaultdict(list)
# allow any leading annotations/modifiers on the same line
pat = re.compile(
    r'^((?:@\w+(?:\([^)]*\))?\s+)*(?:private|internal|public|protected|inline|override|suspend|operator|tailsuspend|expect|actual|external|abstract)\s+)*'
    r'fun\s+(\w+)\s*(?:<[^>]*>)?\s*\(([^)]*)\)', re.M)
for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith('.kt'):
            continue
        p = os.path.join(dp, f)
        s = open(p, encoding='utf-8', errors='replace').read()
        for m in pat.finditer(s):
            mods = m.group(1) or ''
            name = m.group(2)
            params = re.sub(r'\s+', '', m.group(3))
            # normalize param names: keep types only roughly
            is_private = 'private' in mods
            sig[(name, params)].append((p, is_private, m.group(0)[:80]))

print('=== possible duplicate top-level fun (name+params) ===')
found = False
for k, v in sig.items():
    if len(v) > 1:
        # only a real conflict if at least one is non-private
        if not all(x[1] for x in v):
            found = True
            print(k)
            for x in v:
                print('   ', x)
if not found:
    print('(none conflicting)')
print('=== total top-level fun decls ===', sum(len(v) for v in sig.values()))
