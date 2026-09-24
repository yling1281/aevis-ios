import AVFoundation
import Foundation

/// 让 TA 开口说话。
///
/// 音色走系统语音合成（免费、离线、不花钱）。iOS 里可以在
/// 「设置 → 辅助功能 → 朗读内容 → 声音」里下载更高品质的中文音色，
/// 下好之后这里会自动多出可选音色。
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

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

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        Self.activateSession()

        let utterance = AVSpeechUtterance(string: cleaned)
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

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

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
