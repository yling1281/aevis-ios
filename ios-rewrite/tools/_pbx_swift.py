# -*- coding: utf-8 -*-
"""project.pbxproj 里按文件名增删 PBXBuildFile / PBXFileReference / 组 / Sources 四处登记。

用法：
    python _pbx_swift.py add BrandMarks.swift 2B WeatherText.swift 2C Motion.swift 2D
    python _pbx_swift.py del WeatherText.swift Motion.swift

为什么要这个脚本：手改 pbxproj 四处容易漏一处，漏了就是"文件在磁盘上但没进 target"，
Xcode 报 undefined symbol 而不是找不到文件，很难查。脚本化后 add/del 可重放。
"""
import io
import sys

PATH = "AevisApp.xcodeproj/project.pbxproj"

BF = "\t\tA100000000000000000000%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = B100000000000000000000%s /* %s */; };\n"
FR = "\t\tB100000000000000000000%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };\n"
GRP = "\t\t\t\tB100000000000000000000%s /* %s */,\n"
SRC = "\t\t\t\tA100000000000000000000%s /* %s in Sources */,\n"

ANCHOR_BF = "\t\tA1000000000000000000002D /* Motion.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000000000000000000002D /* Motion.swift */; };\n"


def load():
    return io.open(PATH, encoding="utf-8").read()


def save(s):
    io.open(PATH, "w", encoding="utf-8", newline="\n").write(s)


def add(src, name, suffix):
    if ("/* %s */" % name) in src:
        print("  skip（已存在）:", name)
        return src
    src = src.replace(BF % (suffix, name, suffix, name), "")
    # 插在 BuildFile 段落末尾锚点之后（锚点可能已被删，退化到任意一条 A1...2A 之后）
    anchor = "\t\tA1000000000000000000002A /* PersonaCreateView.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000000000000000000002A /* PersonaCreateView.swift */; };\n"
    if anchor not in src:
        raise SystemExit("找不到 PBXBuildFile 锚点")
    src = src.replace(anchor, anchor + BF % (suffix, name, suffix, name), 1)

    anchor = "\t\tB1000000000000000000002A /* PersonaCreateView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PersonaCreateView.swift; sourceTree = \"<group>\"; };\n"
    if anchor not in src:
        raise SystemExit("找不到 PBXFileReference 锚点")
    src = src.replace(anchor, anchor + FR % (suffix, name, name), 1)

    anchor = "\t\t\t\tB1000000000000000000002A /* PersonaCreateView.swift */,\n"
    if anchor not in src:
        raise SystemExit("找不到 Views 组锚点")
    src = src.replace(anchor, anchor + GRP % (suffix, name), 1)

    anchor = "\t\t\t\tA1000000000000000000002A /* PersonaCreateView.swift in Sources */,\n"
    if anchor not in src:
        raise SystemExit("找不到 Sources 锚点")
    src = src.replace(anchor, anchor + SRC % (suffix, name), 1)
    print("  added:", name)
    return src


def delete(src, name):
    if ("/* %s */" % name) not in src:
        print("  skip（不存在）:", name)
        return src
    out = []
    for line in src.split("\n"):
        if ("/* %s */" % name) in line or ("/* %s in Sources */" % name) in line:
            continue
        out.append(line)
    print("  deleted:", name)
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    mode = args[0]
    src = load()
    if mode == "add":
        rest = args[1:]
        for i in range(0, len(rest), 2):
            src = add(src, rest[i], rest[i + 1])
    elif mode == "del":
        for name in args[1:]:
            src = delete(src, name)
    else:
        raise SystemExit("mode 只能是 add / del")
    save(src)
    print("done")


if __name__ == "__main__":
    main()
