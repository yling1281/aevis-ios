#!/usr/bin/env python3
"""把最新的**管理端** IPA 拉到本机。

和 fetch_ipa.py 是同一套路（本机 `github.com` 连不上、`api.github.com` 通，
所以走 `/releases/assets/{id}` + `Accept: application/octet-stream`），
区别只是它认的是 `admin-<N>` 那个 release、取的是 `AevisAdmin-unsigned.ipa`。

用法:
    python3 tools/fetch_admin_ipa.py [输出路径] [tag]

  不带 tag → 自己挑最新的 `admin-<数字>`（**不认** `admin-log-<数字>`，
  那是失败日志的 tag，挑错了会拿到一个不存在的资产）。
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = "yling1281/aevis-ios"
UA = {"User-Agent": "aevis-fetch-admin"}
DEFAULT_OUT = r"E:\苹果ai小手机\dist\AevisAdmin-unsigned.ipa"
ASSET = "AevisAdmin-unsigned.ipa"

TAG_RE = re.compile(r"^admin-(\d+)$")


def get_json(url):
    try:
        req = urllib.request.Request(url, headers=UA)
        return json.load(urllib.request.urlopen(req, timeout=25)), None
    except urllib.error.HTTPError as exc:
        return None, exc.code


def newest_admin_tag():
    """挑最新的 `admin-<N>`。⚠️ `/releases` 的顺序不可信，要比 N。"""
    data, err = get_json("https://api.github.com/repos/%s/releases?per_page=50" % REPO)
    if err:
        raise SystemExit("列 release 失败：HTTP %s" % err)
    best = None
    for rel in data:
        m = TAG_RE.match(rel.get("tag_name") or "")
        if not m:
            continue
        n = int(m.group(1))
        if best is None or n > best[0]:
            best = (n, rel["tag_name"], rel)
    if not best:
        raise SystemExit("一个 admin-<N> 的 release 都没有 —— 管理端还没出过包？")
    return best[1], best[2]


def download(rel, tag, out):
    asset = next((a for a in rel.get("assets", []) if a["name"] == ASSET), None)
    if not asset:
        raise SystemExit("%s 里没有 %s，只有 %s"
                         % (tag, ASSET, [a["name"] for a in rel.get("assets", [])]))
    url = "https://api.github.com/repos/%s/releases/assets/%s" % (REPO, asset["id"])
    expect = asset["size"]
    os.makedirs(os.path.dirname(out), exist_ok=True)

    # 大文件会被截断 —— 重试几次，并且**按字节数核对**（这就是为什么要有这个脚本）
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers=dict(UA, Accept="application/octet-stream"))
            blob = urllib.request.urlopen(req, timeout=300).read()
        except Exception as exc:                       # noqa: BLE001
            print("  第 %d 次失败：%s" % (attempt + 1, exc))
            continue
        if len(blob) == expect:
            with open(out, "wb") as handle:
                handle.write(blob)
            return len(blob)
        print("  第 %d 次拿到 %d 字节（应该是 %d），重试" % (attempt + 1, len(blob), expect))
    raise SystemExit("下载总是不完整，稍后再试")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = args[0] if args else DEFAULT_OUT
    if len(args) > 1:
        tag = args[1]
        rel, err = get_json("https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
        if err:
            raise SystemExit("拿不到 %s：HTTP %s" % (tag, err))
    else:
        tag, rel = newest_admin_tag()

    print("取 %s 里的 %s" % (tag, ASSET))
    size = download(rel, tag, out)
    print("已存到 %s（%d 字节 / %.2f MB）" % (out, size, size / 1024 / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
