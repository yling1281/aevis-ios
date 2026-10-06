import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 图片解码缓存。
///
/// ⚠️⚠️ **为什么必须要有它**（2026-10-06 排查「聊天卡」）：
/// `UIImage(data:)` 是**重量级操作**（整张 JPEG/PNG 解一遍），而聊天气泡的
/// `body` 在流式回复时**每吐一个 token 就会重算一次** —— 消息里有图的话，
/// 每重算一次就把那张图重解一遍；自定义聊天背景同理（整张背景大图）。
/// 聊得越久、图越多，越卡，而且正好卡在「她正在说话」的时候。
///
/// 键的算法：**前 256 字节 + 后 256 字节 + 总长度** 的哈希。
/// 为什么不用整份 `Data` 的 `hashValue`：那要把几 MB 全读一遍（O(n)），
/// 省下来的解码时间又被哈希吃回去了。为什么不怕撞：两张不同的图，
/// 头尾各 256 字节都一样、长度还一样，概率可以忽略。
/// `data` 一变键就变 ⇒ 不会串图。
enum ImageDecodeCache {
    #if canImport(UIKit)
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        return cache
    }()

    /// 解码（命中缓存就直接拿）。传进来的 `data` 变了、键会跟着变，不会串图。
    static func image(for data: Data) -> UIImage? {
        guard !data.isEmpty else { return nil }
        let key = Self.key(for: data)
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }
    #endif

    private static func key(for data: Data) -> NSString {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let head = min(raw.count, 256)
            hasher.combine(bytes: UnsafeRawBufferPointer(start: base, count: head))
            if raw.count > 256 {
                let tail = min(raw.count - 256, 256)
                hasher.combine(bytes: UnsafeRawBufferPointer(
                    start: base.advanced(by: raw.count - tail),
                    count: tail
                ))
            }
        }
        return "\(data.count)-\(hasher.finalize())" as NSString
    }
}
