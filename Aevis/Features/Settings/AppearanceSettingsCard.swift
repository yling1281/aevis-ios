import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

/// 「外观」设置卡片：能交给用户的都交给用户。
/// 玻璃要不要、图标长什么样、字大不大、用什么字体、背景什么样、主题什么颜色，全都可改。
struct AppearanceSettingsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var fonts = FontStore.shared
    @ObservedObject private var icons = AppIconStore.shared

    @State private var pickedItem: PhotosPickerItem?
    @State private var imageNote: String?
    /// 背景图失败的原因 —— 用一个**弹窗**说出来。
    /// 之前只写进那一行小字里，用户翻不到，反馈就变成「选完图没变化」。
    @State private var imageAlert = ""
    @State private var showImageAlert = false
    @State private var importingFont = false
    @State private var fontNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("外观")

            glassSection
            rule

            toneSection
            rule

            toggleRow("简易模式", subtitle: "字更大、间距更松，去掉花哨的装饰", isOn: $settings.simpleMode)
            rule

            accentSection
            rule

            appIconSection
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

    // MARK: - 玻璃材质（四档）

    private var glassSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            label("玻璃材质")

            Picker("玻璃材质", selection: glassBinding) {
                ForEach(GlassStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Text(glassBinding.wrappedValue.explanation)
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// 玻璃四档和原来的开关是同一个东西：选「关闭」就是关掉玻璃。
    private var glassBinding: Binding<GlassStyle> {
        Binding(
            get: { settings.useGlass ? settings.glassStyle : .off },
            set: { value in
                if value == .off {
                    settings.useGlass = false
                } else {
                    settings.useGlass = true
                    settings.glassStyle = value
                }
            }
        )
    }

    // MARK: - 圆角、上色浓度、文字颜色

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("圆角")
                        .font(.aevis(14.5))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", settings.cornerScale * 100))
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.cornerScale, in: 0.4...1.8, step: 0.05)
                Text("越小越方正，越大越圆润。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("上色浓度")
                        .font(.aevis(14.5))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", settings.tintStrength * 100))
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.tintStrength, in: 0...1.6, step: 0.05)
                Text("主题色在背景上着得多浓。拉到 0 就只剩底色。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 9) {
                label("文字颜色")
                HStack(spacing: 13) {
                    ForEach(Array(AppSettings.fontColorPalette.enumerated()), id: \.offset) { index, color in
                        Button {
                            settings.fontColorIndex = index
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().strokeBorder(
                                        settings.fontColorIndex == index
                                            ? settings.accentColor
                                            : Color.primary.opacity(0.15),
                                        lineWidth: 2
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppSettings.fontColorNames[index])
                    }
                    Spacer(minLength: 0)
                }
                Text("聊天页里她的话会跟着变。第一个是跟随系统。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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

            Text("会同时改变气泡、按钮、光晕背景和 TA 的默认颜色。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // 主题色跟头像走。取不到颜色（没设头像）就自动回到上面那一个 ——
            // 所以这个开关永远不会把界面变成没有颜色。
            Toggle(isOn: Binding(
                get: { settings.dynamicAccent },
                set: { on in
                    settings.dynamicAccent = on
                    if on { settings.refreshAvatarTint(from: PersonaStore.shared.avatarImage) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("主题色跟着 TA 的头像走")
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                    Text(settings.dynamicAccent && settings.avatarTint == nil && PersonaStore.shared.avatarImage != nil
                         ? "开着，但这张头像取不出颜色，先用你挑的那个"
                         : "从头像里取一个主色当主题色；没设头像就用你挑的那个")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(settings.accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Text("界面密度")
                    .font(.aevis(13))
                    .foregroundStyle(.primary)

                Picker("界面密度", selection: $settings.densityIndex) {
                    ForEach(Array(AppSettings.densityNames.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .pickerStyle(.segmented)

                Text("只改间距和留白，字号另有开关（上面那排）—— 这两件事分开，谁也不用迁就谁。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 桌面图标

    private var appIconSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            label("桌面图标")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 12
            ) {
                ForEach(AppIconOption.allCases) { option in
                    Button {
                        icons.apply(option)
                    } label: {
                        VStack(spacing: 5) {
                            AppIconPreview(color: option.previewColor, size: 48)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(
                                            icons.current == option
                                                ? Color.primary.opacity(0.85)
                                                : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                            Text(option.label)
                                .font(.aevis(11))
                                .foregroundStyle(icons.current == option ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if let message = icons.message {
                Text(message)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("点一下就换，主屏幕上立刻能看到。iOS 只允许在内置图标之间切换，不能拿相册里的图当桌面图标——这是系统限制，任何 App 都做不到。")
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

            // ⚠️ 这一段是**冲着真实反馈写的**：「导入 TTF 时点「打开」点不动」。
            // 原因多半不在 App 里 —— iOS 的「文件」里，**别的 App 文件夹下的文件
            // 系统会直接灰掉**（那是别的 App 的沙盒，我们读不到），点了当然没反应。
            Text("支持 .ttf / .otf / .ttc。\n"
                 + "如果点「打开」没反应，多半是文件放错地方了：iOS 只允许选"
                 + "「我的 iPhone」或 iCloud Drive 里的文件。如果你那个 TTF 在某个 App 的文件夹里"
                 + "（微信、QQ、下载器那种），先长按它 → 拷贝/移动到「我的 iPhone」，再来导入。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

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
                // PhotosPicker 是控件，系统会把强调色刷到它的文字上，
                // 光写 .foregroundStyle(.primary) 不够 —— 截图自检时发现的（文字是蓝的）。
                .tint(Color.primary)

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

            // 当前那张的缩略图 + 尺寸/大小。
            // 为什么要有：用户报「选完图没变化」，可那张图到底设进去没有，
            // 光看背景是看不出来的（背景变化本来就很轻）。把这个摆出来，
            // 「到底有没有生效」一眼就能确认。
            if let data = settings.customBackgroundData,
               let preview = UIImage(data: data) {
                HStack(spacing: 11) {
                    Color.clear
                        .frame(width: 54, height: 54)
                        .overlay(
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFill()
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("已经设成背景了")
                            .font(.aevis(13))
                            .foregroundStyle(.primary)
                        Text("\(Int(preview.size.width))×\(Int(preview.size.height)) · \(data.count / 1024) KB")
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
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
        .alert("聊天背景", isPresented: $showImageAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(imageAlert)
        }
    }

    // MARK: - 动作

    private func handleFontImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                fontNote = "没有选到文件。"
                return
            }
            var ok: [String] = []
            var problems: [String] = []
            for url in urls {
                do {
                    ok.append(try fonts.importFont(from: url))
                } catch {
                    // 把原因说出来 —— 之前失败什么都不显示，看着像「点了没反应」
                    problems.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if ok.isEmpty {
                fontNote = problems.isEmpty
                    ? "没能导入。"
                    : "没能导入：\n" + problems.joined(separator: "\n")
            } else {
                var line = "已导入并切换为「\(ok[0])」。"
                if !problems.isEmpty {
                    line += "\n另外这几个没成：\n" + problems.joined(separator: "\n")
                }
                fontNote = line
            }
        case .failure(let error):
            fontNote = "打开文件选择器失败：\(error.localizedDescription)"
        }
    }

    private func load(_ item: PhotosPickerItem) {
        imageNote = nil
        Task { @MainActor in
            defer { pickedItem = nil }

            // 相册里有两种图**第一次读不出来**：还在 iCloud 上的、刚拍完没写完的。
            // 隔一下再试一次这两种都能过。只试一次的表现就是
            // 「选完图什么都没发生」—— 用户以为功能坏了，其实只是要多等一秒。
            var raw = await Self.transfer(item)
            if raw == nil {
                try? await Task.sleep(nanoseconds: 700_000_000)
                raw = await Self.transfer(item)
            }

            guard let raw else {
                fail("这张图没能从相册读出来 —— 多半是还在 iCloud 里没下载到本机。"
                     + "等它下载完再选一次；或者先在相册里打开它一遍。")
                return
            }
            guard let compressed = Self.compress(raw) else {
                fail("这张图解码不了（\(raw.count / 1024) KB）。换成 JPG 或 PNG 再试一次。")
                return
            }

            settings.customBackgroundData = compressed
            settings.backgroundStyle = .custom
            imageNote = "好了，已经换成这张。"
        }
    }

    /// 失败要说清楚，而且要说在**用户一定看得见的地方**。
    private func fail(_ reason: String) {
        imageNote = reason
        imageAlert = reason
        showImageAlert = true
    }

    private static func transfer(_ item: PhotosPickerItem) async -> Data? {
        try? await item.loadTransferable(type: Data.self)
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

/// 桌面图标的预览。
/// 真正的图标资源编在 Assets 里，运行时不能按名字取出来当图片用，
/// 所以这里按同样的构图（深色底 + 同色光核 + 细环）画一个小样。
private struct AppIconPreview: View {
    var color: Color
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.55), Color(red: 0.04, green: 0.04, blue: 0.07)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [color, color.opacity(0.5)],
                        center: UnitPoint(x: 0.42, y: 0.42),
                        startRadius: 1,
                        endRadius: size * 0.34
                    )
                )
                .frame(width: size * 0.54, height: size * 0.54)

            Circle()
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.7)
                .frame(width: size * 0.76, height: size * 0.76)
        }
        .frame(width: size, height: size)
    }
}
