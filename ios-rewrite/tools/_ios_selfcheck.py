#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iOS 改动文件自检（v2）——针对 CI run #45 暴露的四类编译错误。

检查项
  1. `@State/@AppStorage/... var x` **既无类型标注也无初值** → type annotation missing in pattern
     （有初值时 Swift 可推断，合法；只有"光秃秃一个名字"才报错）
  2. `async let` 右值含 Optional.map/.flatMap/.compactMap 或三目/闭包 → 编译器不接受
  3. `async let` 被 `await` 但漏 `try`（右值本身抛错）
  4. 已知 async 函数在调用点漏 `await`
  5. `await` 出现在**非 async 的 func 作用域**里（闭包透明，含 Task/.task/refreshable 的 func 跳过）
  6. 香港线路 / 「直连→北京→备用→香港」残留字样
  7. 花括号 / 圆括号 / 方括号平衡

实现要点：先把注释与字符串抹成空格并**保留换行**，再做字符级状态机，
这样 URL 里的 `//` 不会被误当注释，index → 行号也能精确还原。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _find_target_dir():
    """定位 `ios-rewrite/AevisApp`，不依赖调用方的 cwd。

    脚本现在住在 `ios-rewrite/tools/`（CI 用），CI 的 `working-directory` 是 `ios-rewrite`，
    本地又常从仓库根跑 —— 所以从脚本位置逐级往上找，谁先命中用谁。
    """
    cur = HERE
    for _ in range(6):
        cand = os.path.join(cur, "ios-rewrite", "AevisApp")
        if os.path.isdir(cand):
            return cand
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    # 兜底：脚本所在目录的上一级就是 ios-rewrite
    return os.path.join(os.path.dirname(HERE), "AevisApp")


TARGET_DIR = _find_target_dir()


def _swift_files():
    """全量发现 `.swift`，不再维护手写清单。

    手写清单的问题：新加的文件永远不在里面，扫描器会静默放过它。
    CI 的意义就是「新代码也拦得住」，所以必须自动发现。
    """
    out = []
    if not os.path.isdir(TARGET_DIR):
        return out
    for dirpath, _dirnames, filenames in os.walk(TARGET_DIR):
        for name in sorted(filenames):
            if name.endswith(".swift"):
                rel = os.path.relpath(os.path.join(dirpath, name), TARGET_DIR)
                out.append(rel.replace(os.sep, "/"))
    return sorted(out)


FILES = _swift_files()

issues = []


def add(path, lineno, kind, text):
    issues.append((path, lineno, kind, text.strip()))


def strip_all(src):
    """注释/字符串抹成空格，保留换行与全部偏移。返回同长度字符串。"""
    out = list(src)
    i = 0
    n = len(src)
    in_line_comment = False
    in_block = False
    in_str = False
    while i < n:
        ch = src[i]
        if ch == "\n":
            in_line_comment = False
            i += 1
            continue
        if in_line_comment:
            out[i] = " "
            i += 1
            continue
        if in_block:
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                out[i] = out[i + 1] = " "
                i += 2
                in_block = False
                continue
            if ch != "\n":
                out[i] = " "
            i += 1
            continue
        if in_str:
            if ch == "\\" and i + 1 < n:
                out[i] = " "
                if src[i + 1] != "\n":
                    out[i + 1] = " "
                i += 2
                continue
            if ch == '"':
                i += 1
                in_str = False
                continue
            if ch != "\n":
                out[i] = " "
            i += 1
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            out[i] = out[i + 1] = " "
            i += 2
            in_line_comment = True
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            out[i] = out[i + 1] = " "
            i += 2
            in_block = True
            continue
        if ch == '"':
            in_str = True
            i += 1
            continue
        i += 1
    return "".join(out)


FUNC_DECL = re.compile(
    r"\bfunc\s+(\w+)\s*(?:<[^>{}()]*>)?\s*\([^(){}]*\)\s*([^{}\n]*)\{", re.S)
ASYNC_CALL_HINT = re.compile(r"\basync\b")

# 这些花括号开头的地方，闭包体本身就是 async 上下文
ASYNC_CLOSURE = re.compile(
    r"(?:\bTask\b|\bTask\s*\.\s*detached\b|\.task\b|\.refreshable\b"
    r"|withTaskGroup\b|withThrowingTaskGroup\b"
    r"|withCheckedContinuation\b|withCheckedThrowingContinuation\b"
    r"|withUnsafeContinuation\b|withUnsafeThrowingContinuation\b)"
    r"[^{}\n]*$")


def line_map(src):
    lm = [0] * (len(src) + 1)
    ln = 1
    for idx, ch in enumerate(src):
        lm[idx] = ln
        if ch == "\n":
            ln += 1
    lm[len(src)] = ln
    return lm


def collect_func_sets(clean_by_file):
    """扫声明：async 函数名、throws 函数名。

    用途：
      - async 函数名 → 第 4 项（调用点漏 await）
      - throws 函数名 → 第 3 项（`async let x = throwing()` 的 try 要写在 await 处）

    返回 (per_file, worker_asyncs, all_throwing)：
      per_file[rel] = 该文件内声明的 async 函数名 —— 只有本文件里的裸调用才算；
      worker_asyncs  = APIClient.swift 里声明的 async 函数名 —— 用 `APIClient.xxx(` 精确匹配。
    分开是必须的：`LocalStore.load(...)` / `PlazaCacheStore.load(...)` / `speech.start()`
    都是同步函数，只是**重名**，一概按纯名字匹配会造一堆假报警。
    """
    per_file = {}
    worker_asyncs = set()
    all_throwing = set()
    for rel, clean in clean_by_file.items():
        local = set()
        for m in FUNC_DECL.finditer(clean):
            name, mods = m.group(1), m.group(2) or ""
            if re.search(r"\basync\b", mods):
                local.add(name)
                if rel.endswith("Core/APIClient.swift"):
                    worker_asyncs.add(name)
            if re.search(r"\bthrows\b", mods):
                all_throwing.add(name)
        per_file[rel] = local
    return per_file, worker_asyncs, all_throwing


def check_file(rel, src, local_asyncs, worker_asyncs, throwing_funcs):
    clean = strip_all(src)
    lm = line_map(src)
    raw_lines = src.split("\n")
    code_lines = clean.split("\n")

    # ---------- 1. 光秃秃 var（无类型无初值） ----------
    for idx, code in enumerate(code_lines, start=1):
        if not re.search(r"@(State|StateObject|ObservedObject|EnvironmentObject|FocusState|GestureState|Namespace)\b", code):
            if not re.search(r"@AppStorage\b|@SceneStorage\b", code):
                continue
        m = re.search(r"\bvar\s+(\w+)\s*$", code)
        if m:
            add(rel, idx, "1-STATE-NO-TYPE", raw_lines[idx - 1])
        # 也覆盖 `var x` 后紧跟 `{` 的（计算属性无类型不合法）
        m2 = re.search(r"\bvar\s+(\w+)\s*\{\s*$", code)
        if m2:
            add(rel, idx, "1-STATE-NO-TYPE-WILLSET", raw_lines[idx - 1])

    # ---------- 2/3. async let ----------
    async_lets = {}
    for m in re.finditer(r"\basync\s+let\s+(\w+)\s*(?::\s*[^=]+)?=\s*([^\n]*)", clean):
        name, rhs = m.group(1), m.group(2).strip()
        ln = lm[m.start()]
        async_lets[name] = (ln, rhs)
        if re.search(r"\.(map|flatMap|compactMap)\s*[({]", rhs):
            add(rel, ln, "2-ASYNCLET-MAP", "async let %s = %s" % (name, rhs))
        if re.search(r"\.(map|flatMap|compactMap)\s*\{", rhs):
            add(rel, ln, "2-ASYNCLET-CLOSURE", "async let %s = %s" % (name, rhs))
        if rhs.endswith("{") or re.search(r"\bin\b[^)]*$", rhs):
            add(rel, ln, "2-ASYNCLET-CLOSURE", "async let %s = %s" % (name, rhs))

    for name, (ln, rhs) in async_lets.items():
        # `async let` 的 throw 语义：`try` 写在 **await 处**，不写在初始化式里。
        #   async let a = throwing()        → let v = try await a     ← 必须 try
        #   async let a = try? throwing()   → let v = await a         ← try? 已吞错，不必再 try
        # 所以：右值里出现认识的 throwing 函数、且没有 try?/try! → await 处必须有 try。
        swallowed = ("try?" in rhs) or ("try!" in rhs)
        calls_throwing = any(
            re.search(r"(?<!\w)" + re.escape(fn) + r"\s*\(", rhs)
            for fn in throwing_funcs
        ) if throwing_funcs else False
        needs_try = (not swallowed) and (calls_throwing or rhs.lstrip().startswith("try "))
        for m in re.finditer(r"await\s+" + re.escape(name) + r"\b", clean):
            pre = clean[max(0, m.start() - 12):m.start()]
            has_try = bool(re.search(r"try[?!]?\s*$", pre))
            if needs_try and not has_try:
                add(rel, lm[m.start()], "3-ASYNCLET-NO-TRY",
                    "await %s 缺 try（右值 %s 会抛错）" % (name, rhs))

    # ---------- 4. 已知 async 函数漏 await ----------
    # 两类匹配，互不干扰：
    #   APIClient.xxx(   —— worker_asyncs（APIClient.swift 里声明的 async 函数）
    #   xxx(             —— 本文件内声明的 async 函数（裸调用）
    targets = [(name, r"(?<!\w)APIClient\s*\.\s*" + re.escape(name) + r"\s*\(")
               for name in worker_asyncs]
    targets += [(name, r"(?<![\w.])" + re.escape(name) + r"\s*\(")
                for name in local_asyncs]
    for name, pat in targets:
        for m in re.finditer(pat, clean):
            pre = clean[max(0, m.start() - 60):m.start()]
            if re.search(r"await\s+[^;{}]*$", pre):          # 前面已有 await
                continue
            if re.search(r"\bfunc\s+$", pre):                # 声明处
                continue
            # `async let x = <右边任何东西>` / `async let x: T = try? APIClient.`
            # —— async let 初始化式不写 await，这是合法语法
            if re.search(r"\basync\s+let\s+\w+\s*(?::[^=]*)?=\s*(?:try[?!]?\s*)?[\w.]*$", pre):
                continue
            line_start = clean.rfind("\n", 0, m.start()) + 1
            line_end = clean.find("\n", m.start())
            this_line = clean[line_start:line_end if line_end > 0 else len(clean)]
            if re.search(r"\bawait\b", this_line):            # 同一行已有 await（并发/链式）
                continue
            if re.search(r"\bfunc\s+\w+\s*\(", this_line):    # 声明行
                continue
            add(rel, lm[m.start()], "4-MISSING-AWAIT",
                "%s( 调用点无 await —— %s" % (name, this_line.strip()[:70]))

    # ---------- 5. await 落在非 async 的 func 作用域 ----------
    # 作用域分三类：
    #   func           → 看签名有没有 async
    #   async-closure  → `Task { }` / `.task { }` / `.refreshable { }` / withTaskGroup，
    #                    闭包体天然是 async 上下文，遇到即止（不再往外看）
    #   普通闭包        → 透明（SwiftUI 的 body、withAnimation、if/switch 花括号等），继续往外找
    scope = []
    seg_start = 0
    for i, ch in enumerate(clean):
        if ch == "{":
            seg = clean[seg_start:i]
            if re.search(r"\bfunc\s+(\w+)\s*(?:<[^>{}()]*>)?\s*\(", seg):
                tail = seg[seg.rfind("func"):]
                scope.append(("func", bool(re.search(r"\)\s*[^{}\n]*\basync\b", tail)), lm[i]))
            elif ASYNC_CLOSURE.search(seg):
                scope.append(("async-closure", True, lm[i]))
            else:
                scope.append(("closure", None, lm[i]))
            seg_start = i + 1
        elif ch == "}":
            if scope:
                scope.pop()
            seg_start = i + 1
        elif clean.startswith("await", i) and (
                i == 0 or not (clean[i - 1].isalnum() or clean[i - 1] in "_$")):
            for kind, is_async, _ln in reversed(scope):
                if kind == "async-closure":
                    break
                if kind == "func":
                    if not is_async:
                        add(rel, lm[i], "5-AWAIT-IN-SYNC", raw_lines[lm[i] - 1])
                    break

    # ---------- 6. 残留字样 ----------
    for idx, raw in enumerate(raw_lines, start=1):
        if "香港" in raw:
            add(rel, idx, "6-HK-RESIDUE", raw)
        if "→备用→" in raw or "直连→北京→" in raw:
            add(rel, idx, "6-LINE-ORDER", raw)

    # ---------- 7. 括号平衡 ----------
    for op, cl, kind in (("{", "}", "BRACE"), ("(", ")", "PAREN"), ("[", "]", "BRACKET")):
        d = clean.count(op) - clean.count(cl)
        if d != 0:
            add(rel, len(raw_lines), "7-" + kind + "-IMBALANCE", "差 %+d" % d)

    return clean


def main():
    # 扫不到文件 = 路径算错了，不能当成「零问题」放过去（这正是假绿灯的经典来源）
    if not FILES:
        print("IS_PASS: NO —— 一个 .swift 都没找到，TARGET_DIR=%s" % TARGET_DIR)
        return 1
    clean_by_file = {}
    for rel in FILES:
        path = os.path.join(TARGET_DIR, rel)
        if not os.path.exists(path):
            add(rel, 0, "0-MISSING-FILE", "文件不存在")
            continue
        with io.open(path, "r", encoding="utf-8") as f:
            clean_by_file[rel] = strip_all(f.read())

    per_file, worker_asyncs, throwing_funcs = collect_func_sets(clean_by_file)

    for rel in FILES:
        path = os.path.join(TARGET_DIR, rel)
        if not os.path.exists(path):
            continue
        with io.open(path, "r", encoding="utf-8") as f:
            check_file(rel, f.read(), per_file.get(rel, set()), worker_asyncs, throwing_funcs)

    print("扫描 %d 个文件：%s" % (len(FILES), TARGET_DIR))
    print("APIClient async 池：%d 个 / throws func 池：%d 个"
          % (len(worker_asyncs), len(throwing_funcs)))
    print("=" * 96)
    if not issues:
        print("IS_PASS: YES —— 七项全通过")
        print("=" * 96)
        return 0
    by_kind = {}
    for path, lineno, kind, text in issues:
        by_kind.setdefault(kind, []).append((path, lineno, text))
    for kind in sorted(by_kind):
        print("[%s] %d 处" % (kind, len(by_kind[kind])))
        for path, lineno, text in by_kind[kind][:40]:
            print("   %-30s %-6s %s" % (path, lineno, text[:100]))
    print("-" * 96)
    print("共 %d 条待复核" % len(issues))
    print("=" * 96)
    return 1


if __name__ == "__main__":
    sys.exit(main())
