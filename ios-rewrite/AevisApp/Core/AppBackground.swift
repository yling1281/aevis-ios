import SwiftUI
import UIKit

/// 背景相关的 UserDefaults 键 —— **全工程只此一份**（2026-11-25）。
///
/// 之前 `ThemeSettingsView` 和 `AppBackground` 各自手写一遍字符串键，
/// 少一个字母、多一个空格就变成"写进去但没人读"，表现正是用户报的
/// 「主题里选了背景图，主界面没变」。所以键名收敛到这里，两边都引用常量。
enum BackgroundKeys {
    static let style = "aevisBgStyle"          // 预设索引 0...3
    static let blur = "aevisBgBlur"            // 模糊半径 pt（0...20）
    static let imageName = "aevisBgImageName"  // 自定义图文件名（固定 aevis-bg.jpg）
    static let legacyImagePath = "aevisBgImagePath" // 旧键（绝对路径），迁移后清掉
    static let imagePos = "aevisBgPos"         // 0 填充 / 1 居中 / 2 拉伸
    static let revision = "aevisBgRev"         // 写入计数器：换图后自增，驱动重新读盘
    static let dim = "aevisBgDim"              // 自定义图上压暗强度（保证文字可读）

    /// 自定义图的固定文件名：换图覆盖同一个文件，路径不变，重装后路径 UUID 也无关。
    static let customFileName = "aevis-bg.jpg"

    /// Documents 目录下的绝对路径。
    static var customFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(customFileName)
    }
}

/// 已解码背景图的进程内缓存。
///
/// 为什么需要：`AppBackground()` 在主界面、商城、会员页、广场各挂了一份（fullScreenCover
/// 会盖住根视图，所以每页都得自己有一份背景）。1600px 的 JPEG 解一次约 6 MB 位图，
/// 四个页面各解一次就是 24 MB，而且每次切换都重新读盘 —— 手感是"点了背景图要等一下才变"。
/// 用 `NSCache` 按（文件名 + revision）缓存，换图时 revision 变，自动换 key。
enum BackgroundImageStore {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 4
        return c
    }()

    static func image(name: String, revision: Int) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let key = "\(name)#\(revision)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = UIImage(contentsOfFile: BackgroundKeys.customFileURL.path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// 换图/重置后清空，避免旧图靠 revision 撞 key 留下残影。
    static func clear() {
        cache.removeAllObjects()
    }
}

/// 可自定义背景：预设渐变（奶油 / 柔紫 / 海盐 / 深空）或用户自选的相册图片。
///
/// 存储键见 `BackgroundKeys`（`ThemeSettingsView` 写入，这里只读）。
///
/// 2026-11-25 修「选了背景图但不生效」，三个原因一起修掉：
/// 1. **权限**：`PhotosPicker(photoLibrary: .shared())` 需要 `NSPhotoLibraryUsageDescription`，
///    Info.plist 里原先没有这个键 → 相册根本弹不出来，图从来没写进沙盒（已在 Info.plist 补上）；
/// 2. **全局**：背景原先只在 `MainTabView` 挂了一份，登录页没有；现在根视图
///    （`AevisApp.root`）就垫了一层，登录前/登录后/所有 fullScreenCover 都是同一张；
/// 3. **刷新**：原来靠 `.onAppear` + 两个 `onChange` 三处触发，同一次写入里
///    `imageName` 和 `revision` 同时变，SwiftUI 可能只跑一次、读到的是旧状态。
///    现在统一成 `.task(id: signature)` —— 签名变了必然重新读盘，只触发一次。
struct AppBackground: View {
    @AppStorage(BackgroundKeys.style) private var style: Int = 0
    @AppStorage(BackgroundKeys.blur) private var blurAmount: Double = 0
    @AppStorage(BackgroundKeys.imageName) private var imageName = ""
    @AppStorage(BackgroundKeys.legacyImagePath) private var legacyImagePath = ""
    @AppStorage(BackgroundKeys.imagePos) private var imagePos = 0
    @AppStorage(BackgroundKeys.revision) private var revision = 0
    @AppStorage(BackgroundKeys.dim) private var dimOverride: Double = -1
    @Environment(\.colorScheme) private var scheme

    /// 已解码的自定义图（nil = 没有自定义图 / 文件丢失 → 回落预设渐变）
    @State private var customImage: UIImage?

    /// 读盘签名：文件名或版本号任一变化都算"换了张图"。
    private var signature: String { "\(imageName)#\(revision)" }

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
                // 压暗层：全屏照片背景上，深色文字会消失。
                // 自动档（dim=-1）浅色 0.22、深色 0.32 —— 用户可在主题页手动调。
                Color.black.opacity(scrimOpacity)
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
        // 统一成一个触发点：签名变了才重新读盘（只跑一次，不会三处抢）
        .task(id: signature) { reload() }
    }

    /// 压暗强度：`aevisBgDim` < 0 表示自动；否则用用户设的值（0...0.6 夹紧）。
    private var scrimOpacity: Double {
        if dimOverride >= 0 { return min(max(dimOverride, 0), 0.6) }
        return scheme == .dark ? 0.32 : 0.22
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

    private func reload() {
        // 新键优先：按文件名拼路径（重装后路径 UUID 变化，文件名固定）
        if let img = BackgroundImageStore.image(name: imageName, revision: revision) {
            customImage = img
            return
        }

        // 兼容旧数据：绝对路径迁移到文件名
        if !legacyImagePath.isEmpty, let img = UIImage(contentsOfFile: legacyImagePath) {
            // 文件还在：搬到固定文件名，再切到新键
            if let jpg = img.jpegData(compressionQuality: 0.88) {
                try? jpg.write(to: BackgroundKeys.customFileURL, options: .atomic)
            }
            imageName = BackgroundKeys.customFileName
            legacyImagePath = ""
            BackgroundImageStore.clear()
            revision += 1          // 触发下一轮 task(id:) 用新 key 重新读
            customImage = img
            return
        }

        // imageName 有值但文件没了（用户清过缓存 / 重装）：清掉键，回落预设，避免一直白底
        if !imageName.isEmpty {
            imageName = ""
        }
        customImage = nil
    }
}

/// 全局背景宿主（2026-11-25）：把背景和内容分两层，保证**任何页面**都透出同一张图。
///
/// 用法（`AevisApp.root` 最外层）：`AppBackgroundHost { 真正的页面 }`
/// 内容层不加任何底色，页内卡片一律用 `glassCard` 之类的半透明材质。
struct AppBackgroundHost<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            AppBackground()
            content()
        }
    }
}

/// 聊天页**独立背景**（2026-11-24）：默认跟随全局背景；用户在设置里打开
/// 「聊天背景单独设置」后，聊天页只用这里的高对比纯色/渐变，不铺全局自定义图，
/// 保证聊天气泡文字在花哨背景上仍可读。存储键与全局完全分离，互不覆盖。
struct ChatBackground: View {
    @AppStorage("aevisChatBgIndependent") private var independent = false
    @AppStorage("aevisChatBgStyle") private var style = 0
    @Environment(\.colorScheme) private var scheme

    private enum Preset: Int, CaseIterable {
        case ink = 0, cream, mist

        var label: String {
            switch self {
            case .ink: return "深墨"
            case .cream: return "奶油"
            case .mist: return "雾蓝"
            }
        }

        func colors(dark: Bool) -> [Color] {
            switch (self, dark) {
            case (.ink, false):   return [Color.hex(0xE8EAF0), Color.hex(0xDDE1EA)]
            case (.ink, true):    return [Color.hex(0x14161C), Color.hex(0x1C2029)]
            case (.cream, false): return [Color.hex(0xFFF8EC), Color.hex(0xFFF0D9)]
            case (.cream, true):  return [Color.hex(0x241F1A), Color.hex(0x302820)]
            case (.mist, false):  return [Color.hex(0xEAF2F7), Color.hex(0xD8E7F0)]
            case (.mist, true):   return [Color.hex(0x141E26), Color.hex(0x1B2A35)]
            }
        }
    }

    static var presetLabels: [String] { Preset.allCases.map { $0.label } }

    var body: some View {
        Group {
            if independent {
                LinearGradient(
                    colors: (Preset(rawValue: style) ?? .ink).colors(dark: scheme == .dark),
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else {
                AppBackground()
            }
        }
    }
}
