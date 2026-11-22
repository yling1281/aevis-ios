import SwiftUI
import UIKit

/// 可自定义背景：预设渐变（奶油 / 柔紫 / 海盐 / 深空）或用户自选的相册图片。
///
/// 存储键（`ThemeSettingsView` 写入，这里只读）：
/// - `aevisBgStyle`：预设索引（0 奶油 / 1 柔紫 / 2 海盐 / 3 深空）
/// - `aevisBgBlur`：模糊半径 pt（0...20）
/// - `aevisBgImageName`：自定义图的文件名（固定 `aevis-bg.jpg`），空 = 用预设
/// - `aevisBgPos`：图片显示方式（0 填充 / 1 居中 / 2 拉伸）
/// - `aevisBgRev`：写入计数器。因为图片文件名固定（aevis-bg.jpg），路径不变，
///   换图后靠它触发本视图重新读盘（否则会一直显示缓存里的旧图）。
/// - `aevisBgImagePath`：旧键（绝对路径），重装后失效；迁移到 `aevisBgImageName` 后清掉。
///
/// 用法：在需要背景的视图最外层 `.background(AppBackground())`。
struct AppBackground: View {
    @AppStorage("aevisBgStyle") private var style: Int = 0
    @AppStorage("aevisBgBlur") private var blurAmount: Double = 0
    @AppStorage("aevisBgImageName") private var imageName = ""
    @AppStorage("aevisBgImagePath") private var legacyImagePath = ""  // 旧键，迁移后清掉
    @AppStorage("aevisBgPos") private var imagePos = 0
    @AppStorage("aevisBgRev") private var revision = 0
    @Environment(\.colorScheme) private var scheme

    /// 已解码的自定义图（nil = 没有自定义图 / 文件丢失 → 回落预设渐变）
    @State private var customImage: UIImage?

    private enum Preset: Int, CaseIterable {
        case cream = 0, lilac, seaSalt, deepSpace

        /// 按深浅模式返回渐变色组。
        func colors(dark: Bool) -> [Color] {
            switch (self, dark) {
            case (.cream, false):     return [Color.hex(0xFFF8EC), Color.hex(0xFFF1DC)]
            case (.cream, true):      return [Color.hex(0x1E1B24), Color.hex(0x272230)]
            case (.lilac, false):     return [Color.hex(0xF3EEFF), Color.hex(0xE7DEFF)]
            case (.lilac, true):      return [Color.hex(0x241E33), Color.hex(0x2E2642)]
            case (.seaSalt, false):   return [Color.hex(0xEAF4F4), Color.hex(0xDCEDEF)]
            case (.seaSalt, true):    return [Color.hex(0x18282B), Color.hex(0x1F3236)]
            case (.deepSpace, false): return [Color.hex(0xD9DCE6), Color.hex(0xC2C7D4)]
            case (.deepSpace, true):  return [Color.hex(0x101218), Color.hex(0x191C26)]
            }
        }

    }

    var body: some View {
        ZStack(alignment: .top) {
            // 底层永远是预设渐变：自定义图读不到时自然回落，不会露出纯黑/透明底
            gradientLayer

            if let img = customImage {
                imageLayer(img)
            } else {
                // 顶部一点柔光，层次靠材质不靠边框
                RadialGradient(
                    gradient: Gradient(colors: [AE.brandLilac.opacity(0.35), Color.clear]),
                    center: .top, startRadius: 0, endRadius: 320
                )
                .frame(height: 360)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { loadCustomImage() }
        .onChange(of: revision) { _ in loadCustomImage() }
        .onChange(of: imagePath) { _ in loadCustomImage() }
    }

    // MARK: - 图层

    /// 自定义图：按位置模式铺满，模糊直接作用在图上。
    /// `.blur` 会让边缘半透明，所以先按模糊量放大一点再裁掉，避免四周出现一圈灰边。
    private func imageLayer(_ img: UIImage) -> some View {
        GeometryReader { geo in
            imageContent(img)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(1 + CGFloat(blurAmount) * 0.02)
                .blur(radius: CGFloat(blurAmount), opaque: true)
                .clipped()
        }
    }

    @ViewBuilder
    private func imageContent(_ img: UIImage) -> some View {
        switch imagePos {
        case 1:
            Image(uiImage: img).resizable().scaledToFit()
        case 2:
            Image(uiImage: img).resizable()
        default:
            Image(uiImage: img).resizable().scaledToFill()
        }
    }

    /// 预设渐变（原逻辑不变，模糊仍整层生效）。
    /// 先模糊再放大一点，把模糊产生的透明边缘推到屏幕外，避免四周出现一圈暗角。
    private var gradientLayer: some View {
        let preset = Preset(rawValue: style) ?? .cream
        return LinearGradient(
            colors: preset.colors(dark: scheme == .dark),
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .blur(radius: CGFloat(blurAmount))
        .scaleEffect(1 + CGFloat(blurAmount) * 0.02)
    }

    // MARK: - 读图

    private func loadCustomImage() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // 新键优先：按文件名拼路径（重装后路径 UUID 变化，文件名固定）
        if !imageName.isEmpty {
            let url = docs.appendingPathComponent(imageName)
            if let img = UIImage(contentsOfFile: url.path) {
                customImage = img
                return
            }
        }

        // 兼容旧数据：绝对路径迁移到文件名
        if !legacyImagePath.isEmpty {
            if let img = UIImage(contentsOfFile: legacyImagePath) {
                customImage = img
                // 迁移：写入新键，清掉旧键
                imageName = "aevis-bg.jpg"
                legacyImagePath = ""
                return
            }
        }

        customImage = nil
    }
}
