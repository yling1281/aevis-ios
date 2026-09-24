import AVFoundation
import Foundation

enum TTSError: LocalizedError {
    case notConfigured
    case badURL
    case noVoice
    case emptyAudio
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "外接语音还没有 API Key。"
        case .badURL:
            return "外接语音的接口地址不对。"
        case .noVoice:
            return "还没有选音色。先点「拉取音色」拉一份，或者手动填一个音色 ID。"
        case .emptyAudio:
            return "接口没有返回音频。"
        case let .http(status, body):
            switch status {
            case 401, 403: return "语音接口的 Key 被拒绝（\(status)）。"
            case 404: return "语音接口地址找不到（404），检查是否需要单独的地址。"
            case 400: return "语音接口拒绝了这次请求（400）：\(body.prefix(120))"
            default: return "语音接口返回 \(status)：\(body.prefix(120))"
            }
        }
    }
}

/// 让 TA 开口说话。
///
/// 两种来源：
/// - 系统音色：AVSpeechSynthesizer，免费、离线、不花钱
/// - 外部 API：任何 OpenAI 兼容的 `/audio/speech`，音色更自然，按量计费
///
/// 外接失败会自动退回系统音色，不会让 TA 突然哑掉。
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    private init() {}

    // MARK: - 系统音色

    /// 系统里所有中文音色。名称里带 "premium" / "enhanced" 的更好听。
    /// 传 gender 时，把嗓音性别相符的排在前面，省得在一长串里翻。
    static func chineseVoices(preferring gender: GenderIdentity = .unspecified) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { lhs, rhs in
                let leftMatches = matches(lhs, gender)
                let rightMatches = matches(rhs, gender)
                if leftMatches != rightMatches { return leftMatches }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func matches(_ voice: AVSpeechSynthesisVoice, _ gender: GenderIdentity) -> Bool {
        switch gender {
        case .female: return voice.gender == .female
        case .male: return voice.gender == .male
        case .genderless, .unspecified: return false
        }
    }

    func speak(_ text: String, voiceIdentifier: String, rate: Double) {
        let cleaned = Self.plainText(text)
        guard !cleaned.isEmpty else { return }
        speakSystem(cleaned, voiceIdentifier: voiceIdentifier, rate: rate)
    }

    // MARK: - 统一入口

    /// 按设置决定走系统音色还是外部 API。外接失败会退回系统音色，并通过 onError 告一声。
    func speak(
        _ text: String,
        config: TTSConfig,
        systemVoiceIdentifier: String,
        onError: ((String) -> Void)? = nil
    ) {
        let cleaned = Self.plainText(text)
        guard !cleaned.isEmpty else { return }

        switch config.mode {
        case .system:
            speakSystem(cleaned, voiceIdentifier: systemVoiceIdentifier, rate: config.rate)

        case .remote:
            Task {
                do {
                    try await speakRemote(cleaned, config: config)
                } catch {
                    speakSystem(cleaned, voiceIdentifier: systemVoiceIdentifier, rate: config.rate)
                    let message = error.localizedDescription
                    await MainActor.run { onError?(message) }
                }
            }
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let player, player.isPlaying {
            player.stop()
        }
        player = nil
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || (player?.isPlaying ?? false)
    }

    // MARK: - 系统合成

    private func speakSystem(_ text: String, voiceIdentifier: String, rate: Double) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let player, player.isPlaying {
            player.stop()
            self.player = nil
        }

        Self.activateSession()

        let utterance = AVSpeechUtterance(string: text)
        if !voiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utterance.rate = Float(min(max(rate, 0.30), 0.70))
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        synthesizer.speak(utterance)
    }

    // MARK: - 外接合成

    private func speakRemote(_ text: String, config: TTSConfig) async throws {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TTSError.notConfigured }

        let voice = config.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { throw TTSError.noVoice }

        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw TTSError.badURL }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/audio/speech") {
            base += "/audio/speech"
        }
        guard let url = URL(string: base) else { throw TTSError.badURL }

        // 多数服务对单次输入有上限，截一下免得整段被拒。
        let input = String(text.prefix(1800))

        var payload: [String: Any] = [
            "model": config.model,
            "input": input,
            "voice": voice,
            "response_format": "mp3"
        ]
        // speed 不是所有服务都支持，只在语速明显偏离默认时才带。
        if abs(config.rate - 0.5) > 0.06 {
            payload["speed"] = min(max(config.rate * 2.0, 0.25), 4.0)
        }

        do {
            let audio = try await requestSpeech(url: url, key: key, payload: payload)
            try play(audio)
        } catch TTSError.http(let status, _) where status == 400 {
            // 有些服务不认 response_format，去掉再试一次。
            payload.removeValue(forKey: "response_format")
            let audio = try await requestSpeech(url: url, key: key, payload: payload)
            try play(audio)
        }
    }

    private func requestSpeech(url: URL, key: String, payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw TTSError.http(status: http.statusCode, body: body)
        }
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }

    private func play(_ audio: Data) throws {
        stop()
        Self.activateSession()
        let newPlayer = try AVAudioPlayer(data: audio)
        newPlayer.prepareToPlay()
        newPlayer.play()
        player = newPlayer
    }

    // MARK: - 公共零件

    private static func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // .duckOthers：TA 说话时把音乐自动压低，说完恢复。为以后「一起听」做准备。
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// 去掉 markdown 记号，免得朗读时把星号井号都念出来。
    private static func plainText(_ text: String) -> String {
        var output = text
        for token in ["```", "**", "`", "*", "##", "#", ">", "|", "---"] {
            output = output.replacingOccurrences(of: token, with: "")
        }
        output = output.replacingOccurrences(of: "\n", with: "，")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
