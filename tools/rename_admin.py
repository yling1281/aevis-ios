# -*- coding: utf-8 -*-
"""给**管理端**换品牌名 —— 它就是一个"名字随便改"的模板。

用法（在 `aevis-ios` 目录下）：

    python tools/rename_admin.py 星语          # 改成「星语」，桌面/界面/安装源一起变
    python tools/rename_admin.py --check       # 只看现在叫什么、有没有残留，不改

**只改一处** —— `project.yml` 里 AevisAdmin 的 `ADMIN_BRAND`。其余全是从它派生的：

  1. `AevisAdmin/Resources/Info.plist` 的 `CFBundleDisplayName` = `$(ADMIN_BRAND) 管理端`
     → 桌面图标名
  2. 同一个 plist 的 `AEAdminBrand` = `$(ADMIN_BRAND)` → `AdminBrand.swift` 读它
     → App 里的标题（登录页 / 导航栏 / 导出诊断）
  3. `build_webroot.py` 读 `project.yml` 这一行 → 签工具（全能签）源里显示的名字

⚠️ **iOS 的桌面图标名是编译期定死的**，运行期改不了 ——
   所以改完名字**必须重新出一次管理端的包**才生效（主 App 不用重出）。

⚠️ 出包时顺手把版本号升一位：`project.yml` 的 `MARKETING_VERSION` /
   `CURRENT_PROJECT_VERSION`，以及 `build_webroot.py` 的 `ADMIN_VERSION` /
   `ADMIN_BUILD`。同名同版本号，签工具那边可能拿的是缓存。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
ROOT = os.path.dirname(IOS)

PROJECT_YML = os.path.join(IOS, "project.yml")
PLIST = os.path.join(IOS, "AevisAdmin", "Resources", "Info.plist")
WEBROOT_PY = os.path.join(ROOT, "build_webroot.py")
ADMIN_DIR = os.path.join(IOS, "AevisAdmin")

# 这几行**故意**留着旧字样，不是漏改 —— 扫残留时跳过。
# （判断依据是"整行含有这个片段"，所以写得具体一点。）
ALLOW = [
    # 识别**主 App** 的 UA 特征，跟管理端叫什么无关
    'ua.contains("aevis")',
]

BRAND_RE = re.compile(r'(?m)^(\s*ADMIN_BRAND:\s*)(["\']?)([^"\'\n#]*?)\2(\s*)$')


def read_brand():
    text = io.open(PROJECT_YML, encoding="utf-8").read()
    found = BRAND_RE.search(text)
    if not found:
        print("✗ 没在 project.yml 里找到 ADMIN_BRAND —— 工程配置被改过？")
        sys.exit(1)
    return found.group(3).strip()


def write_brand(old, new):
    text = io.open(PROJECT_YML, encoding="utf-8").read()
    new_text, count = BRAND_RE.subn(lambda m: m.group(1) + '"' + new + '"' + m.group(4),
                                    text, count=1)
    if count != 1:
        print("✗ 写 project.yml 失败（匹配到 %d 处，应该只有 1 处）" % count)
        sys.exit(1)
    io.open(PROJECT_YML, "w", encoding="utf-8", newline="\n").write(new_text)


def check_plist():
    """确认 plist 里是占位符而不是写死的名字。"""
    text = io.open(PLIST, encoding="utf-8").read()
    problems = []
    if "$(ADMIN_BRAND) 管理端" not in text:
        problems.append("CFBundleDisplayName 不是 `$(ADMIN_BRAND) 管理端`（是不是被写死了？）")
    if "<key>AEAdminBrand</key>" not in text or text.count("$(ADMIN_BRAND)") < 2:
        problems.append("少 `AEAdminBrand` 这一项 —— App 里的标题读不到品牌名")
    return problems


def scan_leftovers(brand):
    """扫还写死品牌名的地方。返回 [(文件, 行号, 那一行)]。"""
    hits = []
    for name in sorted(os.listdir(ADMIN_DIR)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(ADMIN_DIR, name)
        for no, line in enumerate(io.open(path, encoding="utf-8"), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            if any(allowed in line for allowed in ALLOW):
                continue
            # 只看**字符串字面量**里、而且是**整词**出现的品牌名。
            # ⚠️ 不加"整词"判定的话，`AevisHosts` / `AevisAdmin` 这种标识符
            #    会被当成名字报出来（2026-09-27 第一次跑就误报了两处）——
            #    误报会让人不再信任这个扫描，等于没有。
            pattern = (r'"[^"]*(?<![A-Za-z])' + re.escape(brand)
                       + r'(?![A-Za-z])[^"]*"')
            if re.search(pattern, line):
                hits.append((name, no, stripped))
    return hits


def main():
    args = [a for a in sys.argv[1:]]
    only_check = "--check" in args
    args = [a for a in args if not a.startswith("--")]
    brand = read_brand()

    print("现在管理端叫：%s" % brand)
    print("  桌面图标名 / 登录页标题  → %s 管理端" % brand)
    print("  导航栏标题               → %s 管理" % brand)
    print("  签工具源里显示           → %s 管理端" % brand)
    print("  （来源：project.yml 的 ADMIN_BRAND —— 全项目就这一处）")

    problems = check_plist()
    if problems:
        print("\n⚠️ plist 那边有问题（先修它，不然只是改了个名字、界面不变）：")
        for p in problems:
            print("   · " + p)

    # 改之前先扫一遍旧名字的残留（改完就没法用旧名字找了）
    leftovers = scan_leftovers(brand)
    if leftovers:
        print("\n⚠️ 这些地方还写死着「%s」（应该都改成走 `AdminBrand`）：" % brand)
        for name, no, line in leftovers:
            print("   %s:%d  %s" % (name, no, line))

    if only_check:
        if not problems and not leftovers:
            print("\n✓ 干净：没有残留，plist 也是占位符。")
        return

    if not args:
        print("\n用法：python tools/rename_admin.py 新名字    （或 --check 只看不改）")
        return

    new = args[0].strip()
    if not new:
        print("✗ 新名字是空的")
        return
    if new == brand:
        print("\n跟现在一样，不用改。")
        return
    if "\n" in new or '"' in new or "\\" in new:
        print('✗ 名字里不能有换行 / 双引号 / 反斜杠')
        return

    write_brand(brand, new)
    print("\n✓ 已把 ADMIN_BRAND 改成「%s」（project.yml）" % new)

    after = read_brand()
    if after != new:
        print("✗ 写进去了但读回来是「%s」—— 去 project.yml 看一眼" % after)
        sys.exit(1)

    still = scan_leftovers(new)
    if still:
        print("⚠️ 还有写死新名字的地方：")
        for name, no, line in still:
            print("   %s:%d  %s" % (name, no, line))
    print("""
接下来（这几件事我这边做不了，得你点头）：

  1. 出一次**管理端**的包（CI 跑 admin 那条流水线）——
     桌面图标名是编译期定的，不出包名字不会变。
  2. 出包前把版本号升一位：
     project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION
     build_webroot.py 的 ADMIN_VERSION / ADMIN_BUILD
     （同名同版本，签工具那边可能拿的是缓存。）
  3. 重跑 build_webroot.py + 部署，源里的名字才跟着变。

  主 App（买家的那个）**不受影响**，名字还是原来的、不用重出。
""")


if __name__ == "__main__":
    main()
