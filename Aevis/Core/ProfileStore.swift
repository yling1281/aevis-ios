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

    private static let nicknameKey = "aevis.myNickname"

    private static var avatarFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("aevis-me-avatar.jpg")
    }

    private init() {
        nickname = UserDefaults.standard.string(forKey: Self.nicknameKey) ?? ""

        #if canImport(UIKit)
        if let data = try? Data(contentsOf: Self.avatarFileURL), let image = UIImage(data: data) {
            avatarImage = image
        }
        #endif
    }

    // MARK: - 头像

    /// 设置我的头像。传 nil 就退回默认的圆点。
    func setAvatar(_ image: UIImage?) {
        #if canImport(UIKit)
        guard let image else {
            avatarImage = nil
            try? FileManager.default.removeItem(at: Self.avatarFileURL)
            return
        }

        // 和 TA 的头像一样：存之前压到 512，别把存档撑大。
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
        #endif
    }
}
