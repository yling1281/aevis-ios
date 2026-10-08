import SwiftUI
import UIKit

/// 界面里反复用到的小零件 + 文案格式化。
enum Fmt {
    static func size(_ n: Int) -> String {
        if n <= 0 { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(n))
    }

    /// "2026-10-08T11:22:33" / "2026-10-08 11:22:33" → "10-08 11:22"
    static func time(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        var s = raw.replacingOccurrences(of: "T", with: " ")
        if let dot = s.firstIndex(of: ".") { s = String(s[s.startIndex..<dot]) }
        if s.count >= 16 {
            let start = s.index(s.startIndex, offsetBy: 5)
            let end = s.index(s.startIndex, offsetBy: 16)
            return String(s[start..<end])
        }
        return s
    }

    static func day(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        var s = raw.replacingOccurrences(of: "T", with: " ")
        if s.count >= 10 { s = String(s.prefix(10)) }
        return s
    }
}

/// 加载状态（每个页签自己一份）
enum LoadState: Equatable {
    case idle
    case loading
    case done
    case fail(String, Int)

    var isLoading: Bool { self == .loading }
}

/// 统一的「正在加载 / 出错」提示条
struct StateBanner: View {
    let state: LoadState
    var retry: (() -> Void)?

    var body: some View {
        switch state {
        case .fail(let msg, let code):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: code == -1 ? "wifi.slash" : "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg).font(.footnote).foregroundStyle(.primary)
                }
                if let retry {
                    Button("重试", action: retry).font(.footnote.weight(.semibold))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        default:
            EmptyView()
        }
    }
}

/// 键值一行（详情页/概览用）
struct KVRow: View {
    let k: String
    let v: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.footnote).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(v.isEmpty ? "—" : v)
                .font(mono ? .footnote.monospaced() : .footnote)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

/// 大数字卡片（概览）
struct BigStat: View {
    let label: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 小徽标（分类 / 状态）
struct Chip: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// 复制到剪贴板 + 一句提示（不弹系统 Toast，用一小条横幅）
///
/// ⚠️ 故意**不加 `@MainActor`**：下面 `ToastOverlay` 会在属性初始化里取 `.shared`，
///    加了主线程隔离在 Swift 5 语言模式下会直接编译不过
///    （"main actor-isolated static property can not be referenced from a non-isolated context"）。
///    实际调用点本来就都在主线程。
final class Toast: ObservableObject {
    static let shared = Toast()
    @Published var text: String = ""
    private var token = 0

    func show(_ msg: String) {
        text = msg
        token += 1
        let mine = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.token == mine else { return }
            self.text = ""
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject var toast = Toast.shared

    var body: some View {
        VStack {
            Spacer()
            if !toast.text.isEmpty {
                Text(toast.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: toast.text)
        .allowsHitTesting(false)
    }
}

func copyToPasteboard(_ text: String, what: String = "已复制") {
    UIPasteboard.general.string = text
    Toast.shared.show("\(what)：\(text.count > 42 ? String(text.prefix(42)) + "…" : text)")
}
