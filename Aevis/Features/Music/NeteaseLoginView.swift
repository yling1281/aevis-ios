import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// 网易云登录：默认弹一张二维码，扫一下就登。
///
/// 用户 2026-10-31 定的登录方式（二维码打头）：
/// 1. 二维码（默认）—— 手机网易云 App 扫一下。
/// 2. 手机号 —— 跳到手机号登录页。
/// 3. 网易云音乐 App —— 系统唤起网易云 App（最佳努力，网易没有第三方 SSO，
///    所以这只是个便捷入口，真正的登录还是靠二维码 / Cookie / 网页版）。
/// 4. Cookie —— 自己贴一段 MUSIC_U。
/// 5. 网页版 —— 原来的整页浏览器，保底用。
struct NeteaseLoginView: View {
    @ObservedObject private var qr = NeteaseQRLogin.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss
    @State private var method: Method = .qr
    @State private var showCookie = false
    @State private var cookieDraft = ""

    enum Method: String, CaseIterable, Identifiable {
        case qr, phone, app, cookie, web
        var id: String { rawValue }
        var title: String {
            switch self {
            case .qr: "二维码"
            case .phone: "手机号"
            case .app: "网易云 App"
            case .cookie: "Cookie"
            case .web: "网页版"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("登录方式", selection: $method) {
                    ForEach(Method.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                ScrollView {
                    switch method {
                    case .qr: qrPane
                    case .phone: WebLoginPane(phone: true)
                    case .app: appPane
                    case .cookie: cookiePane
                    case .web: WebLoginPane(phone: false)
                    }
                }
            }
            .navigationTitle("登录网易云")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }.font(.aevis(14))
                }
            }
        }
        .onDisappear { qr.stop() }
        .alert("网易云 Cookie", isPresented: $showCookie) {
            TextField("MUSIC_U=...; 或整段 Cookie", text: $cookieDraft)
            Button("保存") {
                NeteaseClient.shared.setCookie(cookieDraft)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在浏览器里登录网易云音乐，开发者工具 → Application → Cookies，把 music.163.com 那一段整个复制过来。")
        }
    }

    // MARK: - 二维码（默认）

    private var qrPane: some View {
        VStack(spacing: 14) {
            if let image = qr.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if case .loadingKey = qr.status {
                ProgressView("正在生成二维码…")
            } else {
                Text("二维码没出来（weapi 通道可能被网易掐了）。用上面的「网页版」登录也行。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            qrStatusText

            if case .expired = qr.status {
                Button("刷新二维码") { qr.refresh() }
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .aevisGlass(cornerRadius: 14)
            }

            Text("用手机上的网易云音乐 App 扫这个码。扫完在手机上点「确认登录」就登进来了。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .onAppear { if qr.status == .idle { qr.start() } }
        .onDisappear { qr.stop() }
    }

    @ViewBuilder
    private var qrStatusText: some View {
        switch qr.status {
        case .idle, .loadingKey:
            EmptyView()
        case .waiting:
            Label("等扫码…", systemImage: "qrcode.viewfinder")
                .foregroundStyle(.secondary)
        case .scanned:
            Label("已扫码，在手机上点确认", systemImage: "checkmark.circle")
                .foregroundStyle(.orange)
        case .expired:
            Label("二维码过期了", systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
        case .loggedIn:
            Label("登录成功", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Text("出错：\(msg)")
                .foregroundStyle(.red)
                .font(.aevis(12))
        }
    }

    // MARK: - 网易云 App

    private var appPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("用网易云音乐 App 登录", systemImage: "music.note.app")
                .font(.aevis(15, weight: .medium))
            Text("点下面按钮，系统会尝试唤起你手机上的网易云音乐 App（装了的话）。网易没有面向第三方的登录授权，所以这只是个便捷入口——真正把账号登进 Aevis，还是用「二维码 / Cookie / 网页版」这几种。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                #if canImport(UIKit)
                let scheme = URL(string: "orpheus://")!
                if UIApplication.shared.canOpenURL(scheme) {
                    UIApplication.shared.open(scheme)
                } else {
                    UIApplication.shared.open(URL(string: "https://apps.apple.com/app/id590338362")!)
                }
                #endif
            } label: {
                Text("打开网易云音乐 App")
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .aevisGlass(cornerRadius: 14)
            }
            if NeteaseClient.shared.isLoggedIn {
                Label("当前已登录", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
    }

    // MARK: - Cookie

    private var cookiePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把浏览器里登录后的 Cookie 整段贴过来。自己控制账号、不走网页时用这个。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                cookieDraft = settings.neteaseCookie
                showCookie = true
            } label: {
                Text("贴 Cookie")
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .aevisGlass(cornerRadius: 14)
            }
            if NeteaseClient.shared.isLoggedIn {
                Text("Cookie 已存好（在钥匙串里，不会外传）。")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

/// 复用 NeteaseLogin 那个常驻 WKWebView，只是换不同的起始页。
struct WebLoginPane: View {
    let phone: Bool
    @ObservedObject private var web = NeteaseLogin.shared

    var body: some View {
        VStack(spacing: 0) {
            NeteaseWebView(webView: web.webView)
                .overlay(alignment: .center) {
                    if web.loading {
                        ProgressView()
                            .padding(18)
                            .aevisGlass(cornerRadius: 16)
                    }
                }
            if web.loggedIn {
                Label("已登录", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .padding(10)
            }
        }
        .onAppear {
            web.start()
            if phone { web.loadPhoneLogin() }
        }
        .onDisappear { web.stop() }
    }
}

/// 把登录用的 WKWebView 贴到屏幕上。
struct NeteaseWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // WebView 是 NeteaseLogin 自己持有的，这里只是让它上屏幕
    }
}
