#!/usr/bin/env python3
"""把 CI 的 Secrets 就地写进 BuiltInSecrets.swift。

## 为什么需要这一步

仓库是**公开**的，AppKey / SecretKey 不能躺在源码里 ——
但那两个值又不得不内嵌（朋友拿到包不用自己去申请开发者应用）。

解法：仓库里那份 `BuiltInSecrets.swift` 的**值永远是空的**，
CI 在编译前用加密存储的 Secrets 把它填上 —— 真值只活在**构建产物**里，
不进仓库、不出现在任何一次提交中。

## 用法

CI 里靠环境变量传（workflow 里接 `${{ secrets.XXX }}`）：

    AEVIS_BAIDU_APP_KEY=xxx AEVIS_BAIDU_SECRET_KEY=yyy python3 scripts/inject_secrets.py

**环境变量为空就什么都不做**（保持空值），所以没配 Secrets 时也能正常编译，
只是产出的包里没有内置凭据 —— 用户去「设置 → 百度网盘」自己填一次就行。

## 两条纪律

1. **绝不打印真值**，只打印长度 —— CI 日志在公开仓库里是能看到的。
2. 注入是**就地改文件**，所以这一步必须发生在任何 `git commit` **之后**
   （否则改动会被提交回仓库，等于白做还泄露了）。
"""

import io
import os
import re
import sys

TARGET = os.path.join("Aevis", "Core", "BuiltInSecrets.swift")

# 字段名 -> 从哪个环境变量取值
FIELDS = [
    ("baiduPanAppKey", "AEVIS_BAIDU_APP_KEY"),
    ("baiduPanSecretKey", "AEVIS_BAIDU_SECRET_KEY"),
]


def escape(value):
    """Swift 字符串字面量里只需要处理反斜杠和引号。"""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def main():
    if not os.path.isfile(TARGET):
        print("找不到 " + TARGET)
        return 1

    with io.open(TARGET, encoding="utf-8") as handle:
        text = handle.read()

    filled = []
    for name, env in FIELDS:
        value = os.environ.get(env, "").strip()
        if not value:
            print("  %-20s %s 是空的，保持空值不动" % (name, env))
            continue

        pattern = re.compile(r'(static let %s = ")([^"]*)(")' % re.escape(name))
        if not pattern.search(text):
            print("  %-20s 在文件里没找到这一行，跳过" % name)
            continue

        text = pattern.sub(lambda m: m.group(1) + escape(value) + m.group(3), text, count=1)
        # 只报长度，**不报真值**
        filled.append("%s(%d 位)" % (name, len(value)))

    if not filled:
        print("没有要注入的值，什么都不做。")
        return 0

    with io.open(TARGET, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)

    print("已注入：" + "、".join(filled))
    print("（真值只进构建产物，仓库里那份仍然是空的）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
