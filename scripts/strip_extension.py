"""按标记把「系统录屏扩展」从 project.yml 里摘掉。

## 为什么留这个口子

「系统录屏扩展」是一个**嵌进主 App 的独立 target**，它比主 App 多一套签名
要求。而我们的 IPA 是在手机上用第三方工具重签的 —— 如果那个工具处理不了
嵌套的 .appex，**整个 App 会装不上**（iOS 的行为：嵌套 bundle 签名不合格
就不允许安装，不是"扩展不可用"而是"整个装不了"）。

真遇到那种情况，要能**一条推送就退回去**，而不是再改代码、再排查一轮。
所以：在仓库根放一个 `.release/no-extension` 文件 → CI 生成一份**不含扩展**
的工程 → 装得上了，问题就锁定在扩展的签名上。

## 用法

    python3 scripts/strip_extension.py          # 有标记就摘，没有就原样

标记按行匹配，成对出现，所以摘除后 YAML 仍然是合法的
（不会留下空的 dependencies 键或者悬空的列表项）。
"""

import io
import os
import sys

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(PROJECT, "project.yml")
MARKER = os.path.join(PROJECT, ".release", "no-extension")

# 每对是「起始标记 → 结束标记」，连同标记行一起删掉。
BLOCKS = [
    ("# >>> extension:start", "# <<< extension:end"),
    ("# >>> extension-dep:start", "# <<< extension-dep:end"),
    ("# >>> extension-scheme:start", "# <<< extension-scheme:end"),
]


def strip(text):
    """按标记删块。返回（新内容, 删掉的块数）。"""
    lines = text.splitlines()
    out = []
    removed = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        opener = None
        for start, end in BLOCKS:
            if line.strip() == start:
                opener = (start, end)
                break
        if opener is None:
            out.append(line)
            index += 1
            continue

        # 找配对的结束标记
        scan = index + 1
        while scan < len(lines) and lines[scan].strip() != opener[1]:
            scan += 1
        if scan >= len(lines):
            # 标记不配对 —— 宁可原样保留，也不要生成一份半截的工程
            print("  ⚠️ 标记 %s 没找到配对的结束标记，跳过" % opener[0])
            out.append(line)
            index += 1
            continue

        removed += 1
        index = scan + 1

    return "\n".join(out) + "\n", removed


def main():
    if not os.path.isfile(MARKER):
        print("没有 .release/no-extension 标记 —— 保留录屏扩展。")
        return 0

    print("发现 .release/no-extension —— 这次生成**不含录屏扩展**的工程。")

    with io.open(SPEC, encoding="utf-8") as handle:
        text = handle.read()

    stripped, removed = strip(text)
    if removed == 0:
        print("  ⚠️ 一个块都没摘到，检查 project.yml 里的标记还在不在")
        return 1

    # 安全网：摘完之后这几个词不该再出现 —— 剩一个都会让 xcodegen 报错
    for word in ("AevisBroadcast", "extension:start"):
        if word in stripped:
            print("  ✗ 摘除后还残留 %s —— 标记范围不对，放弃摘除" % word)
            return 1

    with io.open(SPEC, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(stripped)

    print("  摘掉 %d 个块；project.yml 现在 %d 字节" % (removed, len(stripped.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
