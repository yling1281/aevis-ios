"""给「录屏接线」那几条新规则做反向验证。

规则写完不验证等于没写 —— 你不知道它到底是**能抓**还是**永远不响**。
这个脚本把每一处故意改坏、跑一次检查、看它报不报，然后还原。

覆盖：
  A. 扩展 Info.plist 的 NSExtensionPointIdentifier 写错
  B. 扩展的 entitlements 声明了**另一个**应用组
  C. project.yml 里的扩展 bundle id 和代码里写的不一致
  D. strip_extension.py 能摘干净、摘完还是合法 YAML
  E. 干净状态下一条都不报（防误报）

跑完会自己还原，并从备份比对，确认文件**逐字节**回到原样。
"""

import io
import os
import shutil
import subprocess
import sys

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON = sys.executable

EXT_PLIST = os.path.join(PROJECT, "Broadcast", "Info.plist")
EXT_ENTITLEMENTS = os.path.join(PROJECT, "Broadcast", "AevisBroadcast.entitlements")
SPEC = os.path.join(PROJECT, "project.yml")
MARKER = os.path.join(PROJECT, ".release", "no-extension")

TOUCHED = [EXT_PLIST, EXT_ENTITLEMENTS, SPEC]

results = []


def run_checker():
    done = subprocess.run(
        [PYTHON, "-X", "utf8", "-u", "tools/swift_check.py"],
        cwd=PROJECT, capture_output=True, text=True, encoding="utf-8",
    )
    return done.stdout + done.stderr


def backup():
    for path in TOUCHED:
        shutil.copyfile(path, path + ".probe-bak")


def restore():
    for path in TOUCHED:
        backup_path = path + ".probe-bak"
        if os.path.exists(backup_path):
            shutil.copyfile(backup_path, path)


def verify_restored():
    for path in TOUCHED:
        backup_path = path + ".probe-bak"
        with open(path, "rb") as handle:
            now = handle.read()
        with open(backup_path, "rb") as handle:
            was = handle.read()
        if now != was:
            return False, path
    return True, None


def cleanup_backups():
    """备份文件挪走而不是删 —— 这个沙箱里删文件会被拦。"""
    for path in TOUCHED:
        backup_path = path + ".probe-bak"
        if os.path.exists(backup_path):
            try:
                os.rename(backup_path, backup_path + ".done")
            except OSError:
                pass


def check(label, expect, mutate=None, after=None):
    if mutate:
        mutate()
    output = run_checker()
    hits = [line for line in output.splitlines() if line.startswith("【R15】")]
    # probe 文件本身可能也被算进去，只关心有没有报
    reported = len(hits) > 0
    ok = reported == expect
    detail = ""
    if hits:
        detail = " | 报了 %d 条，第一行：%s" % (len(hits), hits[0][:110])
    results.append((ok, label, reported, expect, detail))
    print("%s  %-46s 报=%s 期望=%s%s" % ("OK " if ok else "XX ", label, reported, expect, detail))
    if after:
        after()


def main():
    backup()
    try:
        print("=== 0) 干净状态：不该有任何 R15 ===")
        check("干净状态不误报", False)

        print()
        print("=== A) 扩展注册点写错 ===")

        def bad_point():
            text = io.open(EXT_PLIST, encoding="utf-8").read()
            text = text.replace(
                "<string>com.apple.broadcast-services-upload</string>",
                "<string>com.apple.broadcast-services</string>",
            )
            io.open(EXT_PLIST, "w", encoding="utf-8", newline="\n").write(text)

        check("NSExtensionPointIdentifier 写错能抓到", True, bad_point, restore)

        print()
        print("=== B) 两份应用组不一致 ===")

        def bad_group():
            text = io.open(EXT_ENTITLEMENTS, encoding="utf-8").read()
            text = text.replace("group.com.aevis.ios", "group.com.somebody-else.app")
            io.open(EXT_ENTITLEMENTS, "w", encoding="utf-8", newline="\n").write(text)

        check("扩展声明了别的应用组能抓到", True, bad_group, restore)

        print()
        print("=== C) project.yml 里 bundle id 对不上 ===")

        def bad_bundle():
            text = io.open(SPEC, encoding="utf-8").read()
            text = text.replace(
                "PRODUCT_BUNDLE_IDENTIFIER: com.aevis.ios.broadcast",
                "PRODUCT_BUNDLE_IDENTIFIER: com.aevis.ios.wrongname",
            )
            io.open(SPEC, "w", encoding="utf-8", newline="\n").write(text)

        check("bundle id 不一致能抓到", True, bad_bundle, restore)

        print()
        print("=== D) strip_extension.py 能摘干净 ===")

        def make_marker():
            io.open(MARKER, "w", encoding="utf-8", newline="\n").write("1\n")

        make_marker()
        done = subprocess.run(
            [PYTHON, "-X", "utf8", "-u", "scripts/strip_extension.py"],
            cwd=PROJECT, capture_output=True, text=True, encoding="utf-8",
        )
        stripped_ok = done.returncode == 0
        print("    脚本退出码：%d" % done.returncode)
        print("    " + (done.stdout or done.stderr).strip().replace("\n", "\n    "))

        stripped_text = io.open(SPEC, encoding="utf-8").read()
        try:
            import yaml
            parsed = yaml.safe_load(stripped_text)
            yaml_ok = True
        except Exception as error:
            parsed = None
            yaml_ok = False
            print("    摘完 YAML 解析失败：%s" % error)

        no_target = parsed is not None and "AevisBroadcast" not in parsed.get("targets", {})
        app_target = (parsed or {}).get("targets", {}).get("Aevis", {})
        no_dep = "dependencies" not in app_target
        results.append((stripped_ok and yaml_ok and no_target and no_dep,
                        "摘除后：合法 YAML、无扩展目标、无悬空依赖",
                        True, True, ""))
        print("    合法 YAML=%s  没有 AevisBroadcast 目标=%s  主 App 没有悬空 dependencies=%s"
              % (yaml_ok, no_target, no_dep))

        # 摘除版也要过静态检查（不该因为少了扩展就报错）
        stripped_output = run_checker()
        stripped_r15 = [line for line in stripped_output.splitlines() if line.startswith("【R15】")]
        results.append((not stripped_r15, "摘除版静态检查无 R15", False, False,
                        ("报了：%s" % stripped_r15[:1]) if stripped_r15 else ""))
        print("    摘除后静态检查里 R15 条数：%d" % len(stripped_r15))

        restore()
        try:
            os.rename(MARKER, MARKER + ".done")
        except OSError:
            print("    （标记文件没挪走，注意）")

        print()
        print("=== E) 还原是否逐字节回原样 ===")
        same, bad_path = verify_restored()
        results.append((same, "三个被改过的文件都回到原样", same, True,
                        "" if same else ("不一样：%s" % bad_path)))
        print("    逐字节一致：%s%s" % (same, "" if same else "（%s 不一样）" % bad_path))

    finally:
        restore()
        cleanup_backups()

    print()
    failed = [item for item in results if not item[0]]
    if failed:
        print("有 %d 项没通过：" % len(failed))
        for _, label, got, expect, detail in failed:
            print("   %s（实际 %s / 期望 %s）%s" % (label, got, expect, detail))
        return 1
    print("全部 %d 项通过。" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
