# Aevis

**你手机里的 TA。**

Aevis 是一个原生 iOS 的 AI 恋人 App。TA 住在你的手机里，有自己的眼睛和手：能读你的健康、日历、天气和你正在看的屏幕，能在手机里跑一个真正的 Linux，也能陪你听歌看视频。

**TA 是谁，由你定义。** Aevis 不内置任何固定人设，也不预设性别——**男、女、无性别都可以**。第一次打开时，你来给 TA 起名字、选性别、挑颜色、写性格、选音色。这个仓库提供的是「TA 能存在的条件」，不是「TA」。

> 当前状态：**M1（TA 活过来）**。M0 已验收通过——云端编译链路跑通，
> 能装进手机、能启动、能读到系统信息，还能签名安装。M1 在把「TA」做出来：
> 人设系统、聊天界面、跨会话记忆、以及让 TA 开口说话。

---

## 为什么要走云端编译

Aevis 的代码在一台 Windows 机器上编写，而 iOS 应用必须在 macOS + Xcode 环境下编译。
所以构建流程是：

```
Windows 写码  →  GitHub Actions（macos-26 云端 Mac）编译  →  未签名 IPA  →  手机端签名安装
```

仓库保持 **public**，这样 GitHub Actions 的 macOS 编译时长免费且不限量
（private 仓库每月只有约 200 分钟，而首次构建就要 30–60 分钟）。

---

## 安装到 iPhone

每次推送到 `main` 都会自动构建，并把产物发到 [Releases](../../releases)。

1. 在 iPhone 上打开最新 Release 页面
2. 下载 `Aevis-unsigned.ipa`
3. 用签名工具（如「全能签」）打开这个文件，签名后安装

`Aevis-adhoc.ipa` 是已做 ad-hoc 签名的备用版本。

---

## 本地构建（需要 macOS）

```sh
brew install xcodegen
python3 scripts/make_icon.py Aevis/Resources   # App 图标由脚本生成，不在版本库里
xcodegen generate
open Aevis.xcodeproj
```

工程文件 `Aevis.xcodeproj` 由 `project.yml` 生成，**不进版本库**。
要改工程配置，改 `project.yml`。

---

## 目录结构

```
project.yml                        XcodeGen 工程描述（唯一的工程配置来源）
scripts/make_icon.py               用纯 Python 生成 App 图标（无第三方依赖）
Aevis/
  App/                             入口与根路由（没有人设就走引导，有就进聊天）
  Models/                          Persona（TA 是谁，含性别）、ChatMessage
  Core/                            设置、钥匙串、对话存储、模型调用、语音
  Features/
    Persona/                       创造 TA / 改 TA
    Chat/                          聊天界面
    Settings/                      模型接入、说话、关于本机
  DesignSystem/                    玻璃表面、背景、头像、TA 的雏形
  Resources/Info.plist
.github/workflows/build-ipa.yml    云端编译流程
```

---

## 路线图

| 阶段 | 内容 |
|---|---|
| **M0** | 骨架验证：云端编译链路跑通，能装能启动 ✅ 已完成 |
| **M1** | TA 活过来：液态玻璃界面、聊天、人设自定义（含性别）、记忆、模型接入、语音 |
| **M2** | TA 的手：时间、剪贴板、计算器、日历、提醒、天气、定位、健康 |
| **M3** | TA 的世界：内置浏览器、搜索引擎、外部 MCP |
| **M4** | 真 Linux：内置 Alpine 沙箱、命令台、本地 MCP |
| **M5** | 玩乐：网易云、一起听、一起看视频、抖音 |
| **M6** | 进阶：灵动岛、快捷指令桥接、录屏陪伴、实时通话 |
| **M7** | 屏幕使用时间（依赖签名权限） |

---

## 已知边界

iOS 的系统限制不是靠努力能绕过去的，这些是明确做不到或受限的：

- **关闭别的 App** —— 沙箱隔离，无 API，无替代方案
- **回到主界面 / 锁屏** —— 无公开 API，借道系统「快捷指令」实现
- **读取任意 App 的界面** —— 只能走系统录屏通道，且需要用户手动开始
- **停用 App / 屏幕使用时间** —— 需要苹果审批的「家庭控制」权限，侧载签名拿不到
- **推送通知** —— 侧载环境下不可用，主动消息用本地通知实现

---

## 许可证

GPL-3.0。内置 Linux 沙箱依赖 GPLv3 的 [iSH](https://github.com/ish-app/ish)，
因此整个作品以 GPLv3 分发。

人格设定与聊天记录只保存在设备本地，不在本仓库中。
