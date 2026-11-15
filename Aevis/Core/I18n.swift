import Foundation

/// 中英文（2026-11-14 用户：「iOS 帮我做下多语言适配，中英文要，安卓也要，小程序也要」）。
///
/// **为什么用「中文原文当 key」而不是 Localizable.strings**：
/// 这个 App 的文案是直接写在 SwiftUI 里的（几千处），改成 `NSLocalizedString("key", ...)`
/// 要重写每一处调用、还要另起一套 key 命名，改漏一处就是空白。
/// 这里 key 就是中文原文：中文时原样返回（**零风险**），英文时查表，
/// 查不到退回中文（不会空白、不会崩）。
///
/// 词典 `Resources/i18n/zh-en.json` 跟安卓 / 小程序**共用同一份**
/// （安卓在 `app/src/main/assets/i18n/zh-en.json`），改文案不用动代码。
///
/// 默认跟随系统语言；用户在「我 → 语言」里手动选过就以手动为准（存 UserDefaults）。
enum L {

    /// "zh" / "en"
    static private(set) var lang: String = {
        if let saved = UserDefaults.standard.string(forKey: "aevis.lang"), !saved.isEmpty {
            return saved
        }
        let code = Locale.preferredLanguages.first ?? "zh"
        return code.hasPrefix("zh") ? "zh" : "en"
    }()

    /// 词典（只加载一次）。
    static let table: [String: String] = {
        // 两种放法都试：XcodeGen 把 `Aevis/Resources/**` 打进 bundle 时，
        // 有的配置会把子目录拍平，有的保留 —— 都兜一下，找不到就空表（退回中文）。
        var url = Bundle.main.url(forResource: "zh-en", withExtension: "json")
        if url == nil {
            url = Bundle.main.url(forResource: "zh-en", withExtension: "json",
                                  subdirectory: "i18n")
        }
        guard let u = url,
              let data = try? Data(contentsOf: u),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj.filter { !$0.key.hasPrefix("_") }
    }()

    /// 纯文案。`L.t("登录")`
    static func t(_ zh: String) -> String {
        lang == "zh" ? zh : (table[zh] ?? zh)
    }

    /// 带变量的文案，词表里写成 `%@` / `%d`。`L.t("编号 %@", id)`
    static func t(_ zh: String, _ args: CVarArg...) -> String {
        let s = t(zh)
        return args.isEmpty ? s : String(format: s, arguments: args)
    }

    /// 当前语言的名字（设置行显示用）。
    static var label: String { lang == "zh" ? "简体中文" : "English" }

    /// 切换并落盘。
    static func set(_ l: String) {
        guard l != lang else { return }
        lang = l
        UserDefaults.standard.set(l, forKey: "aevis.lang")
        NotificationCenter.default.post(name: .aevisLanguageChanged, object: nil)
    }
}

extension Notification.Name {
    /// 语言变了 —— 根视图收到后整棵树重建（`id(L.lang)`）。
    static let aevisLanguageChanged = Notification.Name("aevis.language.changed")
}
