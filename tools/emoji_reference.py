"""表情包的对拍检查。

为什么值得单独写一个：内置映射表是我一条条手写的一百多行，
里面只要有一个重复的名字、一个多余的空格、一个写坏的表情，
表现就是「某些表情死活不生效」——而且很难看出来是表错了。

这个脚本把 EmojiPack.swift 里的表**解析出来**，然后：
  1. 查表本身的问题（重复、名字太长、名字里带方括号、表情为空）
  2. 用和 Swift 一样的规则模拟一遍「渲染」和「整条是不是一个表情」
  3. 确认提示词里点名提到的几个表情，表里真的有

跑法：
    python tools/emoji_reference.py
"""

import io
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SOURCE = os.path.join(ROOT, "Aevis", "Core", "EmojiPack.swift")

# 名字长度上限，要和 EmojiPack.nameLimit 一致
NAME_LIMIT = 8

# 提示词里点名提到的（说了却查不到，她就会发一个没人认的方括号）
MENTIONED = ["微笑", "呲牙", "偷笑", "大哭"]

passed = 0
failed = []


def check(label, condition, detail=""):
    global passed
    if condition:
        passed += 1
    else:
        failed.append("%s%s" % (label, ("  → " + detail) if detail else ""))


def load_table():
    """从 Swift 源码里抠出 (名字, 表情) 对。"""
    text = io.open(SOURCE, encoding="utf-8").read()
    # 只取 builtin 那一段，别把别的字符串当表情
    start = text.find("private static let builtin")
    end = text.find("// MARK: - 状态", start)
    block = text[start:end]
    return re.findall(r'\("([^"]*)",\s*"([^"]*)"\)', block)


def render(text, table):
    """和 EmojiPack.render 同样的规则：认得的换掉，不认得的原样留着。"""
    def swap(match):
        name = match.group(1)
        return table[name] if name in table else match.group(0)

    return re.sub(r"\[([^\[\]]{1,12})\]", swap, text)


def single_emoji(text):
    """和 EmojiPack.single 的第二条规则一致：整条是不是一串表情符号。"""
    stripped = text.strip()
    if not stripped:
        return None
    # 近似判断：只看「有没有字母或数字」以及「是不是 emoji」这两件事
    if any(ch.isalpha() or ch.isdigit() for ch in stripped):
        return None
    if len(stripped) > 8:
        return None
    return stripped


def main():
    if not os.path.exists(SOURCE):
        print("找不到 %s" % SOURCE)
        return 1

    pairs = load_table()
    table = {}

    check("表能解析出来", len(pairs) > 100, "只解析到 %d 条" % len(pairs))

    # ——— 表本身的毛病 ———

    for name, emoji in pairs:
        check("名字不为空", name.strip() != "", repr(name))
        check("名字没被首尾空格污染", name == name.strip(), repr(name))
        check("名字长度不超过 %d" % NAME_LIMIT, len(name) <= NAME_LIMIT,
              "%s 有 %d 个字" % (name, len(name)))
        check("名字里没有方括号", "[" not in name and "]" not in name, name)
        check("名字里没有引号", '"' not in name and "\\" not in name, name)
        check("表情不为空", emoji.strip() != "", name)

        if name in table:
            check("名字不重复", False, "%s 出现了两次" % name)
        table[name] = emoji

    # ——— 提示词点到的必须在表里 ———

    for name in MENTIONED:
        check("提示词提到的「%s」查得到" % name, name in table)

    # ——— 渲染规则 ———

    check("单独一个表情：认出", render("[微笑]", table) == table["微笑"])
    check("句子里的表情：认出",
          render("[微笑]你好[呲牙]", table) == table["微笑"] + "你好" + table["呲牙"])
    check("连着两个表情：都认出",
          render("[偷笑][大哭]", table) == table["偷笑"] + table["大哭"])
    check("不认识的名字：原样留着",
          render("[这不是表情]", table) == "[这不是表情]")
    check("普通方括号内容：不动",
          render("看这个[1]和[2]", table) == "看这个[1]和[2]")
    check("没方括号：一个字都不改",
          render("今天天气不错", table) == "今天天气不错")
    check("中英混排：表情认出来、英文不动",
          render("OK[强]", table) == "OK" + table["强"])

    # 边界：只有半边方括号
    check("只有左括号：不动", render("[微笑", table) == "[微笑")
    check("只有右括号：不动", render("微笑]", table) == "微笑]")
    check("空方括号：不动", render("[]", table) == "[]")

    # ——— 「整条是不是一个表情」 ———

    check("纯中文：不算表情", single_emoji("好的") is None)
    check("带数字：不算表情", single_emoji("1234") is None)
    check("带英文：不算表情", single_emoji("OK") is None)
    check("空字符串：不算表情", single_emoji("   ") is None)
    check("纯表情符号：算表情", single_emoji("😊") == "😊")

    # ——— 汇总 ———

    print("内置表情 %d 条" % len(table))
    print("通过 %d 项" % passed)

    if failed:
        print("\n没通过 %d 项：" % len(failed))
        for item in failed[:20]:
            print("  " + item)
        return 1

    print("全部通过")
    # 顺手给一个直观的样子
    sample = ["微笑", "呲牙", "偷笑", "大哭", "捂脸", "强", "玫瑰"]
    print("\n样例：" + "  ".join("%s%s" % (n, table[n]) for n in sample if n in table))
    return 0


if __name__ == "__main__":
    sys.exit(main())
