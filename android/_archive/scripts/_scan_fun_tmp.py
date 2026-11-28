import os
import re
import collections

root = 'app/src/main/java'
# top-level functions (no leading whitespace), capture name + full signature line(s)
sig = collections.defaultdict(list)
for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith('.kt'):
            continue
        p = os.path.join(dp, f)
        s = open(p, encoding='utf-8', errors='replace').read()
        for m in re.finditer(r'^(?:private |internal |public )?(?:inline )?fun\s+(\w+)\s*\(([^)]*)\)', s, re.M):
            name = m.group(1)
            params = re.sub(r'\s+', '', m.group(2))
            sig[(name, params)].append(p)

print('=== DUPLICATE top-level fun (same name+params) ===')
found = False
for k, v in sig.items():
    if len(v) > 1:
        found = True
        print(k, '->', v)
if not found:
    print('(none)')

# also detect same-name different-params top-level funcs (possible but note)
byname = collections.defaultdict(set)
for (name, params), v in sig.items():
    byname[name].add(params)
print('=== same-name overloads ===')
for k, v in byname.items():
    if len(v) > 1:
        print(k, '->', len(v), 'variants')
