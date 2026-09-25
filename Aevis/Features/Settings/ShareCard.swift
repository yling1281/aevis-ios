import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// 「分享与搬家」设置卡。
///
/// 两件事：
/// 1. **二维码传配置** —— 朋友的手机要能用，先得填接口地址、模型名、外观偏好。
///    生成一个码让他扫，比手输一遍快得多，也不会输错。
/// 2. **备份到文件** —— 换手机、重装 App 的时候，把整份数据导出成一个文件。
///    （传到百度网盘那条路在「百度网盘」那张卡里，两条并存，谁方便用谁。）
struct ShareCard: View {

    @ObservedObject private var settings = AppSettings.shared

    @State private var includeKey = false
    @State private var qrText = ""
    @State private var showQR = false
    @State private var showScanner = false
    @State private var showPaste = false
    @State private var pasteDraft = ""
    @State private var note: String?
    @State private var backupURL: URL?
    @State private var showImporter = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("分享与搬家")

            shareRow
            rule
            importRow
            rule
            exportRow
            rule
            restoreRow

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            rule
            Text("二维码里默认不带 API Key —— Key 是要花钱的东西，让别人填自己的。"
                 + "真要连 Key 一起给自己另一台设备，勾上那个「带 Key」开关，但别把码发给别人。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .aevisGlass(cornerRadius: 20)
        .sheet(isPresented: $showQR) { qrSheet }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { text in
                    showScanner = false
                    note = ConfigShare.apply(text)
                }
                .ignoresSafeArea()
                .navigationTitle("扫 Aevis 的配置码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("取消") { showScanner = false }
                    }
                }
            }
        }
        .alert("粘贴配置内容", isPresented: $showPaste) {
            TextField("把那段文本贴进来", text: $pasteDraft)
            Button("套用") { note = ConfigShare.apply(pasteDraft) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("扫不了码的时候用这个：让对方把生成页上那段文本发给你，粘进来一样能用。")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            handlePicked(result)
        }
    }

    // MARK: - 各行

    private var shareRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("把我的配置生成二维码")
                    .font(.aevis(15))
                Text(includeKey
                     ? "⚠️ 会连 API Key 一起带走，别把这个码发给别人"
                     : "只带接口地址、模型、外观这些，不带 Key")
                    .font(.aevis(11.5))
                    .foregroundStyle(includeKey ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                Toggle("带 Key", isOn: $includeKey)
                    .labelsHidden()
                    .tint(settings.accentColor)
                Button("生成") {
                    qrText = ConfigShare.snapshot(includeKey: includeKey)
                    if qrText.isEmpty {
                        note = "生成失败，配置读不出来。"
                    } else {
                        showQR = true
                    }
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
            }
        }
    }

    private var importRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("扫一个配置码")
                    .font(.aevis(15))
                Text("扫朋友给的那个码，接口和外观一次套好。扫不了也能粘贴文本。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                Button("扫一扫") { showScanner = true }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .disabled(!QRScannerView.isAvailable)
                Button("粘贴") {
                    pasteDraft = ""
                    showPaste = true
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
            }
        }
    }

    private var exportRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("备份到文件")
                    .font(.aevis(15))
                Text(backupURL == nil
                     ? "把联系人、聊天记录、记忆、朋友圈打成一个文件存出去"
                     : "已经打包好了，点右边「保存 / 分享」")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let backupURL {
                ShareLink(item: backupURL) {
                    Text("保存 / 分享")
                        .font(.aevis(14))
                        .foregroundStyle(settings.accentColor)
                }
            } else {
                Button("打包") { runExport() }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
        }
    }

    private var restoreRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("从文件恢复")
                    .font(.aevis(15))
                Text("会用文件里的内容覆盖本机现在的联系人、聊天记录、记忆和朋友圈")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("选文件") { showImporter = true }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(busy)
        }
    }

    // MARK: - 生成二维码

    private var qrSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(includeKey ? "这段配置里有你的 API Key" : "这段配置里没有 API Key")
                        .font(.aevis(13, weight: .medium))
                        .foregroundStyle(includeKey ? Color.orange : Color.secondary)

                    if let image = ConfigShare.image(for: qrText) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.white)
                            )
                    } else {
                        Text("二维码画不出来。用下面那段文本吧。")
                            .font(.aevis(13))
                            .foregroundStyle(.secondary)
                    }

                    Text(qrText)
                        .font(.aevisMono(10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )

                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = qrText
                        #endif
                        note = "这段文本复制好了，发给对方就行。"
                    } label: {
                        Text("复制这段文本")
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }

                    Text("对方在「设置 → 分享与搬家」里点「扫一扫」（或者「粘贴」）就能套用。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("我的配置码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showQR = false }
                }
            }
        }
    }

    // MARK: - 备份文件

    private func runExport() {
        busy = true
        note = nil
        do {
            let data = try BackupService.shared.makeBackup()
            let name = "Aevis-备份-\(Self.stamp()).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            backupURL = url
            note = "打包好了（\(data.count / 1024) KB）。点「保存 / 分享」存到「文件」或者发给自己。"
        } catch {
            note = "打包失败：" + error.localizedDescription
        }
        busy = false
    }

    private func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let summary = try BackupService.shared.restore(from: data)
                note = summary + "。头像和朋友圈配图不在包里，要自己重设一次。"
            } catch {
                note = "恢复失败：" + error.localizedDescription
            }
        case .failure(let error):
            note = "选文件失败：" + error.localizedDescription
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
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
