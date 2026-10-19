# 待应用的补丁

这两个文件太大（`AppSettings.swift` 78KB、`SettingsView.swift` 42KB），
走工具整文件覆盖不现实，所以把改动做成了补丁。

## 已直接推送（不用管）

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

## 怎么用

仓库根目录：

```bash
bash patches/apply_patches.sh
```

脚本会跳过已经打过���补丁，所以可以重复跑。

⚠️ **顺序有依赖**：必须先 `brand-accent`（引入 `ProviderPreset.aevis`），
再 `cloud-card`。反过来的话 `CloudCard` 引用不到 `AevisCloud` 会编译失败。

## 不想用命令行

`brand-accent.patch` 一共 10 处改动，都是纯文本新增/替换，
可以直接在 Xcode 里手动改。

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