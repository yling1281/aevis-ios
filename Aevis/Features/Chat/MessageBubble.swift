import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 气泡
//
// 从 ChatView.swift 抽出来，单独成文件 —— 原文件已经 50KB+，气泡本身又是
// 聊天页最复杂的一块，拆开两边都好读。微信风走 `AevisBubble`，iMessage 风
// 在这里独立渲染。

/// 气泡外观的一份快照。父视图取好传下来，
/// 气泡本身只负责画 —— 这样两侧气泡能各改各的，互不影响。
struct BubbleTheme {
    var myLook: BubbleLook
    var aiLook: BubbleLook
    var myColor: Color
    var aiColor: Color
    var cornerScale: Double
    var fontColor: Color
    var showMyAvatar: Bool
    var showAiAvatar: Bool
    /// 界面密度（0.82 紧凑 / 1.0 标准 / 1.22 宽松）。只乘在留白上。
    var density: Double = 1.0
    /// 聊天主题：微信风走原来的 `AevisBubble`，iMessage 风走独立渲染。
    var theme: ChatTheme = .wechat
}

/// 一通电话留下的记录 —— 微信那种**居中、淡淡的一行小字**。
///
/// 用户 2026-09-26：「挂断电话的时候……像微信一样留下记录」。
///
/// **故意不做成聊天气泡**：那不是谁说的话，做成气泡会让人误以为
/// ta真的发过「通话时长 03:21」这么一条消息。
struct CallRecordBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 10.5, weight: .medium))
            Text(text)
                .font(.aevis(12))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.primary.opacity(0.06))
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let persona: Persona
    var theme: BubbleTheme
    var simpleMode: Bool = false

    /// 订阅表情包 —— 判断这一条是不是"就是一个表情"要靠它。
    ///
    /// ⚠️ 必须声明在**这个** struct 里：`sticker` / `bigSticker` 都属于这里，
    /// 声明到外层的 ChatView 上，这里就找不到 `emoji` 了（真踩过，整轮编译失败）。
    @ObservedObject private var emoji = EmojiPack.shared

    /// 靠着屏幕那一边至少留这么多空白（也顺手限制了气泡宽度）。
    /// 用「单侧 Spacer 的 minLength」而不是写死像素宽度，这样任何屏幕尺寸都自适应。
    /// 两侧都留 54：一边是头像 26 + 间距 8 + 20，另一边对称。
    private static let sideGap: CGFloat = 54

    private var isUser: Bool { message.role == .user }

    private var look: BubbleLook { isUser ? theme.myLook : theme.aiLook }
    private var color: Color { isUser ? theme.myColor : theme.aiColor }

    private var bubbleFontSize: CGFloat { simpleMode ? 17.5 : 15.5 }
    private var horizontalPadding: CGFloat { (simpleMode ? 16 : 14) * CGFloat(theme.density) }
    private var verticalPadding: CGFloat { (simpleMode ? 13 : 10) * CGFloat(theme.density) }
    private var avatarSize: CGFloat { simpleMode ? 30 : 26 }

    /// 基础圆角再乘两层系数：全局的 + 这一侧自己的。
    private var bubbleCorner: CGFloat {
        let base: CGFloat = simpleMode ? 20 : 18
        let scaled = theme.cornerScale * look.cornerScale
        return max(6, base * CGFloat(scaled))
    }

    /// 整条消息就是一个表情 —— 像微信那样**放大显示**，不套气泡。
    ///
    /// 「一个表情」有两种写法：ta自己写的 `[微笑]`，或者ta直接发一个表情符号。
    /// 判断交给 EmojiPack —— 表情在设置里被关掉时，这里自然就都不算表情了。
    private var sticker: EmojiPack.Item? {
        emoji.single(in: message.text)
    }

    private func emojiText(_ item: EmojiPack.Item) -> some View {
        Text(item.emoji)
            .font(.aevis(simpleMode ? 56 : 48))
            .padding(.vertical, 2)
    }

    /// 大表情：**导入了自己的表情图就用图**（微信 / QQ 那套），没导就用表情符号。
    @ViewBuilder
    private func bigSticker(_ item: EmojiPack.Item) -> some View {
        #if canImport(UIKit)
        if let image = emoji.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: simpleMode ? 148 : 128, maxHeight: simpleMode ? 148 : 128)
                .padding(.vertical, 2)
        } else {
            emojiText(item)
        }
        #else
        emojiText(item)
        #endif
    }

    // MARK: - 微信风

    @ViewBuilder
    private var bubble: some View {
        #if canImport(UIKit)
        if message.kind == .voice {
            voiceBubble
        } else if let data = message.imageData, let image = UIImage(data: data) {
            // 图就是这条消息的全部内容 —— 那张图里 OCR 出来的文字在
            // `message.text` 里，是**给ta看的**，不该再显示一遍。
            pictureBubble(image)
        } else if let sticker {
            bigSticker(sticker)
        } else {
            textBubble
        }
        #else
        if let sticker {
            bigSticker(sticker)
        } else {
            textBubble
        }
        #endif
    }

    /// ⭐ 语音条（2026-09-30）：点一下播放/停止。
    @State private var voicePlayer: AVAudioPlayer?
    @State private var voicePlaying = false

    private var voiceBubble: some View {
        HStack(spacing: 8) {
            Button(action: toggleVoice) {
                Image(systemName: voicePlaying ? "stop.fill" : "play.fill")
                    .font(.aevis(14, weight: .semibold))
            }
            .buttonStyle(.plain)

            Text(voiceLabel)
                .font(.aevis(13))
                .monospacedDigit()
        }
        .foregroundStyle(theme.fontColor)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous).fill(color)
        )
    }

    private var voiceLabel: String {
        guard let d = message.voiceDuration, d > 0 else { return "语音" }
        return "\(Int(d.rounded()))″"
    }

    private func toggleVoice() {
        guard let data = message.voiceData else { return }
        if let p = voicePlayer, p.isPlaying {
            p.stop()
            voicePlayer = nil
            voicePlaying = false
            return
        }
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.play()
        voicePlayer = p
        voicePlaying = true
        let deadline = p.duration + 0.25
        // ⚠️ MessageBubble 是 struct（值类型），闭包不能写 [weak self]（编译报
        //    'weak' may only be applied to class types）。直接捕获 self 即可，
        //    @State 内部是引用语义，赋值仍会正确更新 UI。
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
            if voicePlayer === p {
                voicePlaying = false
                voicePlayer = nil
            }
        }
    }

    private var textBubble: some View {
        AevisBubble(
            text: message.text,
            look: look,
            color: color,
            corner: bubbleCorner,
            fontSize: bubbleFontSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            plainTextColor: theme.fontColor
        )
    }

    #if canImport(UIKit)
    /// 聊天里那张图。
    ///
    /// 用 `Color.clear` 撑尺寸、图放 overlay —— 跟背景图一个路子。
    /// 直接把 `scaledToFill` 摆进布局里会把整棵布局撑大（这条踩过）。
    private func pictureBubble(_ image: UIImage) -> some View {
        let size = Self.pictureSize(for: image)
        return Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            )
            .clipShape(RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    /// 图上显示的尺寸：按原始比例缩到框里，不拉伸。
    private static func pictureSize(for image: UIImage) -> CGSize {
        let maxWidth: CGFloat = 200
        let maxHeight: CGFloat = 260
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return CGSize(width: 120, height: 120) }
        let scale = min(maxWidth / width, maxHeight / height, 1)
        return CGSize(width: max(60, width * scale), height: max(60, height * scale))
    }
    #endif

    // MARK: - iMessage 风
    //
    // ⚠️ 不走 `AevisBubble.solid`：它会按背景亮度算字色，半透明黑会被误判成
    // 深色、给白字。iMessage 分支在这里显式写字色。

    /// iMessage「我」蓝底、「ta」半透明浅灰底。
    private var imessageBackground: Color {
        isUser ? ImessagePalette.blue : ImessagePalette.incoming
    }

    /// 我的气泡白字；ta 的跟随系统（浅底上用 .primary 最稳）。
    private var imessageTextColor: Color {
        isUser ? Color.white : Color.primary
    }

    private var imessageDisplayText: String {
        message.text.isEmpty ? "…" : emoji.render(message.text)
    }

    private var imessageTextBubble: some View {
        Text(imessageDisplayText)
            .font(.aevis(bubbleFontSize))
            .foregroundStyle(imessageTextColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                    .fill(imessageBackground)
            )
    }

    /// iMessage 的语音条：同一套播放逻辑，只换配色。
    private var imessageVoiceBubble: some View {
        HStack(spacing: 8) {
            Button(action: toggleVoice) {
                Image(systemName: voicePlaying ? "stop.fill" : "play.fill")
                    .font(.aevis(14, weight: .semibold))
            }
            .buttonStyle(.plain)

            Text(voiceLabel)
                .font(.aevis(13))
                .monospacedDigit()
        }
        .foregroundStyle(imessageTextColor)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                .fill(imessageBackground)
        )
    }

    /// iMessage 的表情贴图：透明无边框，图 contain，宽不超过 176。
    @ViewBuilder
    private func imessageSticker(_ item: EmojiPack.Item) -> some View {
        #if canImport(UIKit)
        if let image = emoji.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 176, maxHeight: 176)
        } else {
            emojiText(item)
        }
        #else
        emojiText(item)
        #endif
    }

    @ViewBuilder
    private var imessageBubble: some View {
        #if canImport(UIKit)
        if message.kind == .voice {
            imessageVoiceBubble
        } else if let data = message.imageData, let image = UIImage(data: data) {
            pictureBubble(image)
        } else if let sticker {
            imessageSticker(sticker)
        } else {
            imessageTextBubble
        }
        #else
        if let sticker {
            imessageSticker(sticker)
        } else {
            imessageTextBubble
        }
        #endif
    }

    // MARK: - 行

    var body: some View {
        if theme.theme == .imessage {
            imessageRow
        } else {
            row
        }
    }

    @ViewBuilder
    private var row: some View {
        if isUser {
            // 只放一个 Spacer。放两个的话剩余空白会被平分，气泡就飘到中间去了。
            HStack(alignment: .bottom, spacing: 8) {
                Spacer(minLength: Self.sideGap)
                bubble
                if theme.showMyAvatar {
                    AevisAvatar(source: .me, size: avatarSize)
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if theme.showAiAvatar {
                    AevisAvatar(source: .ai, size: avatarSize, seed: persona.avatarSeed)
                }
                bubble
                Spacer(minLength: Self.sideGap)
            }
        }
    }

    @ViewBuilder
    private var imessageRow: some View {
        if isUser {
            HStack(alignment: .bottom, spacing: 8) {
                Spacer(minLength: Self.sideGap)
                imessageBubble
                if theme.showMyAvatar {
                    AevisAvatar(source: .me, size: avatarSize)
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if theme.showAiAvatar {
                    AevisAvatar(source: .ai, size: avatarSize, seed: persona.avatarSeed)
                }
                imessageBubble
                Spacer(minLength: Self.sideGap)
            }
        }
    }
}
