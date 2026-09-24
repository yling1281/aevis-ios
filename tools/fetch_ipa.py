#!/usr/bin/env python3
"""把最新的 Aevis IPA 拉到本机。

存在的理由：本机 **github.com 连不上，但 api.github.com 通**，
所以常规的 releases/download 地址会失败。GitHub 的资产下载端点其实挂在
api 域名上（/releases/assets/{id} + Accept: application/octet-stream），
走它就能绕开。

用法:
    python3 tools/fetch_ipa.py [输出路径] [--wait-quota]
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = "yling1281/aevis-ios"
UA = {"User-Agent": "aevis-fetch"}
DEFAULT_OUT = r"E:\苹果ai小手机\dist\Aevis-unsigned.ipa"


def get_json(url):
    try:
        req = urllib.request.Request(url, headers=UA)
        return json.load(urllib.request.urlopen(req, timeout=25)), None
    except urllib.error.HTTPError as exc:
        return None, exc.code
    except Exception as exc:  # noqa: BLE001
        return None, type(exc).__name__


def wait_for_quota():
    """/rate_limit 不消耗配额，用它算出重置时刻并睡过去。"""
    data, _ = get_json("https://api.github.com/rate_limit")
    if not data:
        return
    core = data["resources"]["core"]
    wait = max(0, core["reset"] - int(time.time())) + 15
    print("配额剩余 %d/%d，需等 %d 秒" % (core["remaining"], core["limit"], wait), flush=True)
    if wait > 0:
        time.sleep(wait)


def newest_run():
    runs, err = get_json("https://api.github.com/repos/%s/actions/runs?per_page=1" % REPO)
    if not runs:
        print("拿不到运行列表:", err, flush=True)
        return None
    run = runs["workflow_runs"][0]
    return {
        "id": run["id"],
        "number": run.get("run_number"),
        "head": run["head_sha"][:7],
        "status": run["status"],
        "conclusion": run["conclusion"],
    }


def wait_for_run(run):
    for i in range(40):
        state, err = get_json("https://api.github.com/repos/%s/actions/runs/%s" % (REPO, run["id"]))
        if not state:
            print("[%d] 查询失败(%s)，等 120 秒" % (i, err), flush=True)
            time.sleep(120)
            continue
        run["status"] = state["status"]
        run["conclusion"] = state["conclusion"]
        print("[%d] %s %s" % (i, run["status"], run["conclusion"]), flush=True)
        if run["status"] == "completed":
            break
        time.sleep(75)
    return run


def report_steps(run_id):
    jobs, _ = get_json("https://api.github.com/repos/%s/actions/runs/%s/jobs" % (REPO, run_id))
    for job in (jobs or {}).get("jobs", []):
        bad = [s for s in job.get("steps", []) if s["conclusion"] not in ("success", "skipped")]
        line = "JOB %s -> %s" % (job["name"], job["conclusion"])
        if bad:
            line += "   失败步骤: " + ", ".join("%s(%s)" % (s["name"], s["conclusion"]) for s in bad)
        print(line, flush=True)


def newest_release_tag():
    """挑 build-N 里 N 最大的那个。列表顺序不可信，必须自己算。"""
    rels, err = get_json("https://api.github.com/repos/%s/releases?per_page=30" % REPO)
    if not rels:
        print("拿不到 release 列表:", err, flush=True)
        return None
    best = None
    for rel in rels:
        tag = rel.get("tag_name", "")
        if not tag.startswith("build-"):
            continue
        try:
            number = int(tag.split("-", 1)[1])
        except ValueError:
            continue
        if best is None or number > best[1]:
            best = (tag, number)
    return best[0] if best else None


def download(tag, out_path):
    rel, err = get_json("https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
    if not rel:
        print("拿不到 release %s: %s" % (tag, err), flush=True)
        if str(tag).startswith("build-"):
            check = str(tag).replace("build-", "check-")
            print("提示：这次推送走的是「只自检」流程，没有 IPA。", flush=True)
            print("     想看截图：python tools/fetch_shots.py %s" % check, flush=True)
            print("     真要出包：把 .release/ipa 改成 1 再推一次。", flush=True)
        return False

    asset = next((a for a in rel["assets"] if a["name"] == "Aevis-unsigned.ipa"), None)
    if not asset:
        print("%s 里没有 Aevis-unsigned.ipa，只有 %s" % (tag, [a["name"] for a in rel["assets"]]), flush=True)
        return False

    # 关键：走 api 域名，绕开本机连不上的 github.com
    url = "https://api.github.com/repos/%s/releases/assets/%s" % (REPO, asset["id"])
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    try:
        req = urllib.request.Request(url, headers=dict(UA, Accept="application/octet-stream"))
        with urllib.request.urlopen(req, timeout=300) as resp, open(out_path, "wb") as handle:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                handle.write(chunk)
    except Exception as exc:  # noqa: BLE001
        print("下载失败: %s %s" % (type(exc).__name__, exc), flush=True)
        return False

    size = os.path.getsize(out_path)
    print("下载成功: %s  %d bytes (%.1f MB)" % (out_path, size, size / 1024 / 1024), flush=True)
    fetch_pngs(rel, out_path)
    return True


def fetch_pngs(rel, out_path):
    """把 Release 里的截图拉下来 —— 提交给用户之前先自己看一眼。"""
    pngs = [a for a in rel["assets"] if a["name"].lower().endswith(".png")]
    if not pngs:
        print("这个 release 里没有截图（模拟器自检可能失败了，去看 sim-build.log）", flush=True)
        return

    shot_dir = os.path.join(os.path.dirname(os.path.abspath(out_path)), "shots")
    os.makedirs(shot_dir, exist_ok=True)

    for asset in pngs:
        target = os.path.join(shot_dir, asset["name"])
        url = "https://api.github.com/repos/%s/releases/assets/%s" % (REPO, asset["id"])
        try:
            req = urllib.request.Request(url, headers=dict(UA, Accept="application/octet-stream"))
            with urllib.request.urlopen(req, timeout=180) as resp, open(target, "wb") as handle:
                handle.write(resp.read())
            print("  截图 %-24s %d bytes" % (asset["name"], os.path.getsize(target)), flush=True)
        except Exception as exc:  # noqa: BLE001
            print("  截图 %s 失败: %s" % (asset["name"], exc), flush=True)
    print("截图目录: %s" % shot_dir, flush=True)


def main():
    out_path = DEFAULT_OUT
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if args:
        out_path = args[0]

    if "--wait-quota" in sys.argv:
        wait_for_quota()

    run = newest_run()
    tag = None

    if run:
        print("最新运行 build-%s  head=%s" % (run["number"], run["head"]), flush=True)
        if run["status"] != "completed":
            run = wait_for_run(run)
        report_steps(run["id"])

        if run["conclusion"] == "success":
            tag = "build-%s" % run["number"]
        else:
            print("最新一次没成功，回退到已发布的最高版本", flush=True)

    if not tag:
        tag = newest_release_tag()

    if not tag:
        print("找不到任何可下载的版本", flush=True)
        raise SystemExit(1)

    print("目标版本: %s" % tag, flush=True)
    if not download(tag, out_path):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
