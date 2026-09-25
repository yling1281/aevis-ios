import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 自定义字体的导入、注册与管理。
///
/// 用户可以把自己喜欢的字体文件放进 App，界面字体立刻跟着变；
/// 字号也能整体缩放。**字体归用户，不归我们。**
///
/// iOS 支持「持久注册」（`.persistent`）：注册过的字体下次启动依然可用，
/// 但这里仍然在启动时再注册一遍，避免被系统清理掉之后第一帧找不到字体。
final class FontStore: ObservableObject {
    static let shared = FontStore()

    struct Installed: Identifiable, Hashable, Codable {
        /// PostScript 名，喂给 Font.custom 用的就是它
        var id: String
        /// 给人看的名字
        var displayName: String
        /// 来自哪个文件，删的时候要一起清
        var fileName: String
    }

    /// 字号系数。1.0 是标准大小。
    @Published var scale: Double {
        didSet { UserDefaults.standard.set(scale, forKey: Self.scaleKey) }
    }

    /// 当前选中的自定义字体（PostScript 名）。空字符串 = 用系统字体。
    @Published var selectedPostScriptName: String {
        didSet { UserDefaults.standard.set(selectedPostScriptName, forKey: Self.selectedKey) }
    }

    @Published private(set) var installed: [Installed] = []

    private static let scaleKey = "aevis.fontScale"
    private static let selectedKey = "aevis.fontPostScriptName"
    private static let listKey = "aevis.fontList"

    private let directory: URL

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = support.appendingPathComponent("AevisFonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        scale = defaults.object(forKey: Self.scaleKey) as? Double ?? 1.0
        selectedPostScriptName = defaults.string(forKey: Self.selectedKey) ?? ""
        installed = Self.loadList()

        for font in installed {
            Self.register(url: directory.appendingPathComponent(font.fileName))
        }
    }

    /// 导入时允许的文件类型。
    /// 除了字体扩展名，还放开了 `.data` 和 `.item` ——
    /// 有些字体文件在系统里没有对应的类型标识，会被文件选择器灰掉选不了
    /// （用户反馈「点了没反应」很可能就是这个）。
    ///
    /// ⚠️ 还有一半原因**不在我们这边**：iOS 的「文件」里，
    /// **别的 App 文件夹下的文件系统会直接灰掉**（读不到别人的沙盒），
    /// 那时候点「打开」也是毫无反应。所以界面上的说明文字同样重要。
    static var allowedTypes: [UTType] {
        var types: [UTType] = [.font]
        for ext in ["ttf", "otf", "ttc", "woff", "woff2"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        types.append(.data)
        types.append(.item)
        return types
    }

    // MARK: - 导入 / 删除

    /// 导入失败的原因。**每种都单独说清楚** ——
    /// 之前失败只返回 nil，界面什么都不显示，看起来就像"点了没反应"。
    enum ImportFailure: LocalizedError {
        case unreadable(String)
        case noFontInside(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "「\(name)」读不出来。如果它在 iCloud 里，先下载到本机再试一次。"
            case .noFontInside(let name):
                return "「\(name)」里面没找到可用的字体。iOS 只认 ttf / otf / ttc，"
                    + "woff / woff2 是网页字体，装不了。"
            }
        }
    }

    /// 导入一个字体文件。成功返回显示名；失败**抛出原因**（不要再静默返回 nil）。
    @discardableResult
    func importFont(from url: URL) throws -> String {
        // 从「文件」里选的 URL 需要先取权限，否则读不到
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fileName = url.lastPathComponent
        let target = directory.appendingPathComponent(fileName)

        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw ImportFailure.unreadable(fileName)
        }

        Self.register(url: target)

        let found = Self.descriptors(of: target)
        guard !found.isEmpty else {
            try? FileManager.default.removeItem(at: target)
            throw ImportFailure.noFontInside(fileName)
        }

        var added: [Installed] = []
        for entry in found where !installed.contains(where: { $0.id == entry.id }) {
            added.append(Installed(id: entry.id, displayName: entry.name, fileName: fileName))
        }

        if added.isEmpty {
            // 这个文件里的字体之前就导过，直接选中它
            selectedPostScriptName = found.first?.id ?? selectedPostScriptName
            return found.first?.name ?? fileName
        }

        installed.append(contentsOf: added)
        persistList()
        selectedPostScriptName = added[0].id
        return added[0].displayName
    }

    /// 删掉一个字体（同一文件里的其它字重一起删）。
    func remove(_ font: Installed) {
        let sameFile = installed.filter { $0.fileName == font.fileName }
        if sameFile.contains(where: { $0.id == selectedPostScriptName }) {
            selectedPostScriptName = ""
        }
        installed.removeAll { $0.fileName == font.fileName }
        persistList()

        let url = directory.appendingPathComponent(font.fileName)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .persistent, nil)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 名字

    var selectedDisplayName: String {
        if selectedPostScriptName.isEmpty { return "系统字体" }
        return installed.first(where: { $0.id == selectedPostScriptName })?.displayName
            ?? selectedPostScriptName
    }

    // MARK: - 私有

    private static func register(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var error: Unmanaged<CFError>?
        // 已经注册过会返回 false 并把错误塞进 error，这是正常情况，忽略即可
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .persistent, &error)
    }

    private static func descriptors(of url: URL) -> [(id: String, name: String)] {
        guard let raw = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        var result: [(id: String, name: String)] = []
        for descriptor in raw {
            guard let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
                continue
            }
            let display = (CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String)
                ?? (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String)
                ?? postScript
            result.append((postScript, display))
        }
        return result
    }

    private static func loadList() -> [Installed] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let decoded = try? JSONDecoder().decode([Installed].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistList() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        UserDefaults.standard.set(data, forKey: Self.listKey)
    }
}

extension Font {
    /// 全局字体入口 —— 自定义字体与字号系数都在这里生效。
    ///
    /// **所有界面文字都应该走这个函数**，不要再直接写 `.system(size:)`，
    /// 否则用户换字体/调字号时那一处不会跟着变。
    static func aevis(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let store = FontStore.shared
        let scaled = max(9, size * CGFloat(store.scale))
        if store.selectedPostScriptName.isEmpty {
            return .system(size: scaled, weight: weight)
        }
        return .custom(store.selectedPostScriptName, size: scaled).weight(weight)
    }

    /// 等宽字体：命令台这类地方要用。
    /// **故意不跟随用户的自定义字体**（终端换成宋体就毁了），
    /// 但字号跟随用户的设置，所以它也是一个正经的字体入口。
    static func aevisMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaled = max(9, size * CGFloat(FontStore.shared.scale))
        return .system(size: scaled, weight: weight, design: .monospaced)
    }
}
