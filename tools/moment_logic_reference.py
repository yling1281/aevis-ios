#!/usr/bin/env python3
"""朋友圈「评论 / 回复条数」计数逻辑的参照实现 + 对拍测试。

为什么单独测这块：
「她最多回几条」这种计数**差一个数**就会走向两个极端 ——
要么她永远不回（off-by-one 提前拦住），要么没完没了地自言自语。
这类错误不会崩、不会报错，只会让人觉得"这功能坏了吧"，最难查。

所以把纯逻辑抽出来验一遍，再照搬到 Swift。

用到的代码：
    python3 tools/moment_logic_reference.py
"""

import random

PASS = []
FAIL = []


def check(name, got, want):
    if got == want:
        PASS.append(name)
    else:
        FAIL.append("%s  得到 %r，期望 %r" % (name, got, want))


def check_truth(name, condition, detail=""):
    if condition:
        PASS.append(name)
    else:
        FAIL.append("%s  %s" % (name, detail))


# ——— 与 Swift 同结构的纯逻辑 ———
# 评论用 (作者, 内容) 表示，作者是 "me" 或 "ta"

def comment_count(comments, author):
    return sum(1 for c in comments if c[0] == author)


def ta_after_my_last(comments):
    """我上一次留言之后，她回了几条。"""
    last_mine = None
    for index, comment in enumerate(comments):
        if comment[0] == "me":
            last_mine = index
    if last_mine is None:
        return comment_count(comments, "ta")
    return comment_count(comments[last_mine + 1:], "ta")


MARKERS = "-*•·「\"'#"


def clean_line(raw):
    """清掉一行前面的列表符号、编号、左引号，以及末尾的右引号。

    两个坑（都是对拍时发现的）：
    1. 不能先 trim 再替换 "- " —— "- " trim 完只剩 "-"，匹配不上，
       会留下一个光秃秃的横杠当评论
    2. 编号要连着点号一起删，不能见数字就删 ——
       否则「300 块有点贵」会被啃成「00 块有点贵」
    """
    text = raw.strip()

    for _ in range(8):
        before = text
        text = text.strip()
        if text and text[0] in MARKERS:
            text = text[1:]
            continue
        digits = ""
        for ch in text:
            if ch.isdigit():
                digits += ch
            else:
                break
        if digits and len(text) > len(digits) and text[len(digits)] in ".、)":
            text = text[len(digits) + 1:]
            continue
        if text == before:
            break

    text = text.strip()
    while text and text[-1] in "」\"'":
        text = text[:-1]
    return text.strip()


def clean_lines(raw, limit):
    out = []
    for line in raw.split("\n"):
        text = clean_line(line)
        if text and len(text) <= 40:
            out.append(text)
    return out[:limit]


def auto_react_allowance(comments, max_comments):
    """我发完动态后，她还能评几条。"""
    return max_comments - comment_count(comments, "ta")


def reply_allowance(comments, max_replies):
    """我留言之后，她还能回几条。"""
    return max(1, max_replies) - ta_after_my_last(comments)


def should_send_dm(chance, roll):
    """该不该私信。chance <= 0 一律不发；roll 是 0~1 的随机数。"""
    if chance <= 0:
        return False
    return roll < min(chance, 1.0)


def main():
    # ——— 1) 我上一次留言之后她回了几条 ———
    check("空评论 → 0", ta_after_my_last([]), 0)
    check("只有她说的 → 全都算", ta_after_my_last([("ta", "a")]), 1)
    check("她说了两条 → 2", ta_after_my_last([("ta", "a"), ("ta", "b")]), 2)
    check("我先说她后说 → 1", ta_after_my_last([("me", "x"), ("ta", "a")]), 1)
    check("她说我先她说 → 只算后面那条", ta_after_my_last([("ta", "a"), ("me", "x"), ("ta", "b")]), 1)
    # 关键用例：我又留了一条言 → 计数清零，她可以再回
    check("她说→我说→她说→我又说 → 清零，可以再回",
          ta_after_my_last([("ta", "a"), ("me", "x"), ("ta", "b"), ("me", "y")]), 0)
    check("她连着回两条后再我说话 → 清零",
          ta_after_my_last([("ta", "a"), ("ta", "b"), ("me", "x")]), 0)

    # ——— 2) 评论总数 ———
    check("只数她的", comment_count([("me", "x"), ("ta", "a"), ("ta", "b")], "ta"), 2)
    check("只数我的", comment_count([("me", "x"), ("ta", "a"), ("me", "y")], "me"), 2)

    # ——— 3) 我发完动态：她还能评几条 ———
    check("上限 1，她还没评 → 能评 1 条", auto_react_allowance([], 1), 1)
    check("上限 1，她已经评了 → 不再评", auto_react_allowance([("ta", "a")], 1), 0)
    check("上限 3，已评 1 → 还能 2", auto_react_allowance([("ta", "a")], 3), 2)
    check("上限 3，已评 3 → 0", auto_react_allowance([("ta", "a"), ("ta", "b"), ("ta", "c")], 3), 0)
    check("我的评论不占她的名额", auto_react_allowance([("me", "x"), ("me", "y")], 1), 1)

    # ——— 4) 我留言后她还能回几条 ———
    check("上限 1，我留了言 → 能回 1", reply_allowance([("me", "x")], 1), 1)
    check("上限 1，她已回 → 不再回", reply_allowance([("me", "x"), ("ta", "a")], 1), 0)
    check("上限 2，已回 1 → 还能 1", reply_allowance([("me", "x"), ("ta", "a")], 2), 1)
    check("上限 2，已回 2 → 0", reply_allowance([("me", "x"), ("ta", "a"), ("ta", "b")], 2), 0)
    check("我又留一条言 → 重新能回", reply_allowance([("me", "x"), ("ta", "a"), ("me", "y")], 1), 1)
    # 边界：上限被填成 0 或负数时，至少允许回一条，不能变成"永远不回"
    check("上限 0 仍至少能回 1", reply_allowance([("me", "x")], 0), 1)
    check("上限 -5 仍至少能回 1", reply_allowance([("me", "x")], -5), 1)

    # ——— 5) 模型输出的清理 ———
    check("去掉破折号",
          clean_lines("- 记得吃早饭", 3), ["记得吃早饭"])
    check("去掉编号",
          clean_lines("1. 早点睡\n2、别熬夜", 3), ["早点睡", "别熬夜"])
    check("去掉引号和书名号",
          clean_lines("「今天真冷」", 3), ["今天真冷"])
    check("空行丢掉",
          clean_lines("第一句\n\n\n第二句", 5), ["第一句", "第二句"])
    check("超长的行丢掉（多半是解释）",
          clean_lines("正常一句\n" + "啊" * 60, 5), ["正常一句"])
    check("按上限截断",
          clean_lines("一\n二\n三\n四", 2), ["一", "二"])
    check("上限 1 只留第一条",
          clean_lines("一\n二\n三", 1), ["一"])
    check("全空 → 空列表", clean_lines("\n\n  \n", 3), [])
    check("只有破折号 → 空列表", clean_lines("- \n* ", 3), [])
    check("单独一个星号也丢掉", clean_lines("*\n·", 3), [])
    # 关键反例：开头是数字但**不是编号**，不能被啃掉
    check("「300块有点贵」不被吃掉数字",
          clean_lines("300块有点贵", 3), ["300块有点贵"])
    check("「2个人吃饭」不被误判成编号",
          clean_lines("2个人吃饭", 3), ["2个人吃饭"])
    check("「1. 早点睡」是编号，要删",
          clean_lines("1. 早点睡", 3), ["早点睡"])
    check("「2、别熬夜」是编号，要删",
          clean_lines("2、别熬夜", 3), ["别熬夜"])
    check("「3) 记得吃药」是编号，要删",
          clean_lines("3) 记得吃药", 3), ["记得吃药"])
    check("「- 记得吃饭」前后都有符号也能清",
          clean_lines("  -  「记得吃饭」  ", 3), ["记得吃饭"])

    # ——— 6) 私信概率 ———
    check("概率 0 → 永不发", should_send_dm(0, 0.0), False)
    check("概率 0 → 即使 roll 极小也不发", should_send_dm(0, 0.0001), False)
    check("概率负数 → 不发", should_send_dm(-0.5, 0.0), False)
    check("概率 40%，roll 0 → 发", should_send_dm(0.4, 0.0), True)
    check("概率 40%，roll 0.39 → 发", should_send_dm(0.4, 0.39), True)
    check("概率 40%，roll 0.4 → 不发（边界）", should_send_dm(0.4, 0.4), False)
    check("概率 40%，roll 0.99 → 不发", should_send_dm(0.4, 0.99), False)
    check("概率 100%，roll 0.999 → 发", should_send_dm(1.0, 0.999), True)
    check("概率被填成 1.5 → 夹住，仍然发", should_send_dm(1.5, 0.999), True)

    # 统计校验：写反了（用 > 而不是 <）会被这一条抓出来
    random.seed(20260924)
    hits = sum(1 for _ in range(20000) if should_send_dm(0.4, random.random()))
    rate = hits / 20000.0
    check_truth("概率 40% 跑两万次的命中率在 38%~42%",
                0.38 <= rate <= 0.42, "实际 %.3f" % rate)

    print("通过 %d 项" % len(PASS))
    for name in PASS:
        print("  ok  %s" % name)
    if FAIL:
        print("\n失败 %d 项：" % len(FAIL))
        for item in FAIL:
            print("  !!  %s" % item)
        return 1
    print("\n全部通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
