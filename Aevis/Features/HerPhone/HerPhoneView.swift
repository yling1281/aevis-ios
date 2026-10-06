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
///  2. 上半屏列出 ta 装了哪些 App（点一下 = ta 打开了它）；
///  3. 下半屏显示 ta 最近发来的几句话（简化的气泡，不是全屏聊天那套）。
///
/// 点某个 App 会走 `HerPhoneStore.shared.logEvent(...)` ——
/// 那边会落一条 `.herPhone` 聊天消息，所以回到聊天页就能看到「ta 刚打开了 淘宝」。
///
/// ⚠️ 入口由 **team-lead** 挂（在 `DiscoverView` 上）。这里只要保证
///    `HerPhoneView()` 能被直接构造、单独调起来就行。
struct HerPhoneView: View {

    @ObservedObject private var store = HerPhoneStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

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
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    device
                    hint
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("ta 的小手机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .aevisScreen("ta 的小手机")
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
                ForEach(store.apps) { app in
                    appIcon(app)
                }
            }
        }
    }

    private func appIcon(_ app: HerApp) -> some View {
        Button {
            // 点一下 = ta 打开了这个 App。
            store.logEvent(appName: app.name, action: "打开了 \(app.name)")
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(HerPhoneStyle.tint(for: app.name))
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
        Text("点 ta 手机上的图标，就像 ta 真的打开了那个 App —— 聊天里会多出一条「ta 刚打开了 …」。")
            .font(.aevis(11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }
}
