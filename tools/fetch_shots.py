#!/usr/bin/env python3
"""把模拟器自检截图拉到本机。

为什么用 curl 而不是 urllib：
本机到 api.github.com 的连接会**中途被掐断**（1.7 MB 只下到 376 KB，
或者直接 read timeout）。curl 带 --retry / --retry-all-errors 能扛过去，
而且下载完还能按 Release 里记录的字节数核对，避免拿到半截文件。

用法:
    python3 tools/fetch_shots.py                # 最新一个版本
    python3 tools/fetch_shots.py check-21       # 指定版本
    python3 tools/fetch_shots.py --wait-quota   # 先等接口配额重置
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = "yling1281/aevis-ios"
UA = {"User-Agent": "aevis-shots"}
OUT_DIR = r"E:\苹果ai小手机\dist\shots"


def get_json(url):
    req = urllib.request.Request(url, headers=UA)
    return json.load(urllib.request.urlopen(req, timeout=30))


def wait_for_quota():
    """GET /rate_limit 不消耗配额，用它算出重置时刻。"""
    try:
        data = get_json("https://api.github.com/rate_limit")
    except Exception:
        return
    core = data["resources"]["core"]
    wait = max(0, core["reset"] - int(time.time())) + 15
    print("接口配额剩余 %d/%d，等 %d 秒" % (core["remaining"], core["limit"], wait), flush=True)
    if wait > 0:
        time.sleep(wait)


def newest_tag():
    """列表顺序不可信，自己按编号取最大。CI 平时发自检包（check-N），
    要出 IPA 时才发 build-N，两种都认。"""
    rels = get_json("https://api.github.com/repos/%s/releases?per_page=30" % REPO)
    best = None
    for rel in rels:
        tag = rel.get("tag_name", "")
        number = None
        for prefix in ("build-", "check-"):
            if tag.startswith(prefix):
                try:
                    number = int(tag.split("-", 1)[1])
                except ValueError:
                    number = None
                break
        if number is None:
            continue
        if best is None or number > best[1]:
            best = (tag, number)
    return best[0] if best else None


def download_asset(asset_id, name, expected_size):
    target = os.path.join(OUT_DIR, name)
    url = "https://api.github.com/repos/%s/releases/assets/%s" % (REPO, asset_id)
    cmd = [
        "curl", "-sL",
        "--retry", "6", "--retry-all-errors", "--retry-delay", "2",
        "--max-time", "300",
        "-H", "Accept: application/octet-stream",
        "-H", "User-Agent: aevis-shots",
        "-o", target,
        url,
    ]
    try:
        subprocess.run(cmd, check=True, timeout=360)
    except Exception as exc:  # noqa: BLE001
        print("  %-22s 下载失败: %s" % (name, exc), flush=True)
        return False

    actual = os.path.getsize(target) if os.path.exists(target) else 0
    if expected_size and actual != expected_size:
        print("  %-22s 不完整: %d / %d" % (name, actual, expected_size), flush=True)
        return False
    print("  %-22s %7.2f MB  OK" % (name, actual / 1024 / 1024), flush=True)
    return True


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--wait-quota" in sys.argv:
        wait_for_quota()

    tag = args[0] if args else newest_tag()
    if not tag:
        print("找不到任何可下载的版本")
        raise SystemExit(1)

    rel = get_json("https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
    pngs = [a for a in rel["assets"] if a["name"].lower().endswith(".png")]
    print("版本 %s，截图 %d 张" % (tag, len(pngs)), flush=True)

    if not pngs:
        print("没有截图。去看这个 release 里的 sim-build.log，模拟器那一步可能失败了。")
        raise SystemExit(1)

    os.makedirs(OUT_DIR, exist_ok=True)
    ok = 0
    for asset in pngs:
        if download_asset(asset["id"], asset["name"], asset.get("size", 0)):
            ok += 1

    print("完成 %d/%d  ->  %s" % (ok, len(pngs), OUT_DIR), flush=True)
    if ok != len(pngs):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
