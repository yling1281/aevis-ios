import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「外观」设置卡片：能交给用户的都交给用户。
/// 玻璃要不要、字大不大、背景长什么样、主题什么颜色，全都可改。
struct AppearanceSettingsCard: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var pickedItem: PhotosPickerItem?
    @State private var imageNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("外观")

            toggleRow("用液态玻璃效果", subtitle: "关掉变成纯色卡片，更清爽、也更省电", isOn: $settings.useGlass)
            rule

            toggleRow("简易模式", subtitle: "字更大、间距更松，去掉花哨的装饰", isOn: $settings.simpleMode)
            rule

            accentSection
            rule

            backgroundSection
        }
        .aevisGlass(cornerRadius: 20)
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
                .font(.system(size: 11.5))
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
                        .font(.system(size: 14, weight: .medium))
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
                            .font(.system(size: 14))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("选了图会自动切成「我的图片」，图会被压缩后只存在这台手机上。")
                .font(.system(size: 11.5))
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
            .font(.system(size: 12.5, weight: .medium))
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
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
    }

    private func toggleRow(_ text: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11.5))
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
