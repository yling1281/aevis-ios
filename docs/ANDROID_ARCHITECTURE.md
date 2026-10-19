# 姜言 Android 端架构设计

> 版本 v1.0 · 2026-10-19
> 后台 = 现在接入微信 AI 的那套（hk `38.76.168.61` 的 `ruoyi-lite` + `wxwork-ai`），**不新建后台**
> iOS 端 = `yling1281/aevis-ios`（341 文件 / Core 102 个 / 27 个功能模块）

---

## 0. 为什么这份文档是照着 iOS 现有代码写的

安卓端不做「另起一套」。iOS 端已经跑出一整套能力基座，安卓端要**一一对标**，
而不是重新设计。下表是 iOS 现状（2026-10-19 实测），它同时也是安卓端的**验收清单**。

| 基座 | iOS 现状 | 安卓要对标的东西 |
|---|---|---|
| 卡片材质 | `GlassSurface.swift` 的 `aevisGlass()`，**58 文件 203 处在用** | 同一套视觉规范（半透明 + 顶部高光 + 双色描边 + 柔光阴影） |
| 主题色 | `AppSettings.accentPalette`，出厂第 0 项 | 品牌青 `#3f9d90`，两端出厂一致 |
| 能力工具 | `DeviceTools.swift` + `ToolCategory` **14 类** | 14 类全对齐，缺一不可 |
| 能力注入 | `CapabilitySpec.block()` 注入进系统提示词 | 同一份文案的安卓版本 |
| 真 Linux | `AlpineRuntime`（iSH 静态库，430 行） | proot + Termux 方案 |
| 自动化 | `AppShortcuts.swift` **10 个 AppIntent** | Shizuku / ADB 路径 |
| 通话 | `SystemCallCenter`（CallKit，521 行） | TelecomManager / ConnectionService |
| 后台协议 | `/v1/*` **68 个接口** | 同一套，一个不改 |

⚠️ **`aevisGlass` 有一条血泪教训，安卓端必须照抄这条约束**：
iOS 0.0.110 曾把描边层从 `strokeBorder` 改成 `fill`，而 SwiftUI 里
**填充形状参与命中测试**，结果高光层把整张卡片的点击全吃掉了 ——
整机所有可点的地方一起失效，截图还完全看不出问题（截图只反映渲染）。
⇒ **安卓端做毛玻璃时，高光层必须 `clickable=false` / `isClickable = false`**，
这是硬性要求，不是可选项。

---

## 1. 整体架构：三层划分

```
┌─────────────────────────────────────────────────────────────┐
│  L3 插件层  Plugin Layer                （两端格式统一）      │
│  .capk 插件包 · 真 Linux 沙箱内跑 · 一起听/日记/杂项工具       │
├─────────────────────────────────────────────────────────────┤
│  L2 平台适配层  Platform Adapter        （唯一允许分叉的地方）  │
│  iOS:  CallKit / AppIntent / iSH / ReplayKit / UserDefaults  │
│  安卓: Telecom / Shizuku / proot / MediaProjection / DataStore│
├─────────────────────────────────────────────────────────────┤
│  L1 共享核心层  Shared Core              （一份逻辑，两端运行）  │
│  协议契约 · 数据模型 · 状态管理 · 计费 · 工具调度 · 业务规则    │
│  ★ 用 Kotlin Multiplatform 编译成 iOS/Android 双端产物       │
├─────────────────────────────────────────────────────────────┤
│  后台 ruoyi-lite（68 个 /v1 接口）· wxwork-ai（企微回调）      │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 L1 共享核心层（关键决策）

**结论：L1 用 Kotlin Multiplatform（KMP）重写，iOS 端通过 Swift 桥接调用。**

理由和代价要说清楚：

| 方案 | 一份逻辑 | 代价 | 结论 |
|---|---|---|---|
| **KMP 重写 L1** | ✅ 真一份 | iOS 端 L1 要重写（约 3-5 人周） | **采用** |
| 只复制粘贴代码 | ❌ 两份 | 必然走偏 | 不采用 |
| 只做接口契约不共享代码 | ❌ | 业务规则还是两份 | 不采用 |

**L1 包含什么**（这些是纯逻辑，无平台依赖）：

- **协议契约** — 68 个 `/v1/*` 接口的请求/响应模型（Kotlin `data class`）
- **数据模型** — `ChatMessage` / `Persona` / `Diary` / `Memory` / `Wallet` / `Order`
- **状态管理** — `ChatStore` / `PersonaStore` / `WalletStore` 的状态机
- **计费** — 按条扣费（0.001 元/条）、余额预校验、套餐顺延规则
- **工具调度** — `DeviceTools` 14 类的**注册表和调用协议**（不含平台实现）
- **业务规则** — 备份码流程、一起听房间配对、日记/经期提醒

**L1 不包含什么**（这些必须留在 L2）：

- 任何 UI 框架代码（SwiftUI / Compose）
- 任何系统 API 调用（CallKit / Telecom / Shizuku）
- 任何持久化实现（UserDefaults / DataStore / SQLDelight）
- 任何并发原语（`@MainActor` / 协程作用域的具体用法）

### 1.2 L2 平台适配层（唯一允许分叉的地方）

**铁律：L2 里不允许出现任何业务判断。** 只做「系统 API 的薄封装」。

```kotlin
// L2 定义接口，L1 调用它 —— 两端各自实现
interface PlatformBridge {
    // —— 通话 ——
    fun startCall(displayName: String): Result<Unit>
    fun hangUp(): Result<Unit>
    fun setMuted(muted: Boolean): Result<Unit>

    // —— 自动化执行（安卓走 Shizuku，iOS 走 AppIntent）——
    suspend fun exec(action: AutomationAction): Result<AutomationResult>

    // —— 真 Linux ——
    suspend fun shell(command: String, timeoutMs: Int): ShellResult

    // —— 系统状态 ——
    fun battery(): BatteryInfo
    fun isCharging(): Boolean
    fun screenOnDurationMinutes(): Int?

    // —— 存储 ——
    fun getString(key: String): String?
    fun putString(key: String, value: String)

    // —— 权限状态 ——
    fun permissionState(p: AppPermission): PermissionState
}

sealed interface AutomationAction {
    data class LaunchApp(val pkg: String) : AutomationAction
    data class ForceStop(val pkg: String) : AutomationAction
    data class SetAppEnabled(val pkg: String, val enabled: Boolean) : AutomationAction   // 应用冻结
    data class RestrictBattery(val pkg: String, val mode: BatteryMode) : AutomationAction  // 后台管控
    data object LockScreen : AutomationAction
    data object GoHome : AutomationAction
    data class Screenshot(val saveTo: String) : AutomationAction
    data class RunCommand(val cmd: String) : AutomationAction   // 走真 Linux
}
```

---

## 2. 安卓系统能力接入：Shizuku / ADB 路径

这是安卓相对 iOS 的**最大优势**，也是需求 4 的核心。

### 2.1 四级权限阶梯（必须按级降级，绝不能卡死）

| 级别 | 手段 | 能做什么 | 获取方式 |
|---|---|---|---|
| **L4 完整** | Shizuku（无线调试 / 半边 ADB） | 应用冻结、后台管控、免 root 装包、跨应用读状态 | 用户在无线调试里启动一次 |
| **L3** | Shizuku（USB ADB） | 同上，稳定 | USB 连接 + 弹窗授权 |
| **L2** | 无障碍服务（AccessibilityService） | 界面自动化、模拟点击、读取当前界面 | 设置里手动开 |
| **L1 降级** | 普通权限 | 只能做 App 自身的事 | 正常弹窗 |

**关键设计：`AutomationExecutor` 按能力自动降级，用户永远能看到 App 能做什么。**

```kotlin
class AutomationExecutor(private val bridge: PlatformBridge) {

    /** 探测当前最高可用级别 */
    suspend fun probe(): CapabilityLevel = when {
        Shizuku.isReady() && Shizuku.hasPermission() -> CapabilityLevel.FULL_SHIZUKU
        AccessibilityManager.isServiceEnabled() -> CapabilityLevel.ACCESSIBILITY
        else -> CapabilityLevel.BASIC
    }

    /**
     * 执行一个动作。**任何一级失败都必须优雅降级，绝不抛给 UI**。
     * @return 结果里带 `degradedTo`，UI 据此提示用户「要开启 XX 才能做这件事」
     */
    suspend fun exec(action: AutomationAction): AutomationResult {
        return when (probe()) {
            CapabilityLevel.FULL_SHIZUKU -> execViaShizuku(action)
            CapabilityLevel.ACCESSIBILITY -> execViaAccessibility(action)
            CapabilityLevel.BASIC -> execViaBasic(action)
        }
    }
}
```

### 2.2 对标 iOS 的 10 个 AppIntent

| iOS AppIntent | 安卓实现 | 权限级别 |
|---|---|---|
| `ReportBatteryIntent` | Shizuku `dumpsys battery` / 普通 BatteryManager | L1 即可 |
| `ReportLocationIntent` | 定位权限（前台服务） | L1 |
| `TellAevisIntent` | 悬浮窗 / 通知栏快捷操作 | L2 |
| `ReportDeviceInfoIntent` | Shizuku `getprop` | L4 → L1 降级 |
| `OpenAevisIntent` | `PackageManager.getLaunchIntentForPackage` | L1 |
| `OpenCallIntent` | TelecomManager 拨号 | L1 |
| `OpenListenIntent` | DeepLink | L1 |
| `AskDailyIntent` | 通知栏 Action | L2 |
| `ReportHealthIntent` | Health Connect API | L1 |
| `ReportScreenTimeIntent` | UsageStatsManager（需 L2 无障碍） | L2 → L4 降级 |

⚠️ **安卓独有的三项能力**（iOS 做不到，安卓能做 —— 这是安卓端的核心卖点）：

- **应用冻结**：`pm disable-user`（需 Shizuku）—— 比 iOS 强得多
- **后台管控**：`cmd appops set ... RUN_IN_BACKGROUND ignore`
- **免 root 装包**：`pm install` via Shizuku

---

## 3. 插件层：真 Linux + `.capk` 插件包

### 3.1 沙箱方案对标

| | iOS | 安卓 |
|---|---|---|
| 运行时 | iSH（Alpine，静态链接） | **proot + Termux** |
| 发行版 | Alpine | Alpine（Termux 的 proot-distro） |
| 包管理 | `apk` | `apk`（同 Alpine） |
| 启动 | 进程内 | 前台服务 + `PRoot` |
| 成本 | 需要编静态库（`ish-sandbox.yml`） | 开箱即用，只需下载 rootfs |

**关键：两端都是 Alpine ⇒ 同一个插件包在两端都能跑。** 这是选 Alpine 不是 Debian 的原因。

### 3.2 插件包规范 `.capk`

```
my-plugin.capk                 # zip 包
├── manifest.json              # 元信息（必填）
├── entry.sh                   # 入口脚本（必填）
├── lib/                       # 依赖库
├── assets/                    # 静态资源
└── README.md                  # 给用户看的说明
```

`manifest.json` 契约：

```json
{
  "id": "netease.listen-together",
  "name": "网易云一起听",
  "version": "1.2.0",
  "minAppVersion": "1.0.0",
  "author": "aevis",
  "description": "和 ta 一起听歌，自动建房同步进度",
  "entry": "entry.sh",
  "runtime": "alpine",
  "permissions": ["network", "music_bind", "listen_room"],
  "capabilities": {
    "listen_create": true,
    "listen_sync": true,
    "listen_message": true
  },
  "resources": {
    "netease": "https://aevis.cn/plugins/netease-crypto.so"
  }
}
```

⚠️ **`permissions` 必须走白名单校验**，不能让插件随便申请。
iOS 端 `CapabilitySpec` 已经把能力分成 14 类，安卓端沿用同一套分类，
插件只能申请这 14 类里已启用的子集 —— 这也是**安全要求**（密钥/凭据不下发到插件）。

### 3.3 示例能力清单

| 插件 | 用到的能力 | 说明 |
|---|---|---|
| 网易云一起听 | `music_bind` `listen_*` `network` | 建房、同步进度、一起看 |
| 网易云一起看 | `network` `listen_room` | 同步播放位置 |
| AI 日记 | `diary` | 写/读日记，提醒 |
| 经期提醒 | `calendar` | 周期计算、提醒推送 |
| jogging 提醒 | `calendar` `location` | 定时 + 位置触发 |
| 浏览器自动化 | `browser` | 复用现有 `BrowserSession` 逻辑 |
| 系统工具箱 | `system` | 应用锁、应用冻结、后台管控 |
| 快捷指令 | `system` | 对标 iOS 的 AppIntent |

---

## 4. 跨端一致性的工程化手段

需求 1 说「两端 UI 与交互保持同步」，这不能靠自觉，得靠机制。

### 4.1 UI 一致性校验（CI 强制）

```bash
# tools/check_ui_parity.py —— CI 必跑，不过就红
1. 主题色：两端 accentPalette 第一个值必须相同（当前 #3f9d90）
2. 玻璃材质参数：模糊半径/高光透明度/描边渐变两端一致
3. 圆角与间距：spacing token 表逐项比对
4. 文案：同一功能的文案字符串比对（从共享 L1 取，两端不应各写一份）
5. 截图比对：同一 seed 的模拟器/模拟器截图做像素级 diff
```

⚠️ **截图比对要留容差**（如每通道 ±2），否则不同渲染引擎的抗锯齿会天天误报。

### 4.2 接口契约测试

- **后台是唯一真相源**：`ruoyi-lite` 导出 OpenAPI 3 规格（`/v1/openapi.json`）
- KMP 的 `expect/actual` 网络层按规格生成，改后台就会编译失败
- **契约测试跑在 CI**：每次发版对比 68 个接口的请求/响应结构有无漂移

### 4.3 功能对等清单（机器可校验）

把 iOS 的 27 个功能模块列成 `features.yaml`，每项标两端状态：

```yaml
- id: chat
  name: 聊天
  ios: done          # done | partial | todo
  android: todo
- id: listen_together
  name: 一起听
  ios: done
  android: todo
# ... 共 27 项
```

**CI 规则**：`ios: done` 但 `android: todo` 且已过承诺日期 → **构建失败**。
这比任何周会都管用。

### 4.4 防止「安卓偷偷简化」

需求 1 说「不做删减」。所以：

- 每个功能的**验收标准由 iOS 现状反推**，不是新设计
- 安卓实现完成后，跑一遍**同一份功能测试用例**（存在 L1，两端共用）
- 任何「安卓做不了这个」的项，必须在 `features.yaml` 里写明**原因**和**iOS 侧对应做法**，
  不能默默留空

---

## 5. 可靠性：容错、降级、错误上报

需求 6 明确「不允许崩溃或功能异常」。

### 5.1 三条铁律

1. **崩溃白名单**：整个 App 崩溃必须是 0。CI 里任何一次崩溃都阻断发布。
2. **降级可见**：任何降级都在 UI 上明确告诉用户，不静默。
3. **上报必有兜底**：上报失败要本地落盘，不能因为上报把 App 带崩。

### 5.2 具体机制

| 机制 | 做法 |
|---|---|
| 全局崩溃捕获 | `Thread.setDefaultUncaughtExceptionHandler`，写入本地队列 + 下次启动上报 |
| 协程兜底 | `CoroutineExceptionHandler` 统一捕获，不让异常冒泡到 UI |
| 网络重试 | 指数退避 3 次，超时 30s；失败转「离线模式」而不是报错页 |
| 沙箱崩溃隔离 | 插件跑在**独立进程**，崩了只杀插件进程，不带崩主进程 |
| Shizuku 掉线 | 监听 binder death，自动降级到 L2 并提示重新授权 |
| 权限缺失引导 | `PermissionState` 三态（已授权/可申请/永久拒绝），永久拒绝给「去设置」按钮 |
| 错误上报 | `DiagUploader`（iOS 已有）安卓版对齐，上报前**脱敏**（见 5.3） |

### 5.3 上报脱敏（硬性要求）

需求 5 说「密钥与凭据一律不得出现在前端代码、页面、日志或文档中」。
上报前必须过一遍脱敏：

```kotlin
object Redactor {
    private val patterns = listOf(
        Regex("""sk-[A-Za-z0-9]{16,}"""),                  // OpenAI 风格 Key
        Regex("""av-[a-f0-9]{32,}"""),                     // 本平台 api_key
        Regex("""(?i)(password|pwd|token|secret|apikey)\s*[=:]\s*\S+"""),
        Regex("""Bearer\s+[A-Za-z0-9\-._~+/]+=*"""),
        Regex("""1[3-9]\d{9}""")                           // 手机号
    )
    fun scrub(s: String): String = patterns.fold(s) { acc, r ->
        acc.replace(r) { "[REDACTED]" }
    }
}
```

⚠️ 脱敏要在**上报之前**做，不是之后。日志文件本身也要过一遍。

---

## 6. 分阶段实施计划

### 阶段 0：地基（1-2 周）

- 建安卓工程骨架（Kotlin + Compose + KMP 模块结构）
- 后台导出 OpenAPI 3 规格
- **L1 骨架**：协议模型 + 鉴权（登录令牌直连，不填 Key）
- CI：契约测试 + 功能对等清单校验

**出口标准**：安卓能登录、能看到余额、能看到充值记录。

### 阶段 1：核心聊天（3-4 周）

- L1 重写：`ChatStore` / `Persona` / `ChatMessage` 状态机
- 安卓聊天页 + 人设页 + 设置页（含主题色、玻璃材质）
- 一起听（复用 `ListenService` 逻辑）
- 计费打通：0.001 元/条，余额不足有明确提示

**出口标准**：能完整聊天，人设/主题/气泡与 iOS 一致，截图 diff 通过。

### 阶段 2：系统能力（2-3 周）

- Shizuku 接入（无线调试 + USB 两条路径）
- 无障碍服务（降级路径）
- `AutomationExecutor` 四级降级阶梯
- 对标 10 个 AppIntent
- **安卓独有能力**：应用冻结、后台管控、免 root 装包

**出口标准**：Shizuku L4 下全部自动化动作可用，断开能优雅降级。

### 阶段 3：插件层（2-3 周）

- proot + Termux 沙箱接入
- `.capk` 插件规范定稿 + 校验器
- 插件商店 UI + 安装流程
- 首批插件：网易云一起听/一起看、AI 日记、经期提醒、jogging 提醒

**出口标准**：同一个 `.capk` 在 iOS 和安卓都能装能跑。

### 阶段 4：通话与打磨（2 周）

- `SystemCallCenter` 安卓版（TelecomManager）
- 录屏/看屏幕（MediaProjection）
- 崩溃率压到 0，全部降级路径走查

---

## 7. 风险点

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| 1 | **L1 用 KMP 重写，iOS 端要动** | 3-5 人周，且可能引入回归 | 严格按模块切，一次一个模块；每切一个跑一次 iOS 的截图自检 |
| 2 | **Shizuku 在国产 ROM 上不稳**（小米/华为后台杀） | 自动化能力不可用 | 四级降级已有；加「保活引导」；必要时提示用户用 L2 无障碍 |
| 3 | **proot 在部分机型上性能差/被杀** | 插件跑不起来 | 插件独立进程 + 前台服务通知；沙箱不可用时降级为「无插件模式」 |
| 4 | **iOS 的 `.capk` 与安卓格式统一** | 插件生态分裂 | 格式一开始就定死同一份 spec，两端各自实现 loader |
| 5 | **68 个接口的契约漂移** | 安卓联调时集体返工 | 先出 OpenAPI 规格 + 契约测试，**这一步不能跳** |
| 6 | **「功能对等」变成无限工期** | 项目拖死 | `features.yaml` 里明确哪些是 P0/P1/P2；P2 可延后但**不许默默不做** |
| 7 | **隐私合规**（健康数据、位置、屏幕使用时间） | 上架被拒 / 用户投诉 | 权限按需申请、逐项说明用途；健康数据走 Health Connect 官方通道 |
| 8 | **应用冻结被厂商 ROM 干扰** | 功能时灵时不灵 | 每次执行后校验实际状态，失败给明确提示而不是假装成功 |

---

## 8. 立即可做的第一步

安卓端还没开工，建议从**阶段 0 的「后台导出 OpenAPI 3 规格」**开始 ——
这是唯一一件**做错了会让后面全部返工**的事，且不依赖安卓工程。

这件事可以直接在 `ruoyi-lite` 里加一个 `/v1/openapi.json` 路由，
把 68 个接口的请求/响应结构导出成机器可读的规格。

---

## 附：本文档对应的实测依据

| 结论 | 怎么得到的 |
|---|---|
| iOS 341 文件 / Core 102 个 / 27 模块 | `git/trees/main?recursive=1` 实测 |
| `aevisGlass` 58 文件 203 处 | `GlassSurface.swift` 注释记录的历史事故 |
| 14 类工具 | `CapabilitySpec.swift` 的 `switch` 实读 |
| 10 个 AppIntent | `AppShortcuts.swift` 实读 |
| 68 个 `/v1` 接口 | 服务器上 `grep -cE "@app\.(get\|post)\('/v1"` |
| 按条 0.001 元 | `MICRO=1000000` → 1000 micro，已实测扣费 |