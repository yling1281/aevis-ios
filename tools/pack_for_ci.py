"""把整个仓库打成给 CI 用的包，放到一个待发布的目录里。

## 为什么要这么绕

连接器推代码，要我把**每个文件的内容**塞进一次工具调用里 ——
七十多个文件、几百 KB，根本传不完。所以改成：

    本地打包 → 放到一个能匿名下载的地方 → 仓库里只推**一个几十字节的地址文件**
    → CI 自己去取 → 取完顺手把源码提交回仓库（之后仓库就完整了）

## 用法

    python tools/pack_for_ci.py [输出目录]        默认 ../../deploy-src

跑完会打印 sha256 和几个关键文件的行数 —— **推之前先核对一眼**，
尤其是每次新加的文件在不在里面。
"""

import hashlib
import importlib.util
import io
import os
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(ROOT)

# 每次都要确认在包里的文件（新增重要文件时加到这儿）
MUST_HAVE = [
    "Aevis/Core/EmojiPack.swift",
    "Aevis/Core/MCPClient.swift",
    "Aevis/Core/MCPStore.swift",
    "Aevis/Features/Settings/MCPCard.swift",
    "Aevis/Features/Chat/ChatView.swift",
    "Aevis/Core/ScreenCompanion.swift",
    # ——— 系统录屏扩展（独立 target，最容易漏）———
    "Broadcast/SampleHandler.swift",
    "Broadcast/Info.plist",
    "Broadcast/AevisBroadcast.entitlements",
    "Aevis/Core/ScreenShareStore.swift",
    # 环回备用通道：App Group 对不上时靠它把文字送回来（两个 target 共用）
    "Aevis/Core/ExtensionLink.swift",
    "Aevis/Core/BroadcastPicker.swift",
    "Aevis/Aevis.entitlements",
    "scripts/strip_extension.py",
    # ——— 百度网盘这一批（2026-09-25 新增）———
    "Aevis/Core/BaiduPanClient.swift",
    "Aevis/Core/BaiduPanTools.swift",
    "Aevis/Core/BackupService.swift",
    # 凭据文件必须带上（仓库/包里那份的值永远是空的，真值由 CI 注入）
    "Aevis/Core/BuiltInSecrets.swift",
    "Aevis/Features/Settings/BaiduPanCard.swift",
    "scripts/inject_secrets.py",
    # ——— 微信式结构：四个 tab + 多联系人 ———
    "Aevis/App/MainTabView.swift",
    "Aevis/App/AppRouter.swift",
    "Aevis/Models/Contact.swift",
    "Aevis/Features/Chat/ChatListView.swift",
    "Aevis/Features/Contacts/ContactsView.swift",
    "Aevis/Features/Discover/DiscoverView.swift",
    "Aevis/Features/Me/MeView.swift",
    # ——— 全屏播放器（仿网易云）———
    "Aevis/Features/Music/PlayerView.swift",
    "Aevis/Features/Music/MusicView.swift",
    "Aevis/Core/MusicPlayer.swift",
    # ——— 第二批新功能（2026-09-25 下午）———
    # 多模态：PDF / Word / RTF
    "Aevis/Core/AttachmentService.swift",
    # QQ 桥接（OneBot 兼容）
    "Aevis/Core/QQBridge.swift",
    "Aevis/Core/QQTools.swift",
    "Aevis/Features/Settings/QQCard.swift",
    # 账号（给以后那个服务器留的接口层）
    "Aevis/Core/AccountService.swift",
    "Aevis/Features/Settings/AccountCard.swift",
    # 配置二维码 + 备份到文件
    "Aevis/Core/ConfigShare.swift",
    "Aevis/Features/Settings/ShareCard.swift",
    "Aevis/Features/Settings/QRScannerView.swift",
    # ——— QQ 官方机器人（唯一能在手机上跑、不用电脑的那条路）———
    "Aevis/Core/QQBotClient.swift",
    "Aevis/Core/QQBotService.swift",
    "Aevis/Core/QQCodeGate.swift",
    "Aevis/Core/QQBotTools.swift",
    # 后台静音保活 —— Info.plist 里的 UIBackgroundModes 靠它才有意义
    "Aevis/Core/SilentKeeper.swift",
    "Aevis/Features/Settings/QQBotCard.swift",
    "Aevis/Features/Settings/DisclaimerView.swift",
    # 主 App 的 Info.plist 必须带上（UIBackgroundModes 在里面）
    "Aevis/Resources/Info.plist",
    "Aevis/App/RootView.swift",
    ".github/shots.txt",
]


def load_collector():
    """复用 push_all.py 的收集规则 —— 保证打包和推送看到的是同一批文件。"""
    spec = importlib.util.spec_from_file_location(
        "push_all", os.path.join(ROOT, "push_all.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    stage = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PROJECT, "..", "deploy-src")
    stage = os.path.abspath(stage)

    collector = load_collector()
    files = collector.collect_files()

    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)

    bundle = os.path.join(stage, "aevis-source.bin")
    with zipfile.ZipFile(bundle, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for rel, full in sorted(files.items()):
            archive.write(full, "aevis-ios/" + rel)

    with open(bundle, "rb") as handle:
        data = handle.read()

    print("包：%d 个文件 / %d 字节" % (len(files), len(data)))
    print("sha256：%s" % hashlib.sha256(data).hexdigest())
    print()

    with zipfile.ZipFile(bundle) as archive:
        names = set(archive.namelist())
        print("关键文件在里面吗：")
        missing = 0
        for probe in MUST_HAVE:
            present = ("aevis-ios/" + probe) in names
            if not present:
                missing += 1
            print("   %-46s %s" % (probe.split("/")[-1], "✓" if present else "✗ 缺了！"))

        # 顺手把版本号打出来，免得又忘了改
        yml = archive.read("aevis-ios/project.yml").decode("utf-8")
        for line in yml.splitlines():
            if "MARKETING_VERSION" in line or "CURRENT_PROJECT_VERSION" in line:
                print("   " + line.strip())

    # 静态服务器要一个入口文件
    io.open(os.path.join(stage, "index.html"), "w", encoding="utf-8", newline="\n").write(
        "<!doctype html><meta charset=utf-8><title>Aevis</title><p>ok</p>"
    )

    print()
    if missing:
        print("⚠️ 有 %d 个关键文件不在包里，先别推。" % missing)
        return 1
    print("下一步：把这个目录部署出去，拿到地址后再推 .bootstrap-url。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
