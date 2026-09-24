#!/usr/bin/env python3
"""找出「写在字符串里、但不会生效」的 markdown 加粗。

背景：SwiftUI 的 `Text("字面量")` 会解析 markdown（`**粗体**`），
但 `Text(某个变量)` **不会** —— 星号会原样显示出来。

真踩过：截图里出现「但**快捷指令可以**」，一眼就知道哪儿写错了。
这个脚本把「字符串里有 `**`，但它是先存进变量再显示的」挑出来。

用法:
    python3 tools/find_markdown.py
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Aevis")


def string_literals(line):
    """取出这一行里的字符串字面量（跳过转义）。"""
    out = []
    index = 0
    length = len(line)
    while index < length:
        char = line[index]
        if char == '"' and not (index > 0 and line[index - 1] == "\\"):
            scan = index + 1
            while scan < length:
                if line[scan] == "\\":
                    scan += 2
                    continue
                if line[scan] == '"':
                    break
                scan += 1
            if scan < length:
                out.append((index, line[index + 1:scan]))
                index = scan + 1
                continue
        index += 1
    return out


def main():
    problems = []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ("Resources", ".git")]
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()

            in_multiline = False
            block_start = 0
            block = []

            for number, line in enumerate(lines, 1):
                stripped = line.strip()

                # ——— 多行字符串 `"""…"""` ———
                # 之前只查单行，漏掉了这种 —— 而「锁屏那段说明」恰恰是多行的，
                # 结果截图里就出现了「但**快捷指令可以**」。
                if stripped.count('"""') == 1:
                    if not in_multiline:
                        in_multiline = True
                        block_start = number
                        block = [stripped]
                    else:
                        block.append(stripped)
                        in_multiline = False
                        text = "\n".join(block)
                        if "**" in text:
                            problems.append((path, block_start, text.splitlines()[0][:64]))
                    continue
                if in_multiline:
                    block.append(stripped)
                    continue

                if stripped.startswith("//"):
                    continue

                for start, literal in string_literals(line):
                    if "**" not in literal:
                        continue
                    before = line[:start].rstrip()
                    inline = bool(re.search(r"\bText\(\s*$", before))
                    if not inline:
                        problems.append((path, number, literal))

    rel = lambda p: os.path.relpath(p, os.path.dirname(ROOT)).replace(os.sep, "/")
    if not problems:
        print("没有发现「写了但不会渲染」的加粗。")
        return 0

    print("这些字符串里有 ** 加粗，但可能因为「先存进变量」而原样显示星号：\n")
    for path, number, literal in problems:
        print("  %-52s :%-4d  %s" % (rel(path), number, literal[:64]))
    print("\n共 %d 处。" % len(problems))
    print("界面上的要去掉星号、或显示处包一层 LocalizedStringKey；")
    print("喂给模型的工具描述无所谓（markdown 在提示词里不影响）。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
