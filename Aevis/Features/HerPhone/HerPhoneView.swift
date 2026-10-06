import SwiftUI

// MARK: - 小工具

/// 「ta 的小手机」相关的小工具。
enum HerPhoneStyle {

    /// App 名字 → 一个**稳定**的颜色（跨启动、跨设备都一样）。
    ///
    /// ⚠️ 不能用 `String.hashValue` —— Swift 的字符串哈希**每次启动都变**，
    ///    那样同一个 App 每次打开颜色都在跳。
    ///    用 unicode 标量求和当种子：简单、确定、够用。
    static func tint(for name: String) -> Color {
        let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(seed % 360) / 360.0
        return Color(hue: hue, saturation: 0.52, brightness: 0.96)
    }
}

// MARK: - 聊天里那条记录

/// 聊天里的「ta 在小手机上做了什么」—— 一张小卡片，气质跟着转账卡走。
///
/// 由 `ChatView` 在 `message.kind == .herPhone` 时渲染。
/// ⚠️ 故意**不复用** `MessageBubble`：那套是给全屏聊天页的正文气泡用的，
///    这里的语义是"一条事件"，画成普通气泡会让人以为 ta 真发了这么一句话。
struct HerPhoneBubble: View {
    let appName: String
    let action: String

    private var symbol: String { HerPhoneStore.symbol(for: appName) }
    private var tint: Color { HerPhoneStyle.tint(for: appName) }

    var body: some View {
        HStack(spacing: 0) {
            card
            Spacer(minLength: 36)
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.20))
                Image(systemName: symbol)
                    .font(.aevis(16, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("ta 的小手机")
                    .font(.aevis(10.5))
                    .foregroundStyle(.secondary)
                Text(line)
                    .font(.aevis(13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 240, alignment: .leading)
        .aevisGlass(cornerRadius: 14)
    }

    private var line: String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ta 动了动自己的小手机" : "ta 刚\(trimmed)"
    }
}

// MARK: - 那部假手机

/// 「ta 的小手机」—— 一部**虚拟的假手机**。
///
/// 老板 2026-10 的原话：
/// 「你还要弄一个对方的手机懂吗？就给对方弄一个小手机……看对方下的什么 APP。」
///
/// 这一页做三件事：
///  1. 画一部手机（外框 + 状态栏 + 灵动岛 + 屏幕）；
///  2. 上半屏列出 ta 装了哪些 App（点一下 = 进到那个 App 里面）；
///  3. 下半屏显示 ta 最近发来的几句话（简化的气泡，不是全屏聊天那套）。
///
/// 点某个 App 做两件事：**推进二级页**（`HerAppLaunchPage(app:)`，定义在 `HerAppPages.swift`），
/// 同时走 `HerPhoneStore.shared.logEvent(...)` 留痕（会落一条 `.herPhone` 聊天消息，
/// 所以回到聊天页就能看到「ta 刚打开了 淘宝」）—— 同一个 App 每次打开只留痕一次。
///
/// ⚠️ 入口由 **team-lead** 挂（在 `DiscoverView` 上）。这里只要保证
///    `HerPhoneView()` 能被直接构造、单独调起来就行。
struct HerPhoneView: View {

    @ObservedObject private var store = HerPhoneStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    // ⚠️ 这里**不要**再挂 `@ObservedObject private var settings = AppSettings.shared`：
    //    AppSettings 的 @Published 非常多（改任何设置都会 objectWillChange），
    //    挂了它 = 本视图跟着无关的设置变更反复重绘，而这台「小手机」是常驻大视图。

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// 二级页的**页面栈**：元素 = `HerApp.id`。整页**复用最外层那个** `NavigationStack`，
    /// 不再嵌套新的（嵌套 `NavigationStack` 会多出一层壳、返回按钮也乱）。
    @State private var path: [String] = []

    /// 本次打开期间**已经记过痕迹**的 App id —— 防止在桌面和二级页之间来回进出
    /// 把聊天里同一条「ta 打开了 X」刷屏。
    @State private var loggedAppIDs: Set<String> = []

    /// App 网格：4 列。
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var taName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "ta" : name
    }

    // MARK: - 视觉口径（纯白 / 纯黑，不渐变、不贴图）

    private var screenColor: Color { scheme == .dark ? .black : .white }

    private var bodyColor: Color {
        scheme == .dark
            ? Color(red: 0.17, green: 0.17, blue: 0.19)
            : Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    private var bezelStroke: Color {
        Color.white.opacity(scheme == .dark ? 0.14 : 0.20)
    }

    // MARK: - 主体

    var body: some View {
        NavigationStack(path: $path) {
            phoneScreen
                .background(AevisBackground().ignoresSafeArea())
                .navigationTitle("ta 的小手机")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: String.self) { id in
                    if let app = HerPhoneStore.shared.app(withID: id) {
                        // 二级页 = 全屏 APP：压在桌面那一屏**上面**，
                        // 顶到安全区，不被手机外壳那圈边距包着。
                        HerAppLaunchPage(app: app)
                    } else {
                        // 兜底：id 对不上（数据被清了）也绝不能白屏。
                        ContentUnavailableView("这个 App 不见了", systemImage: "questionmark.app")
                    }
                }
                .toolbar {
                    // ⚠️ 这个「关闭」关的是**整个 sheet**，保持不变。
                    //    点进二级页后系统自带的返回按钮会自己出现，这里不要自绘返回箭头。
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .aevisScreen("ta 的小手机")
        .onAppear { applyLaunchOptions() }
    }

    /// 桌面那一屏（手机外壳 + 说明）—— 二级页是压在它**上面**的另一页，
    /// 所以外壳那圈边距只属于桌面，不会箍住二级页。
    private var phoneScreen: some View {
        ScrollView {
            VStack(spacing: 16) {
                device
                hint
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 手机外壳

    private var device: some View {
        ZStack {
            // 机身
            RoundedRectangle(cornerRadius: 48, style: .continuous)
                .fill(bodyColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 48, style: .continuous)
                        .strokeBorder(bezelStroke, lineWidth: 1)
                )

            // 屏幕
            VStack(spacing: 0) {
                statusBar
                screenContent
            }
            .background(screenColor)
            .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
            .padding(9)
        }
        // 灵动岛压在屏幕顶端
        .overlay(alignment: .top) { island.padding(.top, 9 + 8) }
        .aspectRatio(9.0 / 19.5, contentMode: .fit)
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.55 : 0.16),
                radius: 20, x: 0, y: 12)
    }

    /// 顶部状态栏：时间 + 信号 / Wi-Fi / 电池。
    private var statusBar: some View {
        HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                Text(Self.clock.string(from: context.date))
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.aevis(11, weight: .medium))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// 灵动岛 —— 一个小胶囊。
    private var island: some View {
        Capsule(style: .continuous)
            .fill(Color.black)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .frame(width: 76, height: 21)
    }

    // MARK: - 屏幕内容

    private var screenContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                appGrid
                chatPreview
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
    }

    // MARK: 上半屏：ta 的 App

    private var appGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("ta 的 App")

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(sortedApps) { app in
                    appIcon(app)
                }
            }
        }
    }

    /// 渲染用的排序（⚠️ 只排**画出来的顺序**，不动 `store.apps` 本体）：
    /// `order == 0` 的（用户自己装的）排**最后**，其余按 `order` 升序，
    /// `order` 并列时再按 `installedAt` 升序。
    private var sortedApps: [HerApp] {
        store.apps.sorted { lhs, rhs in
            let lhsNew = lhs.order == 0
            let rhsNew = rhs.order == 0
            if lhsNew != rhsNew { return !lhsNew }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.installedAt < rhs.installedAt
        }
    }

    private func appIcon(_ app: HerApp) -> some View {
        Button {
            // ① 进这个 App 的二级页；
            // ② 同时留痕（`logEvent` 语义不变），但**同一次打开期间只记一次** ——
            //    否则在桌面和二级页之间来回进出会把聊天里同一条刷屏。
            path.append(app.id)
            if loggedAppIDs.insert(app.id).inserted {
                store.logEvent(appName: app.name, action: "打开了 \(app.name)")
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(iconTint(app))
                    Image(systemName: app.symbol)
                        .font(.aevis(20, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 50, height: 50)

                Text(app.name)
                    .font(.aevis(10.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("卸载", role: .destructive) { store.uninstall(id: app.id) }
        }
    }

    /// 图标底色：`app.accent` 有值就按语义色名取色；`nil` 时保持老的"按名字算色"。
    private func iconTint(_ app: HerApp) -> Color {
        guard let accent = app.accent else { return HerPhoneStyle.tint(for: app.name) }
        switch accent {
        case "green":  return .green
        case "blue":   return .blue
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "teal":   return .teal
        case "indigo": return .indigo
        case "gray":   return .gray
        default:       return HerPhoneStyle.tint(for: app.name)
        }
    }

    // MARK: - CI 截图旁路

    /// 截图自检用的启动直达（**只在 Debug 生效**）：`-aevisOpenHerApp=<id>`
    /// （如 `-aevisOpenHerApp=wechat` / `baidupan` / `browser`）直接进某个 App 的二级页。
    ///
    /// ⚠️ 和 `DemoSeed` / `DiscoverView` 的开关**一个写法**（`#if DEBUG` + 启动参数），
    ///    不然这些开关会被编进正式版。本机没有 Xcode，CI 截图是唯一能看见结果的眼睛，
    ///    所以「点进去」这一层必须能靠启动参数直接截到。
    /// ⚠️ 只有 `HerPhoneStore.shared.app(withID:)` 真能查到时才推 —— 演示数据里没有
    ///    这个 App 就别动，避免白屏。
    private func applyLaunchOptions() {
        #if DEBUG
        let prefix = "-aevisOpenHerApp="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
        else { return }
        let id = String(arg.dropFirst(prefix.count))
        guard !id.isEmpty, HerPhoneStore.shared.app(withID: id) != nil else { return }
        path = [id]
        #endif
    }

    // MARK: 下半屏：ta 发来的几句话

    private var chatPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("ta 发来的")

            if recentAssistant.isEmpty {
                Text("ta 还没说什么……")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(recentAssistant) { message in
                        miniBubble(message)
                    }
                }
            }
        }
    }

    /// ta 最近说的几条（**简化的气泡**，最多 6 条，新的在下面）。
    private var recentAssistant: [ChatMessage] {
        let list = chat.messages.filter {
            $0.role == .assistant
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(list.suffix(6))
    }

    private func miniBubble(_ message: ChatMessage) -> some View {
        HStack {
            Text(bubbleText(message))
                .font(.aevis(12))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Spacer(minLength: 30)
        }
    }

    private func bubbleText(_ message: ChatMessage) -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? message.previewText : trimmed
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.aevis(11))
            .foregroundStyle(.secondary)
    }

    // MARK: - 底下一行说明

    private var hint: some View {
        Text("点 ta 手机上的图标，能进到那个 App 里面看看 —— 聊天里也会多出一条「ta 刚打开了 …」。")
            .font(.aevis(11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }
}
