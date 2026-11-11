import Foundation

/// 法律文本的一节（免责声明 / 用户协议共用）。
///
/// 之所以单独抽出来：这些正文要能**从服务端热更新** —— 改一个字不该发一次版。
struct LegalBlock: Identifiable, Codable, Hashable {
    var id: String { title }
    let title: String
    let paragraphs: [String]
    let bullets: [String]

    init(title: String, paragraphs: [String] = [], bullets: [String] = []) {
        self.title = title
        self.paragraphs = paragraphs
        self.bullets = bullets
    }

    // 服务端写 JSON 时可以只写 bullets，不用两边都填
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        paragraphs = try c.decodeIfPresent([String].self, forKey: .paragraphs) ?? []
        bullets = try c.decodeIfPresent([String].self, forKey: .bullets) ?? []
    }
}

/// 一整篇法律文本。
struct LegalDoc: Codable {
    let version: String
    let updated: String
    let blocks: [LegalBlock]
}

/// 拉服务端下发的正文，带本地缓存。
///
/// 策略：**永远先显示内置正文**（保证离线也有内容），拉到远程就替换并缓存；
/// 拉失败就继续用缓存/内置，不弹错、不阻塞页面。
@MainActor
final class DisclaimerStore: ObservableObject {
    static let shared = DisclaimerStore()

    /// 站上的静态 JSON。改这个文件就能改 App 里的免责声明，不用发版。
    /// ⚠️ 走主域，不用 `sucai.aevis.cn` —— 那边整站 301 到主域，白多一次跳转。
    static let remoteURL = URL(string: AevisHosts.accountPlainBase + "/disclaimer.json")

    private static let cacheKey = "legal.disclaimer.doc"

    /// 拉到远程正文后放这儿；nil 表示还没拉到 / 拉失败 —— 页面回退到内置。
    @Published private(set) var remote: LegalDoc?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let doc = try? JSONDecoder().decode(LegalDoc.self, from: data) {
            remote = doc
        }
    }

    /// 页面出现时调一次。失败不抛错（离线用户照样能看内置那份）。
    func refresh() async {
        guard let url = Self.remoteURL else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let doc = try JSONDecoder().decode(LegalDoc.self, from: data)
            guard !doc.blocks.isEmpty else { return }   // 空文档当没拉到，别把页面变空白
            remote = doc
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } catch {
            // 拉不到就保持现状（缓存 / 内置），不打扰用户
        }
    }
}
