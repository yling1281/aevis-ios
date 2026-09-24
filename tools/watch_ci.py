#!/usr/bin/env python3
"""盯 CI 运行：等它结束，把失败的步骤和编译错误抓回来。

为什么要单独一个脚本：
- 未登录接口限 60 次/小时，所以间隔要放宽、还要容忍 403；
- 编译失败时错误在 `build.log` 里（CI 会把它发到 `log-<n>` 这个发布上），
  直接抓那一段比在几十页日志里翻快得多。

用法：
    python tools/watch_ci.py            # 盯最新一次运行
    python tools/watch_ci.py --run 123  # 盯指定 run id
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = "yling1281/aevis-ios"
HEADERS = {"User-Agent": "aevis-watch"}


def get(url, raw=False):
    request = urllib.request.Request(url, headers=HEADERS)
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            body = response.read()
            if raw:
                return body, None
            return json.loads(body.decode("utf-8", "replace")), None
    except urllib.error.HTTPError as error:
        return None, error.code
    except Exception as error:  # noqa: BLE001
        return None, type(error).__name__


def quota():
    data, _ = get("https://api.github.com/rate_limit")
    if not data:
        return None
    core = data["resources"]["core"]
    return core["remaining"], core["reset"]


def grab_log(tag, name="build.log"):
    """从一个发布的资产里把日志取回来。"""
    release, error = get("https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
    if not release:
        return None, "拿不到 %s：%s" % (tag, error)
    asset = next((a for a in release.get("assets", []) if a["name"] == name), None)
    if not asset:
        return None, "%s 里没有 %s" % (tag, name)
    url = "https://api.github.com/repos/%s/releases/assets/%s" % (REPO, asset["id"])
    body, error = get(url, raw=True)
    if body is None:
        return None, "下载 %s 失败：%s" % (name, error)
    return body.decode("utf-8", "replace"), None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=int, default=0)
    parser.add_argument("--interval", type=int, default=70)
    parser.add_argument("--timeout", type=int, default=3000)
    args = parser.parse_args()

    run_id = args.run
    run_number = 0
    if not run_id:
        runs, error = get("https://api.github.com/repos/%s/actions/runs?per_page=1" % REPO)
        if not runs:
            print("拿不到运行列表：", error, flush=True)
            return 1
        latest = runs["workflow_runs"][0]
        run_id = latest["id"]
        run_number = latest.get("run_number", 0)
        print("盯 run %s（第 %s 次，head=%s）"
              % (run_id, run_number, latest["head_sha"][:7]), flush=True)

    started = time.time()
    state = None
    while time.time() - started < args.timeout:
        data, error = get("https://api.github.com/repos/%s/actions/runs/%s" % (REPO, run_id))
        if not data:
            left, reset = quota() or (None, None)
            print("  查询失败(%s)，剩余配额=%s，等 %ds 再试" % (error, left, args.interval), flush=True)
            time.sleep(args.interval)
            continue

        state = data
        run_number = state.get("run_number", run_number)
        print("[%4ds] %s / %s" % (int(time.time() - started), state["status"], state["conclusion"]),
              flush=True)
        if state["status"] == "completed":
            break
        time.sleep(args.interval)

    if not state or state["status"] != "completed":
        print("等太久了，还没跑完。下次直接跑：python tools/watch_ci.py --run %s" % run_id, flush=True)
        return 1

    # ——— 步骤结果 ———
    jobs, _ = get("https://api.github.com/repos/%s/actions/runs/%s/jobs" % (REPO, run_id))
    failed = []
    for job in (jobs or {}).get("jobs", []):
        print("\nJOB %s -> %s" % (job["name"], job["conclusion"]), flush=True)
        for step in job.get("steps", []):
            mark = step["conclusion"]
            if mark not in ("success", "skipped"):
                failed.append(step["name"])
                print("   !! %-34s %s" % (step["name"], mark), flush=True)
            else:
                print("      %-34s %s" % (step["name"], mark), flush=True)

    conclusion = state.get("conclusion")
    print("\n总结果：%s" % conclusion, flush=True)

    # ——— 失败就把编译错误打出来 ———
    if conclusion != "success":
        log, error = grab_log("log-%s" % run_number)
        if log is None:
            print("抓日志失败：", error, flush=True)
            return 1
        lines = log.splitlines()
        hits = [i for i, line in enumerate(lines) if "error:" in line.lower()]
        print("build.log 共 %d 行，含 error 的 %d 行" % (len(lines), len(hits)), flush=True)
        printed = 0
        for index in hits:
            if printed >= 240:
                break
            for offset in range(max(0, index - 1), min(len(lines), index + 3)):
                print(lines[offset])
                printed += 1
            print("-" * 60)
        if not hits:
            print("\n".join(lines[-160:]))
        return 1

    # ——— 成功：把这次的发布信息打出来 ———
    tag = "build-%s" % run_number
    release, error = get("https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
    if not release:
        print("找不到 build 发布（可能是自检包）：", error, flush=True)
        release, error = get("https://api.github.com/repos/%s/releases/tags/check-%s" % (REPO, run_number))
    if release:
        print("\n发布 %s" % release["tag_name"], flush=True)
        for asset in release["assets"]:
            print("   %-26s %9d B" % (asset["name"], asset["size"]), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
