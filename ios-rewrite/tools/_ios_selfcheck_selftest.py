#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自检脚本的"反向验证"：故意放回 CI run #45 的原始错误，确认扫描器真的能抓到。

若这里全部命中，说明 `_ios_selfcheck.py` 不是空转（vacuous pass）。
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importlib.util

spec = importlib.util.spec_from_file_location("selfcheck", os.path.join(HERE, "_ios_selfcheck.py"))
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

FIXTURE = u'''
struct BuggyShopView: View {
    private let initialTab: Int
    @State private var tab
    @State private var prevTab

    init(initialTab: Int = 0) {
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab)
    }

    private func load() async {
        async let p = APIClient.pointPackages()
        async let ub = session.token.map { APIClient.dsUses(token: $0) }
        let pkgs = (try? await p) ?? []
        let uses = (try? await ub)?.left
        _ = uses
    }

    private func syncHelper() {
        let x = APIClient.pointPackages()
        _ = x
    }

    private func syncButAwaits() {
        try? await Task.sleep(nanoseconds: 1)
    }
}
'''

# 全部在内存里跑：不落盘、不在仓库里留 `_sc_tmp/`（CI 跑完会污染工作区）。
clean = sc.strip_all(FIXTURE)
# fixture 里没有 APIClient 的声明，手工注入真实池里的两个 async 函数
_per_file, _worker, _thr = sc.collect_func_sets({"Core/APIClient.swift": u'''
static func pointPackages() async throws -> [Int] { return [] }
static func dsUses(token: String?) async throws -> Int { return 0 }
'''})
sc.issues = []
sc.check_file("Fixture.swift", FIXTURE, set(), _worker, _thr)

kinds = {}
for _p, _l, k, t in sc.issues:
    kinds.setdefault(k, []).append((_l, t))

print("命中类别：")
for k in sorted(kinds):
    print("  %-22s x%d  e.g. %s" % (k, len(kinds[k]), kinds[k][0][1][:80]))
print("-" * 70)

EXPECT = [
    ("1-STATE-NO-TYPE", 2, "tab / prevTab 缺类型标注"),
    ("2-ASYNCLET-MAP", 1, "async let + Optional.map"),
    ("4-MISSING-AWAIT", 1, "syncHelper 里漏 await"),
    ("5-AWAIT-IN-SYNC", 1, "syncButAwaits 里 await"),
]

ok = True
for kind, need, why in EXPECT:
    got = len(kinds.get(kind, []))
    flag = "OK  " if got >= need else "MISS"
    if got < need:
        ok = False
    print("%-5s %-22s 期望>=%d 实际=%d   (%s)" % (flag, kind, need, got, why))

# 3-ASYNCLET-NO-TRY：`async let ub` 的右值是 Optional.map（不抛错），所以这里不该报；
# 真正该报的是裸 try 的情况，单独验一下。
EXTRA = u'''
static func throwingThing() async throws -> Int { return 0 }

func f() async {
    async let a = throwingThing()
    let v = await a
    _ = v
}
'''
sc.issues = []
sc.check_file("Extra.swift", EXTRA, {"throwingThing"}, set(), {"throwingThing"})
hit3 = [i for i in sc.issues if i[2] == "3-ASYNCLET-NO-TRY"]
print("%-5s %-22s 期望>=1 实际=%d" % ("OK  " if hit3 else "MISS", "3-ASYNCLET-NO-TRY", len(hit3)))
if not hit3:
    ok = False

# 8-AE-UNKNOWN-MEMBER：run#48 的真实错误 `AE.paper`（paper 其实在 extension Color 里）。
# 用真实的两块声明做对照表：enum AE 有 accent/card/chatFont，extension AE 有 extra；
# paper 只在 extension Color 里 —— 所以 AE.paper 必须被抓出来，AE.nope 也是。
AE_FIXTURE = u'''
enum AE {
    static let accent = 1
    static let card = 2
    static func chatFont(_ s: Int) -> Int { return s }
}

extension AE {
    static let extra = 3
}

extension Color {
    static var paper: Int { return 0 }
}

func bad() {
    _ = AE.paper
    _ = AE.nope
    _ = AE.accent
    _ = AE.extra
    _ = AE.chatFont(1)
    _ = Color.paper
}
'''
sc.issues = []
sc.AE_MEMBERS.clear()
sc.AE_MEMBERS.update(sc.collect_ns_members({"Models/Models.swift": AE_FIXTURE}, "AE"))
sc.check_file("AEUse.swift", AE_FIXTURE, set(), set(), set())
hit8 = [i for i in sc.issues if i[2] == "8-AE-UNKNOWN-MEMBER"]
hit8_txt = " ".join(i[3] for i in hit8)
ok8 = (len(hit8) == 2) and ("AE.paper" in hit8_txt) and ("AE.nope" in hit8_txt)
print("%-5s %-22s 期望=2 实际=%d   (%s)" % ("OK  " if ok8 else "MISS", "8-AE-UNKNOWN-MEMBER", len(hit8), hit8_txt[:70]))
if not ok8:
    ok = False

print("-" * 70)
print("SELFTEST: " + ("PASS（扫描器有效）" if ok else "FAIL（扫描器空转，需修）"))
sys.exit(0 if ok else 1)