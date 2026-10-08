import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 来电头像 / 显示名的本地存档。
///
/// 老板原话：「打电话的那些头像，可以自定义」。
/// 这里就干两件事：把一张相册图存进沙盒、把一个显示名存进 `UserDefaults`，
/// 下次启动还在。
///
/// ## ⚠️ 必须如实的一点：系统那张卡上的小图标是「模板渲染」
/// 交给系统的 `iconTemplateImageData` 会被系统当成模板图（单色剪影）来渲染 ——
/// 彩色照片在系统那张卡上不会显示成彩色。
/// 这不是我们偷懒，是 `LiveCommunicationKit` 就这一条路：
/// 它没有任何「把彩色头像放上系统卡」的接口。所以界面文案里也不承诺彩色头像，
/// 只叫它「来电图标」。
///
/// ## 为什么整个类标 `@MainActor`
/// 它被 SwiftUI 的 `@StateObject` 直接持有，属性又在主线程读；
/// 标上 `@MainActor` 最省心，也避开「后台线程改 @Published 在 iOS 26 上硬崩」那个坑。
@MainActor
final class CallIdentityStore: ObservableObject {

    /// ⚠️ 单例 + `private init()` —— 理由同 `CallShell`：App 里读 `shared` 才能编过。
    static let shared = CallIdentityStore()

    private init() {
        load()
    }

    /// 系统卡上显示的「对方名字」。
    @Published private(set) var displayName: String = "ta"

    /// 当前头像（内存缓存，改了它就等于通知界面刷新）。
    @Published private(set) var avatarImage: UIImage?

    /// 是否已经有自定义头像。
    var hasAvatar: Bool { avatarImage != nil }

    // MARK: - 改名字

    func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = trimmed.isEmpty ? "ta" : trimmed
        UserDefaults.standard.set(displayName, forKey: Self.nameKey)
    }

    // MARK: - 换头像

    /// 存一张新头像。图会被压到方形 512 再落盘，省得沙盒里躺一张几 MB 的原图。
    func setAvatar(_ image: UIImage) {
        #if canImport(UIKit)
        guard let data = Self.normalizedPNG(from: image) else { return }
        try? data.write(to: Self.avatarURL, options: .atomic)
        avatarImage = UIImage(data: data)
        UserDefaults.standard.set(Self.avatarFileName, forKey: Self.avatarKey)
        #endif
    }

    /// 清掉自定义头像，退回系统默认。
    func clearAvatar() {
        #if canImport(UIKit)
        try? FileManager.default.removeItem(at: Self.avatarURL)
        avatarImage = nil
        UserDefaults.standard.removeObject(forKey: Self.avatarKey)
        #endif
    }

    // MARK: - 交给系统那张卡的图标

    /// 交给系统那张卡的图标数据（模板图）。
    ///
    /// ⚠️ 再强调一次：系统会把它渲染成单色剪影，不是彩色照片。
    /// 没有自定义头像时返回 nil（用系统默认），有就返回一张方形 PNG。
    var iconTemplateData: Data? {
        #if canImport(UIKit)
        guard let image = avatarImage else { return nil }
        return Self.templatePNG(from: image)
        #else
        return nil
        #endif
    }

    // MARK: - 路径与键

    private static let nameKey = "aevis.call.callerName"
    private static let avatarKey = "aevis.call.callerAvatar"
    private static let avatarFileName = "caller-avatar.png"

    /// 头像落在沙盒 `Documents/caller-avatar.png`。
    private static var avatarURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent(avatarFileName)
    }

    // MARK: - 读档

    private func load() {
        if let saved = UserDefaults.standard.string(forKey: Self.nameKey),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = saved
        }
        #if canImport(UIKit)
        if let data = try? Data(contentsOf: Self.avatarURL),
           let image = UIImage(data: data) {
            avatarImage = image
        }
        #endif
    }

    // MARK: - 渲染（全部用公开 API：UIGraphicsImageRenderer）

    #if canImport(UIKit)

    /// 把任意图裁成方形（aspect fill）并压到 512，返回 PNG 数据。
    private static func normalizedPNG(from image: UIImage, side: CGFloat = 512) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.pngData { _ in
            drawSquare(image, side: side)
        }
    }

    /// 交给系统的模板图数据。
    ///
    /// ⚠️ 这里**不做任何自创的着色 / 裁剪 API**：只是把图画成方形 PNG，
    ///    真正的「单色剪影」是系统拿到数据后自己做的。
    ///    `LiveCommunicationKit` 没有「把彩色头像放上系统卡」的接口，别去找。
    private static func templatePNG(from image: UIImage, side: CGFloat = 512) -> Data? {
        normalizedPNG(from: image, side: side)
    }

    /// 把图画进当前图形上下文，按短边铺满、长边裁掉（方形居中）。
    private static func drawSquare(_ image: UIImage, side: CGFloat) {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return }
        let scale = max(side / width, side / height)
        let drawWidth = width * scale
        let drawHeight = height * scale
        let rect = CGRect(
            x: (side - drawWidth) / 2,
            y: (side - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        image.draw(in: rect)
    }

    #endif
}
