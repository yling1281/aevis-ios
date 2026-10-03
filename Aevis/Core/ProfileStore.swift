import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「我」是谁 —— 名字和头像。
///
/// 和 TA 的人设**分开存**：改我的名字不该动到她，反之也一样。
/// 用户原话：「我的话也能改头像、改名称、改气泡。」
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    /// 我叫什么。聊天里用不到它当提示词，只是给你自己看的。
    @Published var nickname: String {
        didSet { UserDefaults.standard.set(nickname, forKey: Self.nicknameKey) }
    }

    /// 我的头像。存成文件，不塞进 UserDefaults。
    @Published private(set) var avatarImage: UIImage?

    /// 个性签名。朋友圈里挂在我名字下面那句。
    ///
    /// ⚠️ 和「封面上的那句话」（`AppSettings.momentSignature`）**不是一回事**：
    ///    · 这一句是**我**的签名，跟着我走（TA 的朋友圈里、我的资料里都显示这句）
    ///    · 那一句是他给朋友圈**封面**配的说明文字
    ///    用户 2026-09-28 要的是这个「个性签名」。
    @Published var signature: String {
        didSet { UserDefaults.standard.set(signature, forKey: Self.signatureKey) }
    }

    private static let nicknameKey = "aevis.myNickname"
    private static let signatureKey = "aevis.mySignature"

    private static var avatarFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("aevis-me-avatar.jpg")
    }

    /// ⭐ **我的头像原图**（原始字节，一个 bit 都没动过）。
    ///
    /// 为什么单开一份（2026-10-03）：
    /// `avatarFileURL` 那份是**缩到 512 + JPEG 0.88** 的，显示用它省内存没问题，
    /// 但**备份不能用它** —— 用户要的是"不压缩画质"，源文件在被压的那一刻就已经损失了，
    /// 之后无论怎么加密、怎么打包都救不回来。
    /// ⇒ 所以选图的时候把 `PhotosPicker` 给的**原始 `Data`** 原样另存一份，
    ///   备份只认这一份；显示照旧用压缩版。
    private static var avatarOriginalURL: URL {
        avatarFileURL.deletingLastPathComponent()
            .appendingPathComponent("aevis-me-avatar.orig")
    }

    private init() {
        nickname = UserDefaults.standard.string(forKey: Self.nicknameKey) ?? ""
        signature = UserDefaults.standard.string(forKey: Self.signatureKey) ?? ""

        #if canImport(UIKit)
        if let data = try? Data(contentsOf: Self.avatarFileURL), let image = UIImage(data: data) {
            avatarImage = image
        }
        #endif
    }

    // MARK: - 头像

    /// 设置我的头像。传 nil 就退回默认的圆点。
    ///
    /// - Parameter original: **选图时拿到的原始字节**（`PhotosPicker` 的
    ///   `loadTransferable(type: Data.self)`，HEIC / PNG / JPEG 原样）。
    ///   传了就另存一份给备份用（见 `avatarOriginalURL` 的注释）；
    ///   传 nil（老调用路径、或从服务器下载来的）就退回压缩版兜底 ——
    ///   宁可存压缩版也不能让备份里缺头像。
    func setAvatar(_ image: UIImage?, original: Data? = nil) {
        #if canImport(UIKit)
        guard let image else {
            avatarImage = nil
            try? FileManager.default.removeItem(at: Self.avatarFileURL)
            try? FileManager.default.removeItem(at: Self.avatarOriginalURL)
            return
        }

        // 显示用的那份：压到 512，别把内存和存档撑大。
        let target: CGFloat = 512
        let longest = max(image.size.width, image.size.height)
        let scale = longest > target ? target / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let squared = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        avatarImage = squared
        if let data = squared.jpegData(compressionQuality: 0.88) {
            try? data.write(to: Self.avatarFileURL, options: .atomic)
        }

        // 备份用的那份：**原始字节原样落盘**。实在没有原始数据才退回压缩版。
        let keep = original ?? squared.jpegData(compressionQuality: 1.0)
        if let keep {
            try? keep.write(to: Self.avatarOriginalURL, options: .atomic)
        }
        #endif
    }

    /// 备份要的字节：优先原图；没有原图（老版本装的头像）就退回显示版。
    func avatarBytesForBackup() -> Data? {
        if let data = try? Data(contentsOf: Self.avatarOriginalURL), !data.isEmpty {
            return data
        }
        return try? Data(contentsOf: Self.avatarFileURL)
    }

    /// 从备份里把头像写回来（**覆盖本机现在的**）。
    ///
    /// ⚠️ 必须走 `setAvatar(image:original:)` 而不是自己写文件 ——
    /// 这样压缩版、原图、内存里的 `avatarImage` 三处一起更新，
    /// 不会出现"文件换了但界面还是旧的"。
    func adoptAvatar(from data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return }
        setAvatar(image, original: data)
        #endif
    }
}
