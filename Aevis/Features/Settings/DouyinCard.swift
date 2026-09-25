import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「抖音」设置卡片。
///
/// 说实话的地方：**写操作还没接**（点赞/评论/发布需要抖音的 a_bogus 签名）。
/// 所以这张卡片里：
/// - 能真的用的部分 —— 贴 Cookie、解析分享链接 —— 做真的；
/// - 不能用的部分 —— 明写「未接入」，并说明为什么，不做一个一定失败的按钮。
struct DouyinCard: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var editingCookie = false
    @State private var cookieDraft = ""
    @State private var note: String?
    @State private var working = false
    @State private var showBrowser = false

    private var client: DouyinClient { DouyinClient.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("抖音")

            HStack(spacing: 10) {
                Button {
                    cookieDraft = settings.douyinCookie
                    editingCookie = true
                } label: {
                    Text(client.isLoggedIn ? "换 Cookie" : "贴 Cookie 登录")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }

                if client.isLoggedIn {
                    Button {
                        settings.douyinCookie = ""
                        note = "已退出抖音登录。"
                    } label: {
                        Text("退出")
                            .font(.aevis(14))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)

            rule

            toggleRow(
                "高危操作要二次确认",
                subtitle: "评论、发布这类不可撤销的操作，先问你一次",
                isOn: $settings.douyinConfirmRisky
            )

            rule

            VStack(alignment: .leading, spacing: 10) {
                Text("现在能做到什么")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)

                bullet("解析分享链接", ok: true, detail: "把「复制打开抖音…」那段粘给\(Pronoun.current)，\(Pronoun.current)能说出里面是什么")
                bullet("打开抖音", ok: true, detail: "\(Pronoun.current)说一句就跳过去")
                bullet("点赞 / 评论", ok: true, detail: "走网页版：在 App 内的浏览器里驱动抖音自己的页面，签名由它自己算")

                HStack(spacing: 10) {
                    Button {
                        note = nil
                        showBrowser = true
                    } label: {
                        Label("打开抖音网页版", systemImage: "safari")
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }

                    Button(action: testParse) {
                        HStack(spacing: 7) {
                            if working {
                                ProgressView().controlSize(.small)
                            }
                            Text(working ? "解析中…" : "用剪贴板试一次")
                                .font(.aevis(14, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                    }
                    .disabled(working)

                    Spacer(minLength: 0)
                }

                Text("点赞和评论是在**这个浏览器里**完成的：第一次进去先登录一次（扫码或手机号），之后一直有效。抖音改版可能导致点不到按钮 —— 那种情况它会直接告诉你，不会假装成功。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note {
                    Text(note)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("这是逆向接入，没有官方接口 —— 抖音改协议就可能失效。Cookie 只存在这台手机的钥匙串里。**建议登录一个小号。**")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
        .sheet(isPresented: $showBrowser) {
            DouyinBrowserView()
        }
        .alert("抖音 Cookie", isPresented: $editingCookie) {
            TextField("sessionid=...; passport_csrf_token=...", text: $cookieDraft, axis: .vertical)
            Button("保存") {
                settings.douyinCookie = cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = settings.douyinCookie.isEmpty ? "已清空。" : "Cookie 已保存。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在浏览器里登录抖音后，从开发者工具里复制 Cookie 整串贴进来。")
        }
    }

    // MARK: - 动作

    private func currentClipboard() -> String {
        #if canImport(UIKit)
        return UIPasteboard.general.string ?? ""
        #else
        return ""
        #endif
    }

    private func testParse() {
        let text = currentClipboard()
        guard !text.isEmpty else {
            note = "剪贴板是空的。先把抖音的分享文案复制一下。"
            return
        }

        working = true
        note = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let share = try await client.resolve(text)
                note = "解析成功：\n\(share.summary)"
            } catch {
                note = error.localizedDescription
            }
        }
    }

    // MARK: - 零件

    private func bullet(_ text: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                .font(.aevis(13))
                .foregroundStyle(ok ? Color.green : Color.secondary)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.aevis(13.5))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

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

    private func toggleRow(_ text: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
