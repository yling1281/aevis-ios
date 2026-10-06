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
    # ⚠️ 通话**二**探针那三块（2026-10-01 下午补）。
    #
    # 二探针**故意**嵌了一个假扩展，用来测「嵌了 .appex 是不是就丢通话资格」。
    # 而 `.release/no-extension` 这个开关正好可以做那个实验的对照组：
    # 打开它 → 生成一份**不嵌扩展**的二探针 → 摘了还弹不出来，
    # 就说明跟包的结构无关、确实是描述文件本身没资格。
    #
    # 所以这几块**必须**也登记在这里 —— 不登记的话，
    # `.release/no-extension` 打开也只能摘掉主 App 那个录屏扩展，
    # 二探针依然带着假扩展，那个对照实验就做不成。
    ("# >>> probe2-ext:start", "# <<< probe2-ext:end"),
    ("# >>> probe2-ext-dep:start", "# <<< probe2-ext-dep:end"),
    ("# >>> probe2-ext-scheme:start", "# <<< probe2-ext-scheme:end"),
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

    # 安全网：摘完之后不该再有**任何一个 target 定义或引用**残留 ——
    # 剩一个都会让 xcodegen 报错（`target 不存在` / `dependencies` 悬空）。
    #
    # ⚠️⚠️ **只看 YAML 键，不看注释**（2026-10-01 踩过）。
    #    这几个名字在注释里出现是**正常且必要**的：
    #      · `AevisBroadcast` 在讲"契约只此一份"的那段说明里
    #      · `AevisCallProbe2Ext` 在解释这颗探针为什么要嵌扩展的那段里
    #    早先这里是"整份文本里搜关键词"，于是摘干净了也会误报，
    #    而误报的后果是**这条应急路在最需要它的时候用不了**。
    #
    #    判据收紧成：这一行去掉注释之后还含这个名字 ⇒ 才算残留。
    leftovers = ["AevisBroadcast", "AevisCallProbe2Ext"]
    bad = []
    for lineno, line in enumerate(stripped.split("\n"), 1):
        code = line.split("#", 1)[0]          # 去掉行尾注释再判断
        for word in leftovers:
            if word in code:
                bad.append("%d: %s" % (lineno, line.strip()))
    if bad:
        print("  ✗ 摘除后还有 %d 处**真引用**（不是注释）残留 —— 放弃摘除：" % len(bad))
        for item in bad[:8]:
            print("      ", item)
        return 1

    # 标记本身也确认摘掉了（这两个词只可能出现在标记行里）
    for word in ("extension:start", "probe2-ext:start"):
        if word in stripped:
            print("  ✗ 摘除后还残留标记 %s —— 标记范围不对，放弃摘除" % word)
            return 1

    with io.open(SPEC, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(stripped)

    print("  摘掉 %d 个块；project.yml 现在 %d 字节" % (removed, len(stripped.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
