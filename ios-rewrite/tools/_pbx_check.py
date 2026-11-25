#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 project.pbxproj 里每个文件引用都能在磁盘上找到（资源路径解析真值）。

为什么需要：`PBXFileReference` 的 `path` 是**相对所在 group 的 path** 解析的。
把 `Core/AevisHosts.swift` 塞进 `path = Views` 的 group 里，Xcode 会去找
`AevisApp/Views/AevisHosts.swift` —— pbxproj 语法完全合法，但构建报
`Build input file cannot be found`。这类错误本地没有 Xcode 只能靠静态推导发现。

用法：python3 tools/_pbx_check.py [工程根，默认脚本上一级]
退出码 0 = 全部命中；1 = 有悬空引用。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(HERE)
PBX = os.path.join(ROOT, "AevisApp.xcodeproj", "project.pbxproj")

GROUP_RE = re.compile(r"(\w{24})\s*/\*[^*]*\*/\s*=\s*\{\s*isa = PBXGroup;(.*?)\n\t\t\};", re.S)
FILEREF_RE = re.compile(
    r"(\w{24})\s*/\*[^*]*\*/\s*=\s*\{isa = PBXFileReference;(.*?)\};", re.S)


def parse():
    with io.open(PBX, "r", encoding="utf-8") as f:
        src = f.read()
    groups = {}
    for m in GROUP_RE.finditer(src):
        gid, body = m.group(1), m.group(2)
        children = re.findall(r"(\w{24})", body.split("children = (")[1].split(")")[0]) \
            if "children = (" in body else []
        pm = re.search(r"\n\t\t\tpath = ([^;]+);", body)
        groups[gid] = (pm.group(1).strip().strip('"') if pm else None, children)
    refs = {}
    for m in FILEREF_RE.finditer(src):
        rid, body = m.group(1), m.group(2)
        # 只校验 sourceTree = "<group>" 的：构建产物（BUILT_PRODUCTS_DIR）本来就不在磁盘上，
        # 绝对路径（SDKROOT 等）也不需要按 group 拼路径。
        if 'sourceTree = "<group>"' not in body:
            continue
        pm = re.search(r"path = ([^;]+);", body)
        if not pm:
            continue
        refs[rid] = pm.group(1).strip().strip('"')
    return groups, refs


def main():
    groups, refs = parse()
    parent = {}
    for gid, (_p, children) in groups.items():
        for c in children:
            parent[c] = gid

    # 根 group 是唯一没有 parent 的
    missing, ok = [], 0
    for rid, path in sorted(refs.items()):
        parts = [path]
        cur = parent.get(rid)
        while cur is not None:
            gp = groups[cur][0]
            if gp:
                parts.append(gp)
            cur = parent.get(cur)
        full = os.path.join(ROOT, *reversed(parts))
        if os.path.exists(full):
            ok += 1
        else:
            missing.append((path, os.path.relpath(full, ROOT)))

    print("文件引用 %d 个：命中 %d / 悬空 %d" % (len(refs), ok, len(missing)))
    for path, full in missing:
        print("  [MISS] %-40s 解析成 %s" % (path, full))
    print("PBX_CHECK: " + ("PASS" if not missing else "FAIL"))
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
