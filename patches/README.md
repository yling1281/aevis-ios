# 待应用的补丁

这几个文件太大（`AppSettings.swift` 78KB、`SettingsView.swift` 42KB），
走工具整文件覆盖不现实，所以把改动做成了补丁。

## 一条命令搞定

仓库根目录：

```bash
bash patches/apply_patches.sh
```

打完后：

```bash
xcodegen generate
```

脚本会跳过已经打过的补丁，所以**可以重复跑**。

⚠️ 顺序有依赖：`brand-accent` 引入 `ProviderPreset.aevis`，`cloud-card` 里的
`CloudCard` 会用它。脚本已经排好序，别自己改顺序。

## 直接推送（不用管）

| 文件 | 内容 |
| --- | --- |
| `Aevis/Core/AevisCloud.swift` | 姜言后端接入层 + `BackupCodeService` |
| `Aevis/Features/Settings/CloudCard.swift` | 「姜言云端」设置卡（余额 / 内置 API / 充值 / 转移账号） |
| `Aevis/API_SELFHOST.md` | 接入说明 |

## 需要应用补丁

| 补丁 | 改什么 |
| --- | --- |
| `brand-accent.patch` | `AppSettings.swift`：主题色默认档改品牌青 + 新增 `ProviderPreset.aevis` |
| `cloud-card.patch` | `SettingsView.swift`：把 `CloudCard()` 注册进设置页 |
| `cloudcard-fix.patch` | `CloudCard.swift`：备份码造码死循环 + 文案更正 |
| `login-page.patch` | `LoginView.swift`：去掉邮箱验证码登录，改账号密码 + 圆形第三方入口 |

## 🔴 脚本为什么要「修补丁」

2026-10-19 踩了一整天：四个补丁**全打不上**，报 `corrupt patch at ...`。
根因是**空白被破坏**，有三种：

1. **末尾换行被剥掉** —— GitHub 存文本文件时会去掉最后那个换行。
2. **上下文空行被吞成真空行** —— hunk 里的上下文空行正确形态是「**一个空格** + 换行」，
   肉眼看不见，过一趟网络/编辑器就没了。
3. **上下文空行被写成 `-`** —— 看着像删除行，hunk 的行数计数直接对不上。

`apply_patches.sh` 里的 `fix_blank()` 就是修这三种的（用 awk，不依赖 python）。

⚠️ **如果你手改补丁**，改完自己 `git apply --check` 验一下，别直接上。

## 不想用命令行

`brand-accent.patch` 是 10 处改动，都是纯文本新增/替换，可以在 Xcode 里手动改。
其余三个补丁（改动较多）建议直接用脚本。

### 1. `ProviderPreset` 加一个 case

`enum ProviderPreset` 开头加：

```swift
    /// 姜言自建后端（`ai.aevis.cn`）。**放第一个** —— 它是自家服务，
    /// 用它不需要用户自己找地址、不需要自己有 API Key，登录后计费按账号走。
    case aevis
```

然后 4 个 switch 各加一行：

| 位置 | 加这一行 |
| --- | --- |
| `var label` | `case .aevis: return "姜言云端"` |
| `var baseURL` | `case .aevis: return AevisCloud.chatBase` |
| `var defaultModel` | `case .aevis: return "aevis-chat"` |
| `var keyHint` | `case .aevis: return "登录姜言账号就有，不用单独申请"` |

⚠️ 四个 switch **都得加**。Swift 的 `switch` 对 enum 要求穷尽，
少一个就是编译错误 —— 这是最容易踩的一步。

### 2. 主题色改成品牌青

```swift
    static let accentPalette: [Color] = [
        Color(red: 63/255, green: 157/255, blue: 144/255),   // 原来是 0.42/0.35/0.95（紫）
        ...
    ]

    static let accentNames = ["青", "蓝", "青绿", "玫红", "橙", "绿"]
    //                              ↑ 原来是“紫”

    static let bubbleColorNames = ["中性灰", "青", "蓝", "青绿", "玫红", "橙", "绿"]
    //                                       ↑ 原来也是“紫”
```

第 0 项是**出厂默认**（`accentIndex = 0`），所以改了它，新装的用户直接就是品牌青；
已经手动挑过颜色的用户不受影响（他们存的是别的下标）。

### 3. 出厂默认指向姜言云端

`init` 里那两行：

```swift
baseURL = defaults.string(forKey: Key.baseURL) ?? AevisCloud.chatBase   // 原来写死 deepseek
model = defaults.string(forKey: Key.model) ?? "aevis-chat"
providerPreset = ProviderPreset(rawValue: defaults.string(forKey: Key.providerPreset) ?? "") ?? .aevis
```

### 4. `SettingsView` 注册卡片

`sections` 里「账号与数据」那组的 `keys` 开头加 `"cloud"`：

```swift
keys: ["cloud", "account", "device", "devicelist", "pair", "share", "about"]
```

`card(_ key:)` 的 switch 里加：

```swift
case "cloud": CloudCard()
```

## 改完之后

```bash
xcodegen generate
```

新文件（`AevisCloud.swift` / `CloudCard.swift`）在 `Aevis/` 目录下，
`project.yml` 里 `sources: - path: Aevis` 是整个目录，所以**不用改工程配置**。