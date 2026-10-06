import SwiftUI
import UIKit

// =============================================================================
//  她的小手机 —— 点开一个 App 之后的那一页（HerAppLaunchPage）
// =============================================================================
//
//  老板 2026-10 的原话：
//    · 「他的小手机是跟真的手机一样，点开 APP 之后有很多操作逻辑」
//    · 「它里面还要内置一个真实的浏览器」
//    · 「百度网盘是真的百度网盘」
//
//  这一页只做一件事：拿到一个 `HerApp`，按它的 `surface` 分流到对应的一屏。
//
//  ⚠️ 它**不自己起 NavigationStack** —— 外层的 `HerPhoneView` 已经有一个，
//     二级页统一靠 `NavigationLink(destination:)` 往下推（也不用 `.sheet`）。
//
//  🔴 这个产品有一条红线：**不许造假数据**。
//     能真拿到的就用真的（网盘走 `BaiduPanClient`、钱包走 `WalletStore`、
//     聊天走 `ChatStore`、朋友圈走 `MomentStore`、音乐走 `MusicPlayer` /
//     `NeteaseClient`）；拿不到的**老实说没有**（`ContentUnavailableView`）——
//     绝不编几个文件名、几条动态来撑场面。
// =============================================================================

/// 点开她手机上一个 App 之后的那一页。按 `app.surface` 内部分流。
struct HerAppLaunchPage: View {

    /// 这次点开的那个 App。
    private let app: HerApp

    init(app: HerApp) {
        self.app = app
    }

    /// 这个 App 该走哪种面。
    /// `app.surface` 为空（老存档）就按 id 去目录里查默认面。
    private var surface: HerAppSurface {
        app.surface ?? HerAppCatalog.surface(forID: app.id)
    }

    var body: some View {
        Group {
            switch surface {
            case .herChat(let platform):
                HerChatAppPage(app: app, platform: platform)
            case .herWallet:
                HerWalletAppPage(app: app)
            case .herNetdisk:
                HerNetdiskAppPage(app: app)
            case .herPhotos:
                HerPhotosAppPage(app: app)
            case .herMusic:
                HerMusicAppPage(app: app)
            case .herMap:
                HerMapAppPage(app: app)
            case .herMoments:
                HerMomentsAppPage(app: app)
            case .browser(let url):
                // 真 WebKit 内核、真上网、登录态持久 —— 这就是老板要的「真实的浏览器」。
                InAppBrowserView(start: url, title: app.name)
            case .externalApp(let scheme):
                HerExternalAppPage(app: app, scheme: scheme)
            case .generic:
                HerGenericAppPage(app: app)
            }
        }
        .background(AevisBackground())
    }
}

// MARK: - 共用小工具

/// 这一屏里到处要用的「多久以前」。
private enum HerAppLaunchFormat {

    /// 把时间揉成一句人话：刚刚 / N 分钟前 / N 小时前 / N 天前 / M-d HH:mm。
    static func relative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        if elapsed < 86400 * 7 { return "\(Int(elapsed / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M-d HH:mm"
        return formatter.string(from: date)
    }
}

/// 区块小标题，跟其它页面一个口径。
private struct HerAppSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.aevis(11.5))
            .foregroundStyle(.secondary)
    }
}

// MARK: - 微信 / QQ

/// `ChatMessage.source` 里用的通道 key —— 和 `HerChatPlatform.rawValue` 是**同一套**
/// （`"wechat"` / `"qq"`）。微信页 / QQ 页各自按它过滤，只看本平台的消息。
fileprivate extension HerChatPlatform {
    var sourceKey: String { rawValue }
}

/// 「微信 / QQ」—— 她的会话列表 + 只读聊天记录。
///
/// 数据源是**真的** `ChatStore`，但**按通道分开**：微信页只看 `source == "wechat"`
/// 的消息，QQ 页只看 `source == "qq"` 的 —— 两边不再共用同一份内容，
/// 也不再混进「App 里自己聊的」（那些 `source == nil`）。
private struct HerChatAppPage: View {

    let app: HerApp
    let platform: HerChatPlatform

    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var settings = AppSettings.shared

    /// 只看本平台的消息（微信 / QQ 各看各的）。
    private var messages: [ChatMessage] {
        chat.messages.filter { $0.source == platform.sourceKey }
    }

    private var title: String { platform == .qq ? "QQ" : "微信" }
    private var tint: Color { platform == .qq ? Color.blue : Color.green }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    HerChatLogPage(platform: platform)
                } label: {
                    sessionRow
                }
                .buttonStyle(.plain)

                Text(footnote)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openRealApp()
                } label: {
                    Label("在真 App 里打开", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    /// 列表里那一条会话 —— 「和你」。
    private var sessionRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint)
                Image(systemName: "person.fill")
                    .font(.aevis(18, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("和你")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.aevis(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .contentShape(Rectangle())
        .aevisGlass(cornerRadius: 16)
    }

    /// 底下那行说明 —— **如实**：微信这条目前只有「你在微信里发给 ta 的」，
    /// QQ 那条是双向的，别把没接上的功能说成接上了。
    private var footnote: String {
        if platform == .qq {
            return "这里显示你和 ta 在「\(app.name)」里互发的消息（去设置里开了 QQ 通道后开始记）。"
        }
        return "这里显示你在「\(app.name)」里发给 ta 的消息（扫码绑定后开始记）。"
    }

    /// 副标题：本平台最后一条消息的摘要 + 时间。
    private var subtitle: String {
        guard let last = messages.last(where: {
            !$0.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return emptySubtitle
        }
        return "\(last.previewText) · \(HerAppLaunchFormat.relative(last.date))"
    }

    /// 一条消息都没有时，副标题说清是「还没绑定」还是「绑了还没收到」。
    private var emptySubtitle: String {
        if platform == .qq {
            return settings.qqBridgeEnabled ? "还没有收到消息" : "还没开 QQ 通道"
        }
        return settings.weChatBotToken.isEmpty ? "还没绑定微信机器人" : "还没有收到消息"
    }

    /// 用系统去开**真的**微信 / QQ。
    private func openRealApp() {
        let scheme = platform == .qq ? "mqq://" : "weixin://"
        guard let url = URL(string: scheme) else { return }
        // ⚠️ 直接 open，不要先 `canOpenURL` 判断后再决定开不开 ——
        //    没装那个 App 就什么都不发生（不弹错误）。
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// 只读的聊天记录 —— 只画气泡，**不做输入框**，也**不去动** `ChatStore`。
private struct HerChatLogPage: View {

    let platform: HerChatPlatform

    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private var title: String { platform == .qq ? "QQ" : "微信" }

    /// 本平台有内容的那些消息，最新的 80 条。
    private var visibleMessages: [ChatMessage] {
        let list = chat.messages.filter { $0.source == platform.sourceKey }.filter {
            !$0.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(list.suffix(80))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if visibleMessages.isEmpty {
                    emptyState
                } else {
                    ForEach(visibleMessages) { message in
                        bubble(message)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 空状态 —— **说人话**：分清「还没绑定」和「绑了但还没收到消息」，
    /// 而不是一句「还没有聊过」糊过去（那会让人以为功能坏了）。
    private var emptyState: some View {
        Text(emptyText)
            .font(.aevis(13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.top, 30)
    }

    private var emptyText: String {
        switch platform {
        case .wechat:
            if settings.weChatBotToken.isEmpty {
                return "还没绑定微信机器人。绑定之后，你在微信里发给 ta 的消息会出现在这里。"
            }
            return "已经绑定了，还没收到消息。你在微信里给 ta 发一条试试。"
        case .qq:
            if settings.qqBridgeEnabled {
                return "QQ 通道开着。你和 ta 在 QQ 里的消息会出现在这里。"
            }
            return "还没开 QQ 通道。去「设置」里打开 QQ 通道，之后你们在 QQ 里的消息会出现在这里。"
        }
    }

    /// 一条只读气泡。`ta` 的话在左、我的话在右。
    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.role == .user
        return HStack(spacing: 8) {
            if mine { Spacer(minLength: 40) }

            Text(line(message))
                .font(.aevis(14))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(mine ? 0.10 : 0.06))
                        .allowsHitTesting(false)
                )

            if !mine { Spacer(minLength: 40) }
        }
    }

    /// 这条消息显示成什么 —— 优先用 `previewText`（图片 / 转账 / 语音都能说清）。
    private func line(_ message: ChatMessage) -> String {
        let preview = message.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? message.text : preview
    }
}

// MARK: - 支付宝 / 钱包

/// 「支付宝」—— 读**真的** `WalletStore`，列 ta 那张卡上的流水。拿不到就老实说。
private struct HerWalletAppPage: View {

    let app: HerApp

    @ObservedObject private var wallet = WalletStore.shared

    /// ta 那张卡上的进出账（`side == "her"`）。
    /// 老流水没有 `side` 的一律算「我的」，不混进来 —— 免得看着像 ta 的钱。
    private var herEntries: [WalletStore.Entry] {
        wallet.entries.filter { $0.side == "her" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                balanceCard

                HerAppSectionLabel("账单流水")

                if herEntries.isEmpty {
                    Text("这张卡上还没有进出账。")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(herEntries.prefix(30))) { entry in
                        statementRow(entry)
                    }
                }

                Text("数据来自这台设备上的钱包（\(Pronoun.current)的卡）。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Pronoun.current)的卡")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
            Text(WalletStore.money(wallet.taBalance))
                .font(.aevis(26, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .aevisGlass(cornerRadius: 18)
    }

    private func statementRow(_ entry: WalletStore.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.delta > 0 ? "arrow.down.left" : "arrow.up.right")
                .font(.aevis(12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.note)
                    .font(.aevis(13.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(WalletStore.shortTime(entry.date))
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Text(WalletStore.signedMoney(entry.delta))
                .font(.aevisMono(13.5))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .aevisGlass(cornerRadius: 14)
    }
}

// MARK: - 百度网盘

/// 「百度网盘」—— **真网盘**。登录了就列真文件；没登录就老实说，并给一个浏览器入口。
private struct HerNetdiskAppPage: View {

    let app: HerApp

    /// 有没有连上百度网盘（`BaiduPanClient` 看的是真实授权态）。
    @State private var authorized = BaiduPanClient.shared.isAuthorized

    var body: some View {
        Group {
            if authorized {
                HerNetdiskBrowseView(dir: "/", isRoot: true)
            } else {
                notConnected
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openRealApp()
                } label: {
                    Label("用真 App 打开", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .onAppear {
            authorized = BaiduPanClient.shared.isAuthorized
        }
    }

    /// 没登录时的诚实状态 + 一个真·浏览器入口。
    private var notConnected: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "还没连接网盘",
                systemImage: "cloud",
                description: Text("这台设备上的百度网盘还没登上账号，所以看不到真实文件 —— 这里不编一个出来。")
            )

            NavigationLink {
                InAppBrowserView(start: URL(string: "https://pan.baidu.com"), title: "百度网盘")
            } label: {
                Text("在浏览器里打开网盘")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .aevisGlass(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// 用系统去开**真的**百度网盘 App。
    private func openRealApp() {
        guard let url = URL(string: "bdnetdisk://") else { return }
        // ⚠️ 直接 open；没装那个 App 就什么都不发生。
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// 网盘目录的加载状态。
private enum HerNetdiskPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}

/// 网盘目录浏览 —— 根目录和子目录用**同一个**视图。
/// 点文件夹就是往下再推一层（同一个 NavigationStack）。
private struct HerNetdiskBrowseView: View {

    let dir: String
    var isRoot: Bool = false

    @State private var files: [PanFile] = []
    @State private var phase: HerNetdiskPhase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LazyVStack(spacing: 8) {
                    switch phase {
                    case .loading:
                        ProgressView()
                            .padding(.top, 30)
                    case .failed(let text):
                        failureText(text)
                    case .loaded:
                        if files.isEmpty {
                            emptyText
                        } else {
                            ForEach(files) { file in
                                fileRow(file)
                            }
                        }
                    }
                }

                if isRoot, phase == .loaded {
                    Text("数据来自你账号里真实的百度网盘文件。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dir) {
            await load()
        }
    }

    /// 一行 —— 文件夹再推一层，文件就只是个一行。
    @ViewBuilder
    private func fileRow(_ file: PanFile) -> some View {
        if file.isDirectory {
            NavigationLink {
                HerNetdiskBrowseView(dir: file.path)
            } label: {
                row(file)
            }
            .buttonStyle(.plain)
        } else {
            row(file)
        }
    }

    private func row(_ file: PanFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                .font(.aevis(17))
                .foregroundStyle(file.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !file.detail.isEmpty {
                    Text(file.detail)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .aevisGlass(cornerRadius: 14)
    }

    private var pageTitle: String {
        if isRoot { return "百度网盘" }
        let name = dir.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "百度网盘" : name
    }

    private var emptyText: some View {
        VStack(spacing: 8) {
            Text("这个文件夹是空的。")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
            Text("数据来自你账号里真实的百度网盘。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 30)
    }

    private func failureText(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.aevis(28))
                .foregroundStyle(.tertiary)
            Text("现在取不到网盘内容")
                .font(.aevis(14, weight: .medium))
                .foregroundStyle(.primary)
            Text(text)
                .font(.aevis(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Text("这不是编的 —— 就是现在真的拿不到。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    /// 列一次目录。成功就画真文件，失败就把**真实原因**照实说出来。
    private func load() async {
        phase = .loading
        do {
            let list = try await BaiduPanClient.shared.list(dir)
            // 文件夹在前，其余按名字排 —— 跟真网盘一个习惯。
            files = list.sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name < right.name
            }
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 相机 / 相册

/// 「相机」—— App 里**没有**「她的照片」这种数据，所以是**诚实空状态**。
/// 不拿 App 自己的截图或 AppIcon 来充数。
private struct HerPhotosAppPage: View {

    let app: HerApp

    var body: some View {
        ContentUnavailableView(
            "相册还是空的",
            systemImage: "photo.on.rectangle.angled",
            description: Text("这里没有存 \(Pronoun.current) 拍过的照片 —— 不拿 App 自己的截图或图标来充数。")
        )
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 网易云音乐

/// 音乐区的加载状态。
private enum HerMusicPhase: Equatable {
    case loading
    case notLoggedIn
    case loaded
    case failed(String)
}

/// 「网易云音乐」—— 「正在听」来自 App 真正在放的那首（`MusicPlayer`），
/// 「最近在听」来自你网易云账号的真实播放记录（`NeteaseClient`）。
/// 拿不到就诚实说。
private struct HerMusicAppPage: View {

    let app: HerApp

    @ObservedObject private var player = MusicPlayer.shared

    @State private var recent: [MusicTrack] = []
    @State private var phase: HerMusicPhase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nowPlaying

                HerAppSectionLabel("最近在听")

                recentSection

                Text("「最近在听」来自你网易云账号的真实播放记录；「正在听」来自 App 里正在放的那首。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadRecent()
        }
    }

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Image(systemName: player.isPlaying ? "waveform" : "pause.circle")
                    .font(.aevis(20))
                    .foregroundStyle(Color.red)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("正在听")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                    Text(track.display)
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(14)
            .aevisGlass(cornerRadius: 16)
        } else {
            Text("现在没有在放歌。")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .notLoggedIn:
            Text("网易云还没登录，看不到「最近在听」—— 去「音乐」页登录一次就有了。")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Text(text)
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded:
            if recent.isEmpty {
                Text("最近播放是空的。")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { track in
                    trackRow(track)
                }
            }
        }
    }

    private func trackRow(_ track: MusicTrack) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.aevis(14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
        }
        .padding(12)
        .aevisGlass(cornerRadius: 14)
    }

    /// 拉「最近在听」。没登录就老实说，别装。
    private func loadRecent() async {
        guard NeteaseClient.shared.isLoggedIn else {
            phase = .notLoggedIn
            return
        }
        do {
            let tracks = try await NeteaseClient.shared.recentTracks(limit: 12)
            recent = tracks
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 高德地图

/// 「高德地图」—— 项目里**没有**存 ta 的位置，所以是**诚实说明**，
/// 并给一个真·浏览器入口。
private struct HerMapAppPage: View {

    let app: HerApp

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "不知道位置",
                    systemImage: "map",
                    description: Text("这台 App 里没有存 \(Pronoun.current) 的位置，所以不编一个地点出来。")
                )

                NavigationLink {
                    InAppBrowserView(start: URL(string: "https://www.amap.com"), title: "高德地图")
                } label: {
                    Text("在浏览器里打开地图")
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .aevisGlass(cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 朋友圈

/// 「朋友圈」—— `MomentsView` 自带 `NavigationStack`，**不能**在同一个栈里再推一层。
/// 所以这里退化成诚实说明 + 一行最新动态（数据是**真的** `MomentStore`）。
private struct HerMomentsAppPage: View {

    let app: HerApp

    @ObservedObject private var moments = MomentStore.shared

    /// 最新的一条（按时间挑，跟存储顺序无关）。
    private var latest: Moment? {
        moments.moments.max { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ContentUnavailableView(
                    "朋友圈要整页看",
                    systemImage: "photo.stack",
                    description: Text("朋友圈是一整页刷的，不能从这里单开一层。这里只给你看最新的一条。")
                )

                HerAppSectionLabel("最新一条")

                if let latest {
                    momentCard(latest)
                } else {
                    Text("还没有动态。")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func momentCard(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(moment.author.isMe ? "我" : "ta")
                    .font(.aevis(13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(HerAppLaunchFormat.relative(moment.createdAt))
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
            }

            if !moment.text.isEmpty {
                Text(moment.text)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 16)
    }
}

// MARK: - 唤起真 App

/// 用 URL scheme 去开**真的** App（如 `weixin://`）。
///
/// ⚠️ 手机里没装那个 App 时，`open` 会静默失败 —— 直接 pop 掉会显得像坏了，
///    所以这一页留着说明 + 一个「再试一次」。
private struct HerExternalAppPage: View {

    let app: HerApp
    let scheme: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: app.symbol)
                .font(.aevis(40))
                .foregroundStyle(.secondary)

            Text("正在用真 App 打开「\(app.name)」")
                .font(.aevis(15, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text("如果这台手机上没装那个 App，就不会有任何反应 —— 这不是坏了。")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Button {
                open()
            } label: {
                Text("再试一次")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .aevisGlass(cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            open()
        }
    }

    private func open() {
        guard !scheme.isEmpty, let url = URL(string: scheme) else { return }
        // ⚠️ 直接 open；失败就什么都不发生，别弹错误。
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

// MARK: - 兜底

/// 兜底页 —— 没有能在这里接着操作的东西，就看看 ta 最近在手机上做了什么。
/// 数据是**真的** `HerPhoneStore`。
private struct HerGenericAppPage: View {

    let app: HerApp

    @ObservedObject private var store = HerPhoneStore.shared

    /// 她最近的动作，新的在前。
    private var events: [HerPhoneEvent] {
        store.recentEvents(6)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(Pronoun.current)打开了\(app.name)")
                    .font(.aevis(16, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("这个 App 里没有能在这里接着操作的东西 —— 就看看 ta 最近在手机上做了什么。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HerAppSectionLabel("最近的动作")

                if events.isEmpty {
                    Text("还没有记录。")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        eventRow(event)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func eventRow(_ event: HerPhoneEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: HerPhoneStore.symbol(for: event.appName))
                .font(.aevis(15, weight: .medium))
                .foregroundStyle(HerPhoneStyle.tint(for: event.appName))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.action)
                    .font(.aevis(14))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(HerAppLaunchFormat.relative(event.at))
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            Text(event.appName)
                .font(.aevis(12))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .aevisGlass(cornerRadius: 14)
    }
}
