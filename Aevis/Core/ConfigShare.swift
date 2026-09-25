import CoreImage
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 配置分享：把「模型接入 + 外观」打包成一段文本，用二维码传给别人。
///
/// 为什么做这个：朋友的手机要能用，得先填 API 地址、模型名、外观偏好 ——
/// 一遍遍手输很容易错，也没人愿意。Kelivo 那套就是这么干的，用户点名要同步过来。
///
/// ## 一条硬规矩：默认**不带 API Key**
/// Key 是要花钱的东西。默认只分享「接哪个服务、用哪个模型、界面怎么长」，
/// 使用者自己填自己的 Key。真要连 Key 一起给（比如给自己另一台设备），
/// 得**明确勾上**那个开关，而且界面上会写清风险。
enum ConfigShare {

    /// 一段要传的配置。字段都是可选的，认不出来的一律忽略 ——
    /// 版本不一致时也不能炸，这是基本要求。
    struct Payload: Codable {
        var version: Int = 1
        var provider: String?
        var baseURL: String?
        var model: String?
        /// ⚠️ 只有用户明确同意才会带上来
        var apiKey: String?
        var systemVoice: String?
        var accentIndex: Int?
        var simpleMode: Bool?
        var useGlass: Bool?
        var backgroundStyle: String?
        var personaName: String?
    }

    /// 把当前配置打包成文本。
    /// - Parameter includeKey: 要不要连 API Key 一起带走（默认不带）。
    static func snapshot(includeKey: Bool = false) -> String {
        let settings = AppSettings.shared
        let persona = PersonaStore.shared.persona

        let payload = Payload(
            provider: settings.providerPreset.rawValue,
            baseURL: settings.baseURL,
            model: settings.model,
            apiKey: includeKey && !settings.apiKey.isEmpty ? settings.apiKey : nil,
            systemVoice: persona.voiceIdentifier,
            accentIndex: settings.accentIndex,
            simpleMode: settings.simpleMode,
            useGlass: settings.useGlass,
            backgroundStyle: settings.backgroundStyle.rawValue,
            personaName: persona.name
        )

        let encoder = JSONEncoder()
        // 排序 + 不换行：二维码里一个字符都算钱，短一点是一点
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 把一段文本应用进来。返回一句人话（成功或失败的原因）。
    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "没内容。" }
        guard let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return "这段不是 Aevis 的配置（解不出来）。"
        }

        let settings = AppSettings.shared
        var changed: [String] = []
        var persona = PersonaStore.shared.persona
        var personaTouched = false

        if let provider = payload.provider, let parsed = ProviderPreset(rawValue: provider) {
            settings.providerPreset = parsed
            changed.append("服务商")
        }
        if let base = payload.baseURL, !base.isEmpty {
            settings.baseURL = base
            changed.append("接口地址")
        }
        if let model = payload.model, !model.isEmpty {
            settings.model = model
            changed.append("模型")
        }
        // ⚠️ Key 是**单独一步**，而且只在对方真的带过来时才覆盖 ——
        // 不带 Key 的二维码绝不该把本机已填的 Key 清掉。
        if let key = payload.apiKey, !key.isEmpty {
            settings.apiKey = key
            changed.append("API Key")
        }
        if let voice = payload.systemVoice {
            persona.voiceIdentifier = voice
            personaTouched = true
            changed.append("音色")
        }
        if let accent = payload.accentIndex {
            settings.accentIndex = accent
            changed.append("主题色")
        }
        if let simple = payload.simpleMode {
            settings.simpleMode = simple
            changed.append("简易模式")
        }
        if let glass = payload.useGlass {
            settings.useGlass = glass
            changed.append("玻璃效果")
        }
        if let style = payload.backgroundStyle,
           let parsed = BackgroundStyle(rawValue: style) {
            settings.backgroundStyle = parsed
            changed.append("背景")
        }
        if let name = payload.personaName, !name.isEmpty {
            persona.name = name
            personaTouched = true
            changed.append("名字")
        }
        if personaTouched {
            PersonaStore.shared.update(persona)
        }

        guard !changed.isEmpty else { return "这段配置里没有能用的东西。" }
        return "套用了：" + changed.joined(separator: "、")
            + (payload.apiKey == nil ? "。（这段里没有 API Key，你还是得填自己的）" : "。")
    }

    // MARK: - 二维码

    /// 把一段文本画成二维码。
    ///
    /// 用 `CIFilter(name:)` 这种老写法而不是 `CIFilter.qrCodeGenerator()`：
    /// 后者要 `import CoreImage.CIFilterBuiltins`，多一个 import 就多一处可能编不过。
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        #if canImport(UIKit)
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // M 级容错：被挡住一角也还能认出来
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
        #else
        return nil
        #endif
    }
}
