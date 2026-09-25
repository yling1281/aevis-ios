#!/usr/bin/env python3
"""把本地 aevis-ios 源码一次性推到 GitHub（原子提交，走 api.github.com）。

为什么不用 git：
- 本机没有这个仓库的 .git，也没有凭据；
- 而且 **本机连不上 github.com**（网页和 git over https 都不通），
  只有 **api.github.com** 通。所以走 GitHub 的 Git Data API。

这个脚本一次请求就把所有改动做成**一个提交**（而不是一条条文件），
所以 CI 只会被触发一次 —— 符合「全部做完才推一次、编一次」。

令牌从哪来（不要写进代码、不要提交）：
  1. 环境变量 GITHUB_TOKEN，或
  2. 文件 E:\\苹果ai小手机\\.secrets\\github_token.txt（在仓库目录之外，永远不会被提交）

用法：
    python tools/push_all.py --dry-run      # 只看要推哪些文件，不联网
    python tools/push_all.py                # 真推
    python tools/push_all.py --message "..."  # 自定义提交信息
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

REPO = "yling1281/aevis-ios"
BRANCH = "main"
API = "https://api.github.com"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                     # aevis-ios/
TOKEN_FILE = os.path.join(os.path.dirname(ROOT), ".secrets", "github_token.txt")

# 不推的东西：构建产物、缓存、系统垃圾、探针临时文件
#
# `.done` / `.probe-bak` 是本地验证脚本留下的 —— 沙箱里删不掉文件、只能改名，
# 所以它们会散在目录里。**一旦被当成源码推上去就是脏提交**，这里挡掉。
SKIP_DIRS = {".git", "build", "build-sim", "DerivedData", "__pycache__"}
SKIP_EXT = {".pyc", ".ipa", ".zip", ".log", ".done", ".probe-bak"}


def should_skip(rel):
    """生成出来的 App 图标不进仓库 ——
    它们由 CI 里的 `scripts/make_icon.py` 现生成（workflow 里有这一步）。
    把 1.4 MB 的 PNG 提进仓库只会让每次提交都变重，而且改了脚本还得记得重传。
    """
    if ".appiconset/" in rel and rel.endswith(".png"):
        return True
    return False


def token():
    value = os.environ.get("GITHUB_TOKEN", "").strip()
    if value:
        return value
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            value = handle.read().strip()
        if value:
            return value
    return ""


def collect_files():
    """仓库里所有该推的文件，路径用 / 分隔（GitHub 要的格式）。"""
    out = {}
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if os.path.splitext(name)[1] in SKIP_EXT:
                continue
            full = os.path.join(base, name)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            if should_skip(rel):
                continue
            out[rel] = full
    return out


def git_blob_sha(content):
    """算出 git 给这份内容算的 blob id —— 这样不用 git 也能精确比对差异。

    算法就一行：sha1("blob <字节数>\\0" + 内容)。
    自己算而不是"觉得文件改过"，才不会漏推或多推。
    """
    import hashlib
    header = "blob %d\0" % len(content)
    return hashlib.sha1(header.encode("ascii") + content).hexdigest()


def remote_tree(token_value=""):
    """远端当前的文件 → blob sha 映射。公开仓库不登录也能读。"""
    data, err = call(
        "GET",
        "/repos/%s/git/trees/%s?recursive=1" % (REPO, BRANCH),
        token_value=token_value,
    )
    if err:
        return None, err
    out = {}
    for item in data.get("tree", []):
        if item.get("type") == "blob":
            out[item["path"]] = item["sha"]
    return out, None


def diff_against_remote(token_value=""):
    """本地和远端比，分出「新增」「改动」「删除」。"""
    files = collect_files()
    remote, err = remote_tree(token_value)
    if err:
        return None, err

    added, changed, same = [], [], []
    for path, full in files.items():
        with open(full, "rb") as handle:
            sha = git_blob_sha(handle.read())
        if path not in remote:
            added.append((path, full))
        elif remote[path] != sha:
            changed.append((path, full))
        else:
            same.append(path)

    removed = [p for p in remote if p not in files]
    return {
        "added": sorted(added),
        "changed": sorted(changed),
        "same": len(same),
        "removed": sorted(removed),
    }, None


def call(method, path, body=None, token_value=""):
    url = API + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "aevis-push")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if token_value:
        request.add_header("Authorization", "Bearer " + token_value)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=120) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return json.loads(raw) if raw.strip() else {}, None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:400]
        return None, "HTTP %s %s" % (error.code, detail)
    except Exception as error:  # noqa: BLE001
        return None, "%s %s" % (type(error).__name__, error)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="只列文件，不联网")
    parser.add_argument("--diff", action="store_true", help="和远端比差异（只读，不推）")
    parser.add_argument("--message", default="", help="提交信息")
    args = parser.parse_args()

    # ——— 只看差异：只读，不需要令牌 ———
    if args.diff:
        result, err = diff_against_remote(token())
        if err:
            print("比对失败：", err)
            return 1

        added = result["added"]
        changed = result["changed"]
        payload = sum(os.path.getsize(p) for _, p in added + changed)
        for tag, rows in (("新增", added), ("改动", changed)):
            if rows:
                print("【%s】%d 个" % (tag, len(rows)))
                for path, full in rows:
                    print("  %-56s %7d B" % (path, os.path.getsize(full)))
        print()
        print("没变 %d 个；远端有、本地没有 %d 个" % (result["same"], len(result["removed"])))
        if result["removed"]:
            for path in result["removed"]:
                print("  仅远端: %s" % path)
        print("\n需要推 %d 个文件，合计 %.0f KB" % (len(added) + len(changed), payload / 1024))
        return 0

    files = collect_files()
    total = sum(os.path.getsize(p) for p in files.values())
    print("本地 %d 个文件，合计 %.0f KB" % (len(files), total / 1024))

    if args.dry_run:
        for path in sorted(files):
            print("  %-56s %7d B" % (path, os.path.getsize(files[path])))
        print("\n（--dry-run，没有联网）")
        return 0

    token_value = token()
    if not token_value:
        print("\n没有找到令牌。两种给法，任选一种：")
        print("  1. 设环境变量 GITHUB_TOKEN")
        print("  2. 把令牌写进 %s" % TOKEN_FILE)
        print("\n令牌只需要勾 repo 权限（细粒度令牌给 Contents: Read and write 就够）。")
        return 2

    # 1) 当前 main 指向哪
    ref, err = call("GET", "/repos/%s/git/ref/heads/%s" % (REPO, BRANCH), token_value=token_value)
    if err:
        print("拿不到分支指针：", err)
        return 1
    base_commit_sha = ref["object"]["sha"]

    commit, err = call("GET", "/repos/%s/git/commits/%s" % (REPO, base_commit_sha), token_value=token_value)
    if err:
        print("拿不到当前提交：", err)
        return 1
    base_tree_sha = commit["tree"]["sha"]
    print("当前 main: %s" % base_commit_sha[:12])

    # 2) 只上传真正变了的文件（拿着远端树一个个比 blob id，不靠猜）
    result, err = diff_against_remote(token_value)
    if err:
        print("比对远端失败：", err)
        return 1

    targets = result["added"] + result["changed"]
    if not targets:
        print("本地和远端一模一样，没什么可推的。")
        return 0

    print("需要推 %d 个文件（新增 %d / 改动 %d），没变的 %d 个跳过"
          % (len(targets), len(result["added"]), len(result["changed"]), result["same"]))

    entries = []
    for index, (path, full) in enumerate(targets, 1):
        with open(full, "rb") as handle:
            content = handle.read()
        blob, err = call(
            "POST",
            "/repos/%s/git/blobs" % REPO,
            {
                "content": base64.b64encode(content).decode("ascii"),
                "encoding": "base64",
            },
            token_value,
        )
        if err:
            print("上传 %s 失败：%s" % (path, err))
            return 1
        entries.append({
            "path": path,
            "mode": "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        if index % 10 == 0 or index == len(targets):
            print("  已上传 %d/%d" % (index, len(targets)))

    # 3) 建一棵新树（带上原树，未改动的文件自动保留）
    tree, err = call(
        "POST",
        "/repos/%s/git/trees" % REPO,
        {"base_tree": base_tree_sha, "tree": entries},
        token_value,
    )
    if err:
        print("建树失败：", err)
        return 1

    # 4) 一个提交把全部改动装进去 —— CI 只会跑一次
    message = args.message or "feat(m1): 一口气补齐剩余功能（气泡/记忆/角色卡/朋友圈/陪伴/系统桥）"
    new_commit, err = call(
        "POST",
        "/repos/%s/git/commits" % REPO,
        {"message": message, "tree": tree["sha"], "parents": [base_commit_sha]},
        token_value,
    )
    if err:
        print("建提交失败：", err)
        return 1

    # 5) 移动 main 指针（快进，不 force）
    ref_body = {"sha": new_commit["sha"], "force": False}
    _, err = call("PATCH", "/repos/%s/git/refs/heads/%s" % (REPO, BRANCH), ref_body, token_value)
    if err:
        print("移动分支失败：", err)
        return 1

    print("\n推上去了。")
    print("  提交：%s" % new_commit["sha"])
    print("  看看 CI 有没有跑起来：")
    print("  https://api.github.com/repos/%s/actions/runs?per_page=1" % REPO)
    return 0


if __name__ == "__main__":
    sys.exit(main())
