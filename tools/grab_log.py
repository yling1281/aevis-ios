#!/usr/bin/env python3
"""把 CI 发上来的 build.log 抓回来（大文件会被截断，所以分块 + 按字节数核对）。

用法:
    python tools/grab_log.py 53            # 抓 log-53 里的 build.log
    python tools/grab_log.py 53 --errors   # 只印含 error: 的行（前后各带一点上下文）

**为什么要单独一个脚本**：`/releases/assets/{id}` 对未鉴权请求经常只回前
一千多字节，直接 `urlopen().read()` 拿到的是一段残片 —— 而且它不报错，
看着像"日志就是这么短"。这里按 Range 分块拉，并且每块都比对长度。
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = "yling1281/aevis-ios"
# ⚠️ `Accept: application/octet-stream` 只能加在**下资产**那一步 ——
# 把它带到列发布的接口上，GitHub 会直接回 415（踩过）。
JSON_HEADERS = {"User-Agent": "aevis-log"}
BLOB_HEADERS = {"User-Agent": "aevis-log", "Accept": "application/octet-stream"}
CHUNK = 40000


def get(url, headers=None, raw=False, tries=4):
    last = None
    for attempt in range(tries):
        request = urllib.request.Request(url, headers=headers or JSON_HEADERS)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
            if raw:
                return body, None
            return json.loads(body.decode("utf-8", "replace")), None
        except urllib.error.HTTPError as error:
            # 416 = Range 超出文件尾，正常结束
            return None, error.code
        except Exception as error:  # noqa: BLE001
            last = type(error).__name__
            time.sleep(1.5 * (attempt + 1))
    return None, last


def fetch_asset(asset_id, size):
    """分块拉，拿满 `size` 个字节才算成功。

    ⚠️ 两个真实踩过的坑：
    - 不分块的话，`/releases/assets/{id}` 经常只回前一千多字节，**而且不报错**；
    - 如果服务器压根忽略 Range、每块都回同一段开头，就会拼出一份"看起来够长、
      其实全是重复内容"的日志 —— 所以下面的长度单调性检查不能省。
    """
    pieces = []
    got = 0
    guard = 0
    while got < size and guard < 300:
        guard += 1
        end = min(got + CHUNK, size) - 1
        want = end - got + 1
        headers = dict(BLOB_HEADERS)
        headers["Range"] = "bytes=%d-%d" % (got, end)
        body, error = get("https://api.github.com/repos/%s/releases/assets/%s" % (REPO, asset_id),
                          headers=headers, raw=True)
        if body is None:
            return None, "第 %d 字节起这一段拿不到（%s）" % (got, error)
        if not body:
            return None, "第 %d 字节起拿到 0 字节" % got
        if len(body) > want:
            # 服务器忽略了 Range，直接把整个文件给了我们 —— 那就是全部了
            pieces = [body]
            got = len(body)
            break
        pieces.append(body)
        got += len(body)
        if (len(pieces) >= 2 and len(pieces[-1]) == len(pieces[-2])
                and len(body) < want and got < size):
            return None, ("服务器疑似忽略 Range（连着两块都是 %d 字节），"
                          "这次只能拿到残片，换个时间再试" % len(body))
    data = b"".join(pieces)
    if len(data) < size:
        return None, "只拿到 %d / %d 字节" % (len(data), size)
    return data[:size], None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("build", type=int, help="构建号，比如 53（对应发布 log-53）")
    parser.add_argument("--errors", action="store_true", help="只印含 error: 的片段")
    parser.add_argument("--tail", type=int, default=160, help="没找到 error 时印最后多少行")
    args = parser.parse_args()

    tag = "log-%d" % args.build
    release, error = get("https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag), raw=False)
    if not release:
        print("拿不到 %s：%s" % (tag, error))
        return 1

    asset = next((a for a in release.get("assets", []) if a["name"] == "build.log"), None)
    if not asset:
        print("%s 里没有 build.log，有的资产是：%s"
              % (tag, [a["name"] for a in release.get("assets", [])]))
        return 1

    out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "_ci_log%d.log" % args.build)
    data, error = fetch_asset(asset["id"], asset["size"])
    if data is None:
        print("下载失败：%s" % error)
        return 1
    with open(out, "wb") as handle:
        handle.write(data)
    print("已存到 %s（%d 字节，和服务器报的 %d 对上了）" % (out, len(data), asset["size"]))

    if not args.errors:
        return 0

    lines = data.decode("utf-8", "replace").splitlines()
    hits = [i for i, line in enumerate(lines) if "error:" in line.lower()]
    if not hits:
        print("\n没找到 error: —— 印最后 %d 行：\n" % args.tail)
        print("\n".join(lines[-args.tail:]))
        return 0

    print("\n共 %d 行，含 error 的 %d 行：\n" % (len(lines), len(hits)))
    printed = 0
    for index in hits:
        if printed >= 240:
            break
        for offset in range(max(0, index - 1), min(len(lines), index + 3)):
            print(lines[offset])
            printed += 1
        print("-" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
