import SwiftUI
import PhotosUI
import Photos
import UIKit

/// 主题配置（2026-11-22 新增，照用户给的「主题配置」参考图做）。
///
/// 版式：顶部手机框预览（实时渲染当前背景：预设色 / 相册图 + 位置 + 模糊）
/// → 「背景图」分组（更换背景图 / 显示位置 / 模糊 / 恢复默认背景）
/// → 「预设背景」分组（跟设置页原有 4 个色块同一套 `aevisBgStyle`）。
///
/// 存储（`AppBackground` 直接读这几个键，改完立刻全局生效）：
/// - `aevisBgImageName`：固定文件名 `aevis-bg.jpg`（重装后路径 UUID 变化，用文件名拼路径）
/// - `aevisBgPos`：0 填充 / 1 居中 / 2 拉伸
/// - `aevisBgBlur`：0...20
/// - `aevisBgStyle`：预设索引（0 奶油 / 1 柔紫 / 2 海盐 / 3 深空）
/// - `aevisBgRev`：换图/重置后自增，让 AppBackground 重新读盘
struct ThemeSettingsView: View {
    @AppStorage("aevisBgStyle") private var bgStyle = 0
    @AppStorage("aevisBgBlur") private var bgBlur = 0.0
    @AppStorage("aevisBgImageName") private var imageName = ""
    @AppStorage("aevisBgPos") private var imagePos = 0
    @AppStorage("aevisBgRev") private var revision = 0

    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var saving = false
    @State private var errorText = ""
    @State private var showError = false

    /// 与 ThemeSettingsView 的预览共用；`imagePos` 的三档文案（顺序必须和 0/1/2 对齐）。
    private let posItems = ["填充", "居中", "拉伸"]

    private struct BgPreset: Identifiable {
        let id: Int
        let name: String
        let colors: [Color]
    }
    private let presets: [BgPreset] = [
        BgPreset(id: 0, name: "奶油", colors: [Color.hex(0xFFF8EC), Color.hex(0xFFF1DC)]),
        BgPreset(id: 1, name: "柔紫", colors: [Color.hex(0xF3EEFF), Color.hex(0xE7DEFF)]),
        BgPreset(id: 2, name: "海盐", colors: [Color.hex(0xEAF4F4), Color.hex(0xDCEDEF)]),
        BgPreset(id: 3, name: "深空", colors: [Color.hex(0xD9DCE6), Color.hex(0xC2C7D4)])
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                previewPhone

                sectionCard(title: "背景图", icon: "photo.on.rectangle") {
                    changeRow
                    innerDivider
                    positionRow
                    innerDivider
                    blurRow
                    innerDivider
                    resetRow
                }

                sectionCard(title: "预设背景", icon: "square.grid.2x2") {
                    HStack(spacing: 10) {
                        ForEach(presets) { p in
                            swatch(p)
                        }
                    }
                    .padding(.top, 2)
                    hint("选预设会替换掉自定义图片。背景与模糊会立即应用到主页、商城与账号中心（聊天页用自己的气泡底色，不铺背景）。")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .background(Color.paper)
        .navigationTitle("主题配置")
        .navigationBarTitleDisplayMode(.inline)
        // 从设置 tab push 进来时收起底部原生 TabBar（系统不会自动收，由目的页声明）；
        // 返回设置页会自动恢复。与 ChatView 同一写法。
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await importImage(item) }
        }
        .onChange(of: imageName) { _ in loadPreview() }
        .onAppear { loadPreview() }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errorText)
        }
    }

    // MARK: - 手机框预览

    private var previewPhone: some View {
        let screenW: CGFloat = 168
        let screenH: CGFloat = 300

        return ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.adaptive(dark: Color.hex(0x2A2F3E), light: .white).opacity(0.55))

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .overlay(
                    previewBackground
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                )
                .frame(width: screenW, height: screenH)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.5), lineWidth: 0.8)
                )

            mockContent
                .frame(width: screenW, height: screenH)
        }
        .frame(width: screenW + 18, height: screenH + 18)
        .overlay(
            RoundedRectangle(cornerRadius: 33, style: .continuous)
                .stroke(AE.accentDeep.opacity(0.75), lineWidth: 2)
        )
        .shadow(color: AE.shadowColor, radius: 14, y: 6)
    }

    /// 预览里的背景：规则与 AppBackground 完全一致（有图用图 + 位置 + 模糊，没图用预设渐变）。
    @ViewBuilder
    private var previewBackground: some View {
        if let img = previewImage {
            GeometryReader { geo in
                Group {
                    switch imagePos {
                    case 1: Image(uiImage: img).resizable().scaledToFit()
                    case 2: Image(uiImage: img).resizable()
                    default: Image(uiImage: img).resizable().scaledToFill()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(1 + CGFloat(bgBlur) * 0.02)
                .blur(radius: CGFloat(bgBlur), opaque: true)
                .clipped()
            }
        } else {
            LinearGradient(
                colors: currentPreset.colors,
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .blur(radius: CGFloat(bgBlur) * 0.6)
        }
    }

    /// 手机框里的示意内容：几条胶囊 + 三张卡片，纯装饰，用来对比背景与模糊。
    private var mockContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                AevisMascot(size: 17)
                Capsule().fill(AE.accentDeep.opacity(0.55))
                    .frame(width: 54, height: 5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)

            Capsule().fill(Color.black.opacity(0.18))
                .frame(width: 60, height: 5)
            Capsule().fill(Color.black.opacity(0.10))
                .frame(width: 86, height: 5)

            Capsule()
                .fill(LinearGradient(colors: [Color.hex(0x9BC5F0), Color.hex(0xC9E2FA)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
                .overlay(alignment: .trailing) {
                    AevisMascot(size: 13).offset(x: 6, y: -1)
                }
                .padding(.trailing, 12)

            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.45))
                        .frame(height: 34)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    // MARK: - 背景图分组

    private var changeRow: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            HStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 22)
                Text("更换背景图")
                    .font(.system(size: 15))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 8)
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(imageName.isEmpty ? "未设置" : "已设置")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AE.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AE.textSecondary.opacity(0.45))
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
    }

    private var positionRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 22)
                Text("显示位置")
                    .font(.system(size: 15))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 8)
                Text(posItems[min(max(imagePos, 0), 2)])
                    .font(.system(size: 12.5))
                    .foregroundStyle(AE.textSecondary)
            }
            segment(items: posItems, index: $imagePos)
        }
        .padding(.vertical, 4)
    }

    private var blurRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "drop")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 22)
                Text("模糊")
                    .font(.system(size: 15))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 8)
                Text("\(Int(bgBlur))")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(AE.textSecondary)
            }
            Slider(value: $bgBlur, in: 0...20, step: 1)
                .tint(AE.accent)
                .padding(.leading, 34)
        }
        .padding(.vertical, 4)
    }

    private var resetRow: some View {
        Button {
            resetBackground()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.hex(0xE0484D))
                    .frame(width: 22)
                Text("恢复默认背景")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.hex(0xE0484D))
                Spacer(minLength: 0)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 预设色块

    private func swatch(_ p: BgPreset) -> some View {
        let on = imageName.isEmpty && bgStyle == p.id
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                bgStyle = p.id
                clearCustomImage()     // 有自定义图时选预设，预设才会真的上屏
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: p.colors,
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    if on {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(AE.accentDeep, lineWidth: 2)
                        Circle()
                            .fill(AE.accentDeep)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: Color.black.opacity(0.16), radius: 3, y: 1)
                    }
                }
                .frame(height: 50)

                Text(p.name)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? AE.textPrimary : AE.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 通用

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AE.accent)
                Text(title)
                    .font(.system(size: AE.sectionTitle, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }

    /// 三段选择器（与设置页 SettingsSegment 同一套视觉，这里是本文件私有实现，
    /// 因为那边的是 private，不能跨文件复用）。
    private func segment(items: [String], index: Binding<Int>) -> some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = index.wrappedValue == i
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        index.wrappedValue = i
                    }
                } label: {
                    Text(items[i])
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? AE.textPrimary : AE.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.adaptive(dark: Color.hex(0x3C4256), light: .white))
                                    .shadow(color: Color.black.opacity(0.07), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AE.accentSoft.opacity(0.85))
        )
        .padding(.leading, 34)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var innerDivider: some View {
        Rectangle()
            .fill(AE.textSecondary.opacity(0.14))
            .frame(height: 0.7)
    }

    // MARK: - 数据

    private var currentPreset: BgPreset {
        presets.first(where: { $0.id == bgStyle }) ?? presets[0]
    }

    /// 自定义图固定存 `Documents/aevis-bg.jpg`（覆盖写），文件名写进 `aevisBgImageName`。
    private var bgFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("aevis-bg.jpg")
    }

    private func loadPreview() {
        guard !imageName.isEmpty else {
            previewImage = nil
            return
        }
        previewImage = UIImage(contentsOfFile: bgFileURL.path)
    }

    private func clearCustomImage() {
        if FileManager.default.fileExists(atPath: bgFileURL.path) {
            try? FileManager.default.removeItem(at: bgFileURL)
        }
        imageName = ""
        previewImage = nil
        revision += 1
    }

    private func resetBackground() {
        withAnimation(.easeInOut(duration: 0.2)) {
            clearCustomImage()
            imagePos = 0
            bgBlur = 0
        }
    }

    // MARK: - 相册导入

    private func importImage(_ item: PhotosPickerItem) async {
        await MainActor.run { saving = true }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let raw = UIImage(data: data) else {
                throw NSError(domain: "aevis.bg", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "这张图片读不出来，换一张试试。"])
            }
            // 相册原图动辄十几 MB，先缩到长边 1600 再压 JPEG，避免占满沙盒
            let img = downscaled(raw, maxSide: 1600)
            guard let jpg = img.jpegData(compressionQuality: 0.88) else {
                throw NSError(domain: "aevis.bg", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "图片压缩失败，换一张试试。"])
            }
            try jpg.write(to: bgFileURL, options: .atomic)

            await MainActor.run {
                imageName = "aevis-bg.jpg"
                previewImage = img
                revision += 1
                saving = false
                pickerItem = nil
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                showError = true
                saving = false
                pickerItem = nil
            }
        }
    }

    private func downscaled(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let w = img.size.width
        let h = img.size.height
        guard w > 0, h > 0 else { return img }
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1 else { return img }

        let size = CGSize(width: floor(w * scale), height: floor(h * scale))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
