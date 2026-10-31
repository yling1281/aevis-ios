# -*- coding: utf-8 -*-
"""从 GitHub Release 资产分块下载 IPA（国内网络下整包下会超时）。

用法：
    python fetch_ipa_chunked.py <asset_id> <输出路径> [--chunk MB]

为什么不用 tools/fetch_ipa.py：那个脚本拉的是 release **列表**，
而 `api.github.com` 的列表接口在当前网络下经常 `IncompleteRead`；
资产本体走 `release-assets.githubusercontent.com` 是稳的，
所以这里直接拿 asset id → 解析重定向 → Range 分块。
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

REPO = "yling1281/aevis-ios"
UA = {"User-Agent": "aevis-fetch"}


def real_url(asset_id):
    h = dict(UA)
    h["Accept"] = "application/octet-stream"
    r = urllib.request.urlopen(urllib.request.Request(
        "https://api.github.com/repos/%s/releases/assets/%d" % (REPO, asset_id),
        headers=h), timeout=40)
    return r.geturl()


def asset_size(asset_id):
    r = urllib.request.urlopen(urllib.request.Request(
        "https://api.github.com/repos/%s/releases/assets/%d" % (REPO, asset_id),
        headers=UA), timeout=40)
    return json.load(r)["size"]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    asset_id = int(sys.argv[1])
    out = sys.argv[2]
    chunk_mb = 4
    if "--chunk" in sys.argv:
        chunk_mb = int(sys.argv[sys.argv.index("--chunk") + 1])

    total = asset_size(asset_id)
    url = real_url(asset_id)
    print("资产 %d  大小 %.2f MB" % (asset_id, total / 1048576))
    print("下载源: %s" % url.split('/')[2])

    chunk = chunk_mb * 1024 * 1024
    pos = 0
    part = 0
    tmp = out + ".part"
    with open(tmp, "wb") as f:
        while pos < total:
            end = min(pos + chunk, total) - 1
            ok = False
            for attempt in range(4):
                p = subprocess.run(
                    ["curl", "-sL", "-m", "180", "--retry", "2", "--retry-delay", "2",
                     "-H", "Range: bytes=%d-%d" % (pos, end), url, "-o", tmp + ".blk"],
                    capture_output=True)
                sz = os.path.getsize(tmp + ".blk") if os.path.exists(tmp + ".blk") else 0
                want = end - pos + 1
                if p.returncode == 0 and sz == want:
                    ok = True
                    break
                print("   重试 %d（拿到 %d / 需要 %d）" % (attempt + 1, sz, want))
                time.sleep(3)
            if not ok:
                print("块 %d 失败，停止" % part)
                return 2
            with open(tmp + ".blk", "rb") as bf:
                data = bf.read()
            f.write(data)
            pos += len(data)
            part += 1
            print("  块 %d 完成  %.1f%% (%.2f/%.2f MB)"
                  % (part, pos * 100.0 / total, pos / 1048576, total / 1048576))

    if os.path.exists(tmp + ".blk"):
        os.remove(tmp + ".blk")
    got = os.path.getsize(tmp)
    print("下载完成: %d 字节" % got)
    if got != total:
        print("⚠️ 大小不符（应为 %d）" % total)
        return 3
    if os.path.exists(out):
        os.remove(out)
    os.rename(tmp, out)
    print("已保存: %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
