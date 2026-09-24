import SwiftUI

/// 「一起听」面板。
///
/// 三种形态在这里切。她的话落在下面 —— **不自动念**，
/// 因为音乐正在放，她再说话会把人声盖掉；想听就点旁边那个小喇叭。
struct TogetherView: View {
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var mode: ListenTogetherMode = .sync

    private var persona: Persona { personaStore.persona }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeSection
                    nowPlaying
                    if together.active {
                        herLines
                    } else {
                        startHint
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("一起听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(together.active ? "结束" : "关闭") {
                        if together.active {
                            together.stop()
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if together.active {
                        Button("让她说一句") {
                            Task { await together.pokeHer() }
                        }
                        .disabled(together.thinking)
                    }
                }
            }
            .onAppear {
                if let saved = ListenTogetherMode(rawValue: settings.listenTogetherMode) {
                    mode = saved
                }
            }
        }
    }

    // MARK: - 形态

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("怎么一起听")
                .font(.aevis(14.5, weight: .medium))
                .foregroundStyle(.primary)

            Picker("形态", selection: $mode) {
                ForEach(ListenTogetherMode.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, value in
                settings.listenTogetherMode = value.rawValue
            }

            Text(mode.explanation)
                .font(.aevis(11.5))
                .foregroundStyle(mode.isImplemented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .fixedSize(horizontal: false, vertical: true)

            if !mode.isImplemented {
                Text("这种形态还没接 —— 它的房间接口需要逆向签名，现在还没有可用实现。先用另外两种。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    if together.active {
                        together.stop()
                    } else {
                        together.start(
                            mode: mode,
                            persona: persona,
                            config: settings.llm,
                            memory: settings.memoryInjectEnabled
                                ? MemoryStore.shared.injectedLines()
                                : []
                        )
                    }
                } label: {
                    Text(together.active ? "结束一起听" : "开始一起听")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(together.active ? Color.red : Color.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }
                .disabled(!mode.isImplemented)

                Spacer(minLength: 0)
            }

            if let status = together.statusLine {
                Text(status)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 正在放

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("正在放")
                .font(.aevis(14.5, weight: .medium))
                .foregroundStyle(.primary)

            if let track = player.current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.primary)
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                    }
                }

                if !player.lyric.isEmpty {
                    Text("「\(player.lyric)」")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 20) {
                    Button {
                        Task { await player.previous() }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.aevis(16))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.aevis(20))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.aevis(16))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            } else {
                Text("还没放歌。先去「音乐」里搜一首，或者直接跟她说「放首歌」。")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 她的话

    private var herLines: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("她跟着听到的")
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                if together.thinking {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 8)
            }

            if together.herLines.isEmpty {
                Text("她还没开口。放一会儿，或者点右上角「让她说一句」。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(together.herLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 9) {
                            AevisAvatar(source: .ai, size: 24, seed: persona.avatarSeed)

                            Text(line)
                                .font(.aevis(14))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 6)

                            // 想听就点一下 —— 不自动念，免得盖住歌
                            Button {
                                together.speak(line)
                            } label: {
                                Image(systemName: "speaker.wave.2")
                                    .font(.aevis(13))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Text("她不会自动念出来 —— 歌在放，再叠一层人声会听不清。想听哪句就点旁边的小喇叭。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var startHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开始之后会发生什么")
                .font(.aevis(14.5, weight: .medium))
                .foregroundStyle(.primary)
            Text("她会跟着歌词走：每唱几句，就接着那一句说一句自己的感觉。说完落在上面那块里，不会打断歌曲。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }
}
