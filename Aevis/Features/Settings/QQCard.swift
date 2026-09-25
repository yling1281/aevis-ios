import SwiftUI

/// 「QQ 桥接」设置卡。
///
/// 为什么不是「登录 QQ」：QQ 没有官方个人接口，App 也没法自己登。
/// 通行做法是**在电脑上跑一个 OneBot 实现**（NapCat / LLOneBot / go-cqhttp），
/// 由它登录 QQ，对外开一个 HTTP 端口；手机连过去。
///
/// 所以这一页只有三样东西要填：**开关、地址、令牌**。
/// 账号密码全程不经过这个 App —— 这是有意的。
struct QQCard: View {

    @ObservedObject private var settings = AppSettings.shared

    @State private var showURL = false
    @State private var urlDraft = ""
    @State private var showToken = false
    @State private var tokenDraft = ""
    @State private var note: String?
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("QQ 桥接")

            switchRow
            rule
            urlRow
            rule
            tokenRow
            rule
            sendRow
            rule
            testRow

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if let result {
                rule
                Text(result)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            rule
            Text("QQ 是登在「一个一直开着的服务」上的，不是登在这台手机上。"
                 + "那个服务可以是你的服务器（公网地址，出门用 4G 也能连），"
                 + "也可以是家里的电脑（同一个 WiFi 时才好用）。\n"
                 + "最省事的是放服务器上 —— 手机在哪都能用，也不用一直开着电脑。\n"
                 + "先把 OneBot 实现（NapCat / LLOneBot / go-cqhttp 都行）跑起来，"
                 + "把它的 HTTP 地址和 Access Token 填到这里。账号密码不经过这个 App。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .aevisGlass(cornerRadius: 20)
        .alert("OneBot 服务地址", isPresented: $showURL) {
            TextField("https://你的域名 或 http://192.168.1.5:3000", text: $urlDraft)
            Button("保存") {
                settings.qqBridgeURL = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = settings.qqBridgeURL.isEmpty
                    ? "地址清空了，QQ 桥接就不会生效。"
                    : "记下了。点下面「测试连接」看看通不通。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("那个 OneBot 服务的地址。可以是公网地址（推荐，出门也能用），"
                 + "也可以是同一个 WiFi 下的电脑。要带 http:// 或 https://。")
        }
        .alert("Access Token", isPresented: $showToken) {
            TextField("留空表示没设令牌", text: $tokenDraft)
            Button("保存") {
                settings.qqBridgeToken = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = "令牌存进钥匙串了（不会外传）。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("OneBot 配置里的 Access Token。只存在这台手机的钥匙串里。")
        }
    }

    // MARK: - 各行

    private var switchRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("启用")
                    .font(.aevis(15))
                Text(settings.qqBridgeEnabled
                     ? "开着。她可以看和发你的 QQ 消息了"
                     : "关着。整块 QQ 功能都不生效")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.qqBridgeEnabled)
                .labelsHidden()
                .tint(settings.accentColor)
        }
    }

    private var urlRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("服务地址")
                    .font(.aevis(15))
                Text(settings.qqBridgeURL.isEmpty
                     ? "还没填。那个 OneBot 服务跑起来了吗？"
                     : settings.qqBridgeURL)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(settings.qqBridgeURL.isEmpty ? "去填" : "修改") {
                urlDraft = settings.qqBridgeURL
                showURL = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    private var tokenRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("Access Token")
                    .font(.aevis(15))
                Text(settings.qqBridgeToken.isEmpty
                     ? "没设令牌（如果服务端没开鉴权就不用填）"
                     : "已填（存在钥匙串里）")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(settings.qqBridgeToken.isEmpty ? "去填" : "修改") {
                tokenDraft = ""
                showToken = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    private var sendRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("允许替你发消息")
                    .font(.aevis(15))
                Text(settings.qqBridgeCanSend
                     ? "开着。她说要发的时候，是以你本人的身份发出去的"
                     : "关着。她只能看，不能替你说话")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.qqBridgeCanSend)
                .labelsHidden()
                .tint(settings.accentColor)
        }
    }

    private var testRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("测试连接")
                    .font(.aevis(15))
                Text("问一下那个服务「你现在登的是哪个号」")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(testing ? "测试中…" : "测试") { runTest() }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(testing || !QQBridge.shared.isConfigured)
        }
    }

    // MARK: - 动作

    private func runTest() {
        testing = true
        note = nil
        result = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                let login = try await QQBridge.shared.loginInfo()
                result = "通了。那个服务现在登的是 \(login.nickname)（\(login.userID)）。"
            } catch {
                result = "没通：" + error.localizedDescription
            }
        }
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
