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
    # 🔴 2026-11-25 事故：原来这里写死 `build-<run>`，那是旧工程 build-ipa.yml 的
    # release 名。rewrite 流水线发的是 `ipa-rw-<run>`，资产名也不同
    # （Aevis-rewrite-unsigned.ipa vs Aevis-unsigned.ipa）。
    # 结果 run#49 成功后脚本报了「发布 build-49」——那个其实是 2026-09-25 的旧包，
    # 提交 f2a0ee77，6.4 MB；真包 2.16 MB。照脚本提示去下 build-49 的 IPA
    # 就会把两个月前的旧 App 当 2.7 发出去（真的发生了）。
    # 修法：① 按 workflow 名选 tag 前缀；② 必须核对 release body 里的提交 sha；
    #       ③ 明确打印「该下哪个资产」，不再让人从资产列表里猜。
    wf_name = (state.get("name") or "").lower()
    is_rewrite = "rewrite" in wf_name
    if is_rewrite:
        candidates = ["ipa-rw-%s" % run_number]
    else:
        candidates = ["build-%s" % run_number, "check-%s" % run_number]

    release, error = None, None
    for tag in candidates:
        release, error = get("https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
        if release:
            break
    if not release:
        print("找不到发布（%s）：%s" % (", ".join(candidates), error), flush=True)
        return 1

    head = state.get("head_sha") or ""
    body = release.get("body") or ""
    if head[:8] and head[:8] not in body:
        print("!! 发布 %s 的提交与本 run 不一致（本 run %s，发布说明未含该 sha）——"
              "不要下载，先查 release。" % (release["tag_name"], head[:8]), flush=True)
        return 1

    print("\n发布 %s" % release["tag_name"], flush=True)
    print("提交 %s  /  workflow %s" % (head[:8], state.get("name")), flush=True)
    for asset in release["assets"]:
        print("   %-26s %9d B" % (asset["name"], asset["size"]), flush=True)
    prefer = ("Aevis-rewrite-unsigned.ipa" if is_rewrite else "Aevis-unsigned.ipa")
    hit = next((a for a in release["assets"] if a["name"] == prefer), None)
    print("应下载资产：%s%s" % (prefer, "" if hit else "  ⚠ 不存在！"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
