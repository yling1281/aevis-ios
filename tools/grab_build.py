#!/usr/bin/env python3
"""把最新一次构建的 IPA 取回本地。

为什么要单独写一个：
- 本机连不上 github.com 的下载页，只有 api 域名通，
  所以下载必须走 `/releases/assets/{id}` + `Accept: application/octet-stream`；
- 未登录接口限 60 次/小时，所以轮询间隔要放宽、失败要容忍；
- 大文件会被截断，所以**下完必须按字节数和发布里记录的大小对一遍**，
  再打开 zip 确认里面真的是 `Payload/Aevis.app`。

用法：
    python tools/grab_build.py            # 等最新的 build-N 出来后取回来
    python tools/grab_build.py --tag build-23
    python tools/grab_build.py --wait 600 # 最多等 600 秒
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

REPO = "yling1281/aevis-ios"
API = "https://api.github.com"
OUT = r"E:\苹果ai小手机\dist\Aevis-unsigned.ipa"
HEADERS = {"User-Agent": "aevis-grab"}


def get_json(url):
    request = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8", "replace")), None
    except urllib.error.HTTPError as error:
        return None, error.code
    except Exception as error:  # noqa: BLE001
        return None, type(error).__name__


def latest_build_release():
    """列表顺序不可信，自己按 build-N 里的 N 比大小。"""
    releases, error = get_json("%s/repos/%s/releases?per_page=20" % (API, REPO))
    if not releases:
        return None, error
    best = None
    for release in releases:
        tag = release.get("tag_name", "")
        if not tag.startswith("build-"):
            continue
        try:
            number = int(tag.split("-", 1)[1])
        except ValueError:
            continue
        if best is None or number > best[0]:
            best = (number, release)
    return (best[1] if best else None), None


def download(url, target):
    """用 curl 下 —— 实测 Python 的 urllib 在本机下大文件会被中途掐死。"""
    os.makedirs(os.path.dirname(target), exist_ok=True)
    command = [
        "curl", "-sL",
        "--retry", "5", "--retry-all-errors", "--retry-delay", "2",
        "--max-time", "600",
        "-H", "Accept: application/octet-stream",
        "-H", "User-Agent: aevis-grab",
        "-o", target,
        url,
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    return os.path.exists(target), result.returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", default="")
    parser.add_argument("--wait", type=int, default=720, help="最多等多少秒")
    args = parser.parse_args()

    started = time.time()
    release = None

    while time.time() - started < args.wait:
        if args.tag:
            release, error = get_json("%s/repos/%s/releases/tags/%s" % (API, REPO, args.tag))
        else:
            release, error = latest_build_release()

        if release:
            asset = next(
                (a for a in release.get("assets", []) if a["name"] == "Aevis-unsigned.ipa"),
                None,
            )
            if asset:
                break
            print("[%3ds] 发布 %s 已出现，但还没有 IPA，继续等"
                  % (int(time.time() - started), release["tag_name"]), flush=True)
        else:
            print("[%3ds] 还没有 build 发布（%s），等 25 秒再看" % (int(time.time() - started), error),
                  flush=True)
        time.sleep(25)
    else:
        print("等超时了。稍后再跑一次就行。")
        return 1

    tag = release["tag_name"]
    asset = next(a for a in release["assets"] if a["name"] == "Aevis-unsigned.ipa")
    print("\n发布 %s（%s）" % (tag, release.get("published_at", "")))
    for item in release["assets"]:
        print("   %-26s %9d B" % (item["name"], item["size"]))

    url = "%s/repos/%s/releases/assets/%s" % (API, REPO, asset["id"])
    print("\n开始下载 IPA …", flush=True)
    ok, code = download(url, OUT)
    if not ok:
        print("下载失败，curl 退出码 %s" % code)
        return 1

    size = os.path.getsize(OUT)
    print("下载完成：%s" % OUT)
    print("  本地 %d 字节 / 发布里记录 %d 字节" % (size, asset["size"]))
    if size != asset["size"]:
        print("  !! 字节数对不上，多半是被截断了，重跑一次本脚本")
        return 1
    print("  字节数一致 ✔")

    # 抽查包内容，别只看大小
    import zipfile
    with zipfile.ZipFile(OUT) as archive:
        names = archive.namelist()
        plist = [n for n in names if n.endswith("Info.plist")]
        executable = [n for n in names if n.endswith("/Aevis")]
        print("  包内 %d 个条目；有 Info.plist：%s；有可执行文件：%s"
              % (len(names), bool(plist), bool(executable)))
        unsigned = not any("_CodeSignature" in n for n in names)
        print("  未签名（全能签要的就是这种）：%s" % unsigned)
        if plist:
            import plistlib
            info = plistlib.loads(archive.read(plist[0]))
            print("  提交：%s" % str(info.get("AevisCommit"))[:12])
            print("  版本：%s build %s"
                  % (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
