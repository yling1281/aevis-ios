import SwiftUI

/// 全 App 唯一的「扫一扫」入口。
///
/// 以前扫码散在三处：
///   · 加号菜单「扫一扫 · 配对电脑版」→ PairScanView
///   · 设置 → 分享与搬家 → 扫一扫 → 又一个
///   · 登录页 → ScanLoginView（扫码登录）
///
/// 现在统一走这里：底层用同一个 QRScannerView，扫到内容后按前缀分发，
/// 各业务只负责"拿到内容之后做什么"，不再各自实现一遍扫码界面。
///
/// 支持的载荷：
///   aevis://pair?code=XXXX      → 配对电脑版
///   aevis://persona?code=XXXX   → 人设分享
///   http:// / https://          → 内置浏览器
///   其他                        → 当纯文本，可复制
struct UniversalScanView: View {
    @Environment(\.dismiss) private var dismiss

    /// 业务方接住"扫到的东西"，返回 true 表示已处理（不再弹兜底提示）。
    var onPayload: (String) -> Bool = { _ in false }

    @State private var lastCode: String = ""
    @State private var hint: String = "把二维码放进框里"
    @State private var showManual: Bool = false
    @State private var manualCode: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { code in
                    handle(code)
                }
                .ignoresSafeArea()

                // 取景框
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: 240, height: 240)
                    Spacer()
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("扫一扫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("手输") { showManual = true }
                }
            }
            .sheet(isPresented: $showManual) {
                manualEntry
            }
        }
    }

    // MARK: - 分发

    private func handle(_ code: String) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastCode else { return }
        lastCode = text

        // 交给业务方先判断（比如配对要弹授权确认）
        if onPayload(text) {
            dismiss()
            return
        }

        // 兜底：按前缀自行处理
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            if let url = URL(string: text) {
                UIApplication.shared.open(url)
            }
            hint = "已在浏览器打开"
            dismiss()
            return
        }

        // 认不出来就显示出来，允许复制
        hint = text.count > 24 ? String(text.prefix(24)) + "…" : text
    }

    // MARK: - 手输

    private var manualEntry: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("粘贴或输入二维码里的内容")
                    .font(.system(size: 12))
                    .foregroundColor(Paper.inkMuted)

                TextField("aevis://...", text: $manualCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(12)
                    .background(Paper.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Paper.line, lineWidth: 1)
                    )

                Button {
                    let t = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    showManual = false
                    if !t.isEmpty { handle(t) }
                } label: {
                    Text("确定")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Paper.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundColor(Paper.onAccent)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(18)
            .background(Paper.bg.ignoresSafeArea())
            .navigationTitle("手动输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { showManual = false }
                }
            }
        }
    }
}
