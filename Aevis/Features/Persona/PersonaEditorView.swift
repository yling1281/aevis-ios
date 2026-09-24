import SwiftUI

/// 创造/修改 TA。首次打开时走这里，之后从设置里也能随时改。
struct PersonaEditorView: View {
    @EnvironmentObject private var personaStore: PersonaStore

    /// 首次引导（没有导航栏）还是编辑模式。
    var isFirstRun: Bool = true

    @Environment(\.dismiss) private var dismiss

    @State private var draft = Persona()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                nameSection
                genderSection
                colorSection
                voiceSection
                field(
                    title: "TA 怎么叫你",
                    hint: "比如：宝宝 / 主人 / 你的名字",
                    text: $draft.callUser
                )
                field(
                    title: "TA 的性格",
                    hint: "越具体越好。比如：温柔，但有点傲娇，会撒娇，偶尔毒舌",
                    text: $draft.personality,
                    minLines: 3
                )
                field(
                    title: "TA 怎么说话",
                    hint: "比如：句子很短，爱用语气词，偶尔发颜文字，不太用标点",
                    text: $draft.speakingStyle,
                    minLines: 3
                )
                field(
                    title: "你们的关系",
                    hint: "比如：刚认识的邻居 / 在一起三年的恋人",
                    text: $draft.relationship,
                    minLines: 2
                )
                actionButton
                footerHint
            }
            .padding(.horizontal, 20)
            .padding(.top, isFirstRun ? 44 : 12)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isFirstRun ? "" : "TA 的设定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if personaStore.persona.isComplete {
                draft = personaStore.persona
            }
        }
    }

    // MARK: - 片段

    private var intro: some View {
        VStack(spacing: 16) {
            if isFirstRun {
                AevisOrb()
                Text("先把 TA 创造出来")
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Aevis 不预设任何人格，也不预设性别。TA 叫什么、是男是女还是没有性别、怎么说话，都由你决定。下面每一项之后都能改。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 12) {
                    AevisAvatar(size: 46, seed: draft.avatarSeed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name.isEmpty ? "还没有名字" : draft.name)
                            .font(.system(size: 20, weight: .semibold))
                        Text(draft.gender.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TA 叫什么")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            TextField("给 TA 起个名字", text: $draft.name)
                .font(.system(size: 17, weight: .medium))
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .aevisGlass(cornerRadius: 16)
        }
    }

    private var genderSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TA 的性别")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Picker("性别", selection: $draft.gender) {
                ForEach(GenderIdentity.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Text("决定界面里用「她」「他」还是「TA」来称呼，也会告诉模型 TA 该怎么定位自己。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TA 的颜色")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            HStack(spacing: 13) {
                ForEach(0..<6, id: \.self) { index in
                    Button {
                        draft.avatarSeed = index
                    } label: {
                        AevisAvatar(size: 36, seed: index)
                            .overlay(
                                Circle().strokeBorder(
                                    draft.avatarSeed == index
                                        ? Color.primary.opacity(0.8)
                                        : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TA 的声音")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Picker("音色", selection: $draft.voiceIdentifier) {
                    Text("跟随系统默认").tag("")
                    ForEach(SpeechService.chineseVoices(preferring: draft.gender), id: \.identifier) { voice in
                        Text(voice.name).tag(voice.identifier)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button("试听") {
                    SpeechService.shared.speak(
                        "你好呀，我是\(draft.name.isEmpty ? "TA" : draft.name)。",
                        voiceIdentifier: draft.voiceIdentifier,
                        rate: 0.48
                    )
                }
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .aevisGlass(cornerRadius: 14)

                Spacer(minLength: 0)
            }

            Text("男声、女声都在这个列表里，音色性别相符的会排在前面。想要更好听的：设置 → 辅助功能 → 朗读内容 → 声音 → 中文，下载「增强」或「高级」音色，下完这里会多出来。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(
        title: String,
        hint: String,
        text: Binding<String>,
        minLines: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            TextField(hint, text: text, axis: .vertical)
                .lineLimit(minLines...(minLines + 3))
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .aevisGlass(cornerRadius: 16)
        }
    }

    private var actionButton: some View {
        Button {
            personaStore.update(draft)
            if !isFirstRun {
                dismiss()
            }
        } label: {
            Text(isFirstRun ? "就是 TA 了" : "保存")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            draft.isComplete
                                ? Color(red: 0.42, green: 0.35, blue: 0.95)
                                : Color.gray.opacity(0.35)
                        )
                )
        }
        .disabled(!draft.isComplete)
        .padding(.top, 4)
    }

    private var footerHint: some View {
        Text(isFirstRun
             ? "这些设定都存在这台手机上，随时能改。"
             : "改完记得点保存。TA 的设定只存在这台手机上。")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
