import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「这台设备」设置卡：显示设备码 + 看它绑没绑。
///
/// ## 这一版**只记录，不拦人**
/// 绑定的目的不是"锁住用户"，而是让卖家那边能算清"这个账号用在哪几台机器上"。
/// 所以 App **不会因为没绑定就不让用** —— 那种做法有个真实的副作用：
/// 用户在地铁里没信号、或者服务器临时挂了，他就进不去自己的聊天记录了。
///
/// 真要改成硬性拦截，得先想清楚断网时怎么办 —— 这是产品决定，不是技术决定。
struct DeviceCard: View {

    @Environment(\.openURL) private var openURL

    @State private var checking = false
    @State private var bound = false
    @State private var maskedAccount: String?
    @State private var problem: String?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("这台设备")

            codeRow
            rule
            statusRow
            rule
            actionRow

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if let problem {
                rule
                Text(problem)
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            rule
            Text("这串码是这台手机的身份证，重装 App 也不会变。\n"
                 + "绑定在网页上做：打开 \(Self.bindHost)，登录之后把它填进去。\n"
                 + "一个账号只能绑一台设备；换机要在同一个页面申请，一个账号一辈子只能申请一次。\n"
                 + "（这一版只是记录，不会因为没绑定就不让你用。）")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
        }
        .task { await check() }
    }

    private static let bindHost = AevisHosts.accountDomain + "/me"

    // MARK: - 行

    private var codeRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("设备码")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                Text(DeviceIdentity.pretty)
                    // 用项目自己的等宽字体：**等宽 + 跟着字号设置走**。
                    // 直接写 `.font(.system(size:))` 的话，用户调字号时这行不会变。
                    .font(.aevisMono(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button {
                copy()
            } label: {
                Text("复制")
                    .font(.aevis(13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppSettings.shared.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("绑定状态")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.aevis(14))
                    .foregroundStyle(bound ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if checking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                if let url = DeviceIdentity.bindPage { openURL(url) }
            } label: {
                Text(bound ? "去网页看 / 换机" : "去网页绑定")
                    .font(.aevis(15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppSettings.shared.accentColor)

            Spacer(minLength: 8)

            Button {
                Task { await check(manual: true) }
            } label: {
                Text(checking ? "检查中…" : "重新检查")
                    .font(.aevis(14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppSettings.shared.accentColor)
            .disabled(checking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var statusText: String {
        if checking && maskedAccount == nil && problem == nil { return "检查中…" }
        if bound {
            return maskedAccount.map { "已绑定到 \($0)" } ?? "已绑定"
        }
        return "还没绑定"
    }

    // MARK: - 动作

    /// 问服务器这张码绑出去没有。
    ///
    /// ⚠️ 这个接口**故意不需要登录**：绑定发生在网页上，App 这边没登录态；
    /// 而查询结果只有"绑没绑 + 一串打码邮箱"，没有任何可利用的信息。
    @MainActor
    private func check(manual: Bool = false) async {
        checking = true
        if manual { note = nil; problem = nil }
        defer { checking = false }

        guard let url = URL(string:
            AevisHosts.account("/api/device/lookup?device_id=\(DeviceIdentity.canonical)"))
        else {
            problem = "内部错误：设备码拼不出查询地址。"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                problem = "服务器没回正经东西。"
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard http.statusCode == 200 else {
                problem = "服务器说：\((json["message"] as? String) ?? "HTTP \(http.statusCode)")"
                return
            }
            bound = (json["bound"] as? Bool) ?? false
            maskedAccount = json["account"] as? String
            problem = nil
            if manual {
                note = bound ? "查到了，绑在你这个账号上。" : "还没绑 —— 去网页上填一下。"
            }
        } catch {
            // 断网是常事，**不弹红字吓人**：只说"没查到"，并保留上一次的结果
            problem = "没连上服务器（\(error.localizedDescription)）。不影响你正常用 App。"
        }
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = DeviceIdentity.pretty
        note = "复制好了，粘到网页的输入框里就行。"
        #endif
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
}
