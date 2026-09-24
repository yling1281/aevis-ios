import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#endif

/// 把驱动里的那个 WKWebView 放到界面上。
struct DouyinWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 不用更新 —— WebView 是驱动自己持有的，这里只是把它贴到屏幕上
    }
}

/// 抖音网页版：在里面登录、刷，然后从底部点「点赞 / 评论」。
///
/// 设计上和别的功能不一样的地方：**评论的最后一下发送我没替你按**。
/// 评论发出去撤不回来，按设置里那条「高危操作要二次确认」，
/// 这一步留给人自己点更合理。
struct DouyinBrowserView: View {
    @ObservedObject private var driver = DouyinWebDriver.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var commentText = ""
    @State private var askingComment = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DouyinWebView(webView: driver.webView)
                    .overlay(alignment: .center) {
                        if !driver.isLoaded {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("正在打开抖音网页版…\n第一次要先在这里登录一次")
                                    .font(.aevis(12.5))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(18)
                            .aevisGlass(cornerRadius: 16)
                        }
                    }

                actionBar
            }
            .navigationTitle(driver.pageTitle.isEmpty ? "抖音网页版" : driver.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("进入首页") { driver.loadHome() }
                        .font(.aevis(14))
                }
                // 在页面上登录之后，凭据要**同步一份给接口那边** ——
                // 不然网页是登录状态、接口却还是未登录，两边不通。
                // 页面每次加载完也会自动同步一次，这个按钮是给「登完没跳转」的情况兜底。
                ToolbarItem(placement: .topBarTrailing) {
                    Button("同步登录态") { driver.harvestCookie(quiet: false) }
                        .font(.aevis(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .font(.aevis(14))
                }
            }
            .alert("写条评论", isPresented: $askingComment) {
                TextField("说点什么…", text: $commentText, axis: .vertical)
                Button("写进去") {
                    let text = commentText
                    Task { await driver.comment(text) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会填进抖音自己的评论框里。**发出去那一下你自己点**——撤不回来。")
            }
            .onAppear {
                if !driver.isLoaded { driver.loadHome() }
            }
        }
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Button {
                    Task { await driver.like() }
                } label: {
                    Label("点赞", systemImage: "heart")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .aevisGlass(cornerRadius: 13)
                }
                .disabled(driver.busy || !driver.isLoaded)

                Button {
                    commentText = ""
                    askingComment = true
                } label: {
                    Label("评论", systemImage: "bubble.right")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .aevisGlass(cornerRadius: 13)
                }
                .disabled(driver.busy || !driver.isLoaded)

                Button {
                    Task { await driver.submitComment() }
                } label: {
                    Label("发送", systemImage: "paperplane")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .aevisGlass(cornerRadius: 13)
                }
                .disabled(driver.busy || !driver.isLoaded)

                Spacer(minLength: 0)
            }

            if let status = driver.statusLine {
                Text(status)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(settings.douyinConfirmRisky
                     ? "评价和发送这类撤不回来的操作，最后一下都留给你自己点。"
                     : "你已经关掉了高危操作确认 —— 我会尽量替你点完。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Rectangle().fill(.bar))
    }
}
