"""反向验证 R18：把 emoji 的声明挪回 ChatView，看检查器报不报。

规则写完不验证等于没写。这个探针模拟「真踩过的那次写法」，
跑完自动还原，不留痕迹。
"""

import io
import os
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PY = sys.executable
TARGET = os.path.join(ROOT, "Aevis", "Features", "Chat", "ChatView.swift")

DECL = "@ObservedObject private var emoji = EmojiPack.shared"


def read():
    with io.open(TARGET, encoding="utf-8") as handle:
        return handle.readlines()


def write(lines):
    with io.open(TARGET, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("".join(lines))


def run_check():
    out = subprocess.run(
        [PY, "-X", "utf8", "-u", "tools/swift_check.py"],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
    ).stdout
    return [line for line in out.splitlines() if "R18" in line], out


def main():
    original = read()
    lines = list(original)

    # 1) 找到 MessageBubble 并把它里面的声明删掉（连同上面的注释）
    start = next(i for i, l in enumerate(lines) if l.startswith("private struct MessageBubble"))
    removed = 0
    index = start
    while index < len(lines):
        if DECL in lines[index]:
            # 连注释一起删
            back = index
            while back > 0 and lines[back - 1].strip().startswith("///"):
                back -= 1
            removed = index - back + 1
            del lines[back:index + 1]
            break
        index += 1

    # 2) 挪回 ChatView（bridge 那行后面）
    anchor = next(i for i, l in enumerate(lines) if "var bridge = BridgeInbox.shared" in l)
    lines.insert(anchor + 1, "    " + DECL + "\n")

    write(lines)
    print("已把声明挪回 ChatView（删掉 %d 行，加入 1 行）" % removed)

    hits, out = run_check()
    print("R18 报出 %d 条：" % len(hits))
    for line in hits[:6]:
        print("   " + line.strip())

    caught = len(hits) > 0

    # 3) 还原
    write(original)
    restored = read() == original
    print()
    print("能抓到这次的真 bug :", caught)
    print("已还原            :", restored)
    return 0 if (caught and restored) else 1


if __name__ == "__main__":
    sys.exit(main())
