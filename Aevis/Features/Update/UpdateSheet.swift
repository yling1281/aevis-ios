import SwiftUI
import WebKit

/// 更新弹窗：强制模式不可关闭；可选模式可「稍后」。
///
/// 文案刻意写明 iOS 的安装限制 —— 用户点「立即更新」后是跳到下载/OTA，
/// 而不是在 App 内自动装好。说清楚比让用户以为失败了要好。
struct UpdateSheet: View {
    @ObservedObject var center: AppUpdateCenter
    /// 品牌色走 `AppSettings.shared.accentColor` —— 项目里**没有** `\.theme`
    /// 这个 EnvironmentKey（`@Environment(\.theme)` 是我上一轮写错的，直接编译不过）。
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if let info = center.latest {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: info.force ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                        .font(.aevis(22))
                        .foregroundStyle(info.force ? Color.orange : settings.accentColor)
                    Text(info.force ? "需要更新后才能继续使用" : "有新版本可用")
                        .font(.aevis(17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }

                Text("当前 \(info.current)　·　最新 \(info.latest)")
                    .font(.aevis(13))
                    .foregroundStyle(Color.primary.opacity(0.6))

                if !info.notes.isEmpty {
                    ScrollView {
                        Text(info.notes)
                            .font(.aevis(14))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }

                Text(info.hasOTA
                     ? "将跳转到系统安装页完成更新。"
                     : "将下载安装包（.ipa）。iOS 不允许 App 自行安装，下载后请在「文件」中用签名工具安装。")
                    .font(.aevis(12))
                    .foregroundStyle(Color.primary.opacity(0.55))

                HStack(spacing: 12) {
                    if !info.force {
                        Button("稍后") { center.dismiss() }
                            .font(.aevis(15))
                            .foregroundStyle(Color.primary.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    Button {
                        center.openInstall()
                    } label: {
                        Text("立即更新")
                            .font(.aevis(15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(settings.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .interactiveDismissDisabled(info.force)
        }
    }
}

/// 协议查看器：优先显示服务端热更的 HTML；拉不到时回落到本地随包文本。
struct LegalDocView: View {
    let kind: String          // privacy | terms | sdk
    let title: String
    let fallback: String

    @Environment(\.dismiss) private var dismiss
    @State private var html: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let html, !html.isEmpty {
                    HTMLView(html: wrap(html))
                } else {
                    ScrollView {
                        Text(fallback)
                            .font(.aevis(14))
                            .lineSpacing(6)
                            .padding(20)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            if let r = await AppUpdateCenter.shared.legalHTML(kind) {
                html = r.html
            }
            loading = false
        }
    }

    /// 服务端返回的是正文片段，这里补一层极简样式，保证深色模式下可读。
    private func wrap(_ body: String) -> String {
        """
        <!doctype html><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          :root{color-scheme:light dark}
          body{font:16px/1.85 -apple-system,system-ui;margin:0;padding:18px 18px 40px;
               color:var(--fg,#1c1c1e);background:transparent;-webkit-text-size-adjust:100%}
          h1{font-size:21px;margin:0 0 8px}
          h2{font-size:16px;margin:26px 0 8px}
          p,li{font-size:15px;text-align:justify;color:inherit}
          ol{padding-left:20px}
          .meta{color:#8a8a8e;font-size:12.5px}
          table{width:100%;border-collapse:collapse;font-size:13px}
          th,td{border:1px solid rgba(128,128,128,.28);padding:8px;text-align:left;vertical-align:top}
          .note{margin-top:24px;padding:12px;border-radius:10px;background:rgba(128,128,128,.12);font-size:13px}
          @media (prefers-color-scheme:dark){ body{color:#e8e8ea} .meta{color:#9a9a9e} }
        </style>
        <body>\(body)</body>
        """
    }
}

/// 极简 WKWebView 包装（只读展示，禁止跳转）。
struct HTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: nil)
    }
}
