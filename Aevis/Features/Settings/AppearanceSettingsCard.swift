import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// 「外观」设置卡片：能交给用户的都交给用户。
/// 玻璃要不要、字大不大、用什么字体、背景长什么样、主题什么颜色，全都可改。
struct AppearanceSettingsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var fonts = FontStore.shared

    @State private var pickedItem: PhotosPickerItem?
    @State private var imageNote: String?
    @State private var importingFont = false
    @State private var fontNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("外观")

            toggleRow("用液态玻璃效果", subtitle: "关掉变成纯色卡片，更清爽、也更省电", isOn: $settings.useGlass)
            rule

            toggleRow("简易模式", subtitle: "字更大、间距更松，去掉花哨的装饰", isOn: $settings.simpleMode)
            rule

            accentSection
            rule

            fontSection
            rule

            backgroundSection
        }
        .aevisGlass(cornerRadius: 20)
        .fileImporter(
            isPresented: $importingFont,
            allowedContentTypes: FontStore.allowedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFontImport(result)
        }
    }

    // MARK: - 主题色

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            label("主题色")

            HStack(spacing: 13) {
                ForEach(Array(AppSettings.accentPalette.enumerated()), id: \.offset) { index, color in
                    Button {
                        settings.accentIndex = index
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().strokeBorder(
                                    settings.accentIndex == index
                                        ? Color.primary.opacity(0.8)
                                        : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppSettings.accentNames[index])
                }
                Spacer(minLength: 0)
            }

            Text("会同时改变气泡、按钮、光晕背景和她的默认颜色。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 字体与字号

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("字体与字号")

            HStack {
                Text("字号")
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(Int((fonts.scale * 100).rounded()))%")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $fonts.scale, in: 0.85...1.4, step: 0.05)

            // 实时预览：改一下就能看到
            VStack(alignment: .leading, spacing: 6) {
                Text("预览")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                Text("今天风有点大，出门记得穿厚一点。")
                    .font(.aevis(16))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            Picker("字体", selection: $fonts.selectedPostScriptName) {
                Text("系统字体").tag("")
                ForEach(fonts.installed) { item in
                    Text(item.displayName).tag(item.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack(spacing: 10) {
                Button {
                    fontNote = nil
                    importingFont = true
                } label: {
                    Text("导入字体文件")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }
                Spacer(minLength: 0)
            }

            if !fonts.installed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fonts.installed) { item in
                        HStack(spacing: 10) {
                            Text(item.displayName)
                                .font(.aevis(13.5))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Button {
                                fonts.remove(item)
                                fontNote = "已删除 \(item.displayName)。"
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 7)
                        if item.id != fonts.installed.last?.id {
                            Rectangle()
                                .fill(Color.primary.opacity(0.07))
                                .frame(height: 0.5)
                        }
                    }
                }
            }

            if let fontNote {
                Text(fontNote)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("支持 ttf / otf / ttc。字体文件会复制到 App 自己目录里，导入一次就长期可用；版权归你自己负责。当前：\(fonts.selectedDisplayName)")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 聊天背景

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            label("聊天背景")

            Picker("聊天背景", selection: $settings.backgroundStyle) {
                ForEach(BackgroundStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Text("从相册选一张")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }

                if settings.customBackgroundData != nil {
                    Button {
                        settings.customBackgroundData = nil
                        if settings.backgroundStyle == .custom {
                            settings.backgroundStyle = .aurora
                        }
                        imageNote = nil
                    } label: {
                        Text("删掉这张")
                            .font(.aevis(14))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }
                }

                Spacer(minLength: 0)
            }

            if let imageNote {
                Text(imageNote)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("选了图会自动切成「我的图片」，图会被压缩后只存在这台手机上。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            load(item)
        }
    }

    // MARK: - 动作

    private func handleFontImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var ok: [String] = []
            var failed = 0
            for url in urls {
                if let name = fonts.importFont(from: url) {
                    ok.append(name)
                } else {
                    failed += 1
                }
            }
            if ok.isEmpty {
                fontNote = "没能导入（可能是字体文件有问题，或这个格式 iOS 不支持）。"
            } else if failed == 0 {
                fontNote = "已导入并切换为「\(ok[0])」。"
            } else {
                fontNote = "已导入「\(ok[0])」，另有 \(failed) 个文件没成功。"
            }
        case .failure(let error):
            fontNote = "导入失败：\(error.localizedDescription)"
        }
    }

    private func load(_ item: PhotosPickerItem) {
        imageNote = nil
        Task { @MainActor in
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else {
                    imageNote = "这张图读不出来，换一张试试。"
                    return
                }
                guard let compressed = Self.compress(raw) else {
                    imageNote = "这张图格式不支持，换一张试试。"
                    return
                }
                settings.customBackgroundData = compressed
                settings.backgroundStyle = .custom
                imageNote = "好了，已经换成这张。"
            } catch {
                imageNote = "读取失败：\(error.localizedDescription)"
            }
            pickedItem = nil
        }
    }

    /// 压到最长边 1600、JPEG 0.82 —— 手机上看足够清楚，又不至于占地方。
    private static func compress(_ data: Data, maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: quality)
        #else
        return nil
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

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5))
            .foregroundStyle(.secondary)
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
