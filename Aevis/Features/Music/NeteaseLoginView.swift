import SwiftUI
import WebKit

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

/// 网易云登录页。
///
/// 在这个页面上**正常登录一次**（扫码或手机号都行），登进去之后
/// App 自己去 cookie 存储里把凭据拿走 —— 用户不用复制任何东西。
struct NeteaseLoginView: View {

    @ObservedObject private var login = NeteaseLogin.shared

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NeteaseWebView(webView: login.webView)
                    .overlay(alignment: .center) {
                        if login.loading {
                            VStack(spacing: 9) {
                                ProgressView()
                                Text("正在打开网易云…")
                                    .font(.aevis(12.5))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(18)
                            .aevisGlass(cornerRadius: 16)
                        }
                    }

                statusBar
            }
            .navigationTitle("登录网易云")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("首页") { login.loadHome() }
                        .font(.aevis(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .font(.aevis(14))
                }
            }
            .onAppear { login.start() }
            .onDisappear { login.stop() }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            if login.loggedIn {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.aevis(13, weight: .medium))
                    Text("已登录")
                        .font(.aevis(13, weight: .medium))
                }
                .foregroundStyle(.green)
            }

            if let status = login.statusLine {
                Text(status)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Rectangle().fill(.bar))
    }
}
