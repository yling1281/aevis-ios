import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 朋友圈。原生实现，不接任何第三方。
///
/// 两个人：我，和 TA。
/// 她能自己发（打开 App 时补发 / 聊天里被要求发 / 也能回我的评论）。
struct MomentsView: View {
    @ObservedObject private var moments = MomentStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var pendingImage: UIImage?

    @State private var commentingOn: Moment?
    @State private var commentDraft = ""

    @State private var busy = false
    @State private var note: String?
    @State private var showClearConfirm = false

    private var persona: Persona { personaStore.persona }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    composer

                    if moments.moments.isEmpty {
                        emptyState
                    }

                    ForEach(moments.moments) { moment in
                        card(moment)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            Task { await askHerToPost() }
                        } label: {
                            Label("让 TA 发一条", systemImage: "sparkles")
                        }
                        .disabled(busy || !settings.isConfigured)

                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空朋友圈", systemImage: "trash")
                        }
                        .disabled(moments.moments.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .confirmationDialog(
                "清空朋友圈？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) { moments.clear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有动态和图片都会删掉。这个操作不能撤销。")
            }
            .alert("评论", isPresented: Binding(
                get: { commentingOn != nil },
                set: { if !$0 { commentingOn = nil } }
            )) {
                TextField("说点什么…", text: $commentDraft, axis: .vertical)
                Button("发出去") { submitComment() }
                Button("取消", role: .cancel) { commentingOn = nil }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
        }
    }

    // MARK: - 我发一条

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AevisAvatar(source: .me, size: 34)

                TextField("说点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.aevis(15))
                    .padding(.vertical, 6)
            }

            if let image = pendingImage {
                HStack(spacing: 10) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button {
                        pendingImage = nil
                    } label: {
                        Text("不要这张")
                            .font(.aevis(13))
                            .foregroundStyle(.red)
                    }

                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label("图", systemImage: "photo")
                        .font(.aevis(14))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .aevisGlass(cornerRadius: 12)
                }
                .tint(Color.primary)

                Spacer(minLength: 0)

                Button(action: postMine) {
                    Text("发表")
                        .font(.aevis(14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(canPost ? settings.accentColor : Color.gray.opacity(0.35))
                        )
                }
                .disabled(!canPost)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var canPost: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }

    private func postMine() {
        guard canPost, let moment = moments.post(text: draft, author: .me, image: pendingImage) else {
            return
        }
        draft = ""
        pendingImage = nil
        note = nil

        // 我发完她就来看一眼：点赞 + 评论。条数由设置控制，不会一口气刷一屏。
        let config = settings.llm
        let who = persona
        let memory = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        Task { @MainActor in
            await moments.reactToMyMoment(
                moment: moment,
                persona: who,
                config: config,
                memory: memory
            )
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.aevis(30))
                .foregroundStyle(.tertiary)
            Text("这里还空着")
                .font(.aevis(16, weight: .medium))
                .foregroundStyle(.primary)
            Text(settings.momentsEnabled
                 ? "她过一会儿就会发一条。你也可以先发。"
                 : "在设置里打开「让她自己发」，她就会时不时发一条。")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 30)
    }

    // MARK: - 一条动态

    private func card(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AevisAvatar(
                    source: moment.author.isMe ? .me : .ai,
                    size: 36,
                    seed: persona.avatarSeed
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: moment.author))
                        .font(.aevis(14.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(Self.relative(moment.createdAt))
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Button {
                    moments.toggleLike(moment)
                } label: {
                    Image(systemName: moment.likes.contains(.me) ? "heart.fill" : "heart")
                        .font(.aevis(14))
                        .foregroundStyle(moment.likes.contains(.me) ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(moment.author.isMe)
            }

            if !moment.text.isEmpty {
                Text(moment.text)
                    .font(.aevis(15))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let image = moments.image(for: moment) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !moment.likes.isEmpty || !moment.comments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !moment.likes.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "heart.fill")
                                .font(.aevis(10))
                                .foregroundStyle(.red)
                            Text(moment.likes.map { displayName(for: $0) }.joined(separator: "、"))
                                .font(.aevis(12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(moment.comments) { comment in
                        HStack(alignment: .top, spacing: 5) {
                            Text(displayName(for: comment.author) + "：")
                                .font(.aevis(12.5, weight: .medium))
                                .foregroundStyle(comment.author.isMe
                                                 ? settings.accentColor
                                                 : .primary)
                            Text(comment.text)
                                .font(.aevis(12.5))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }

            HStack(spacing: 14) {
                Button {
                    commentDraft = ""
                    commentingOn = moment
                } label: {
                    Label("评论", systemImage: "bubble.right")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
        // ScrollView 里没有 List，所以删除走长按菜单，不用 swipeActions
        .contextMenu {
            Button(role: .destructive) {
                moments.remove(moment)
            } label: {
                Label("删掉这条", systemImage: "trash")
            }
        }
    }

    private func displayName(for author: Moment.Author) -> String {
        if author.isMe {
            let mine = ProfileStore.shared.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            return mine.isEmpty ? "我" : mine
        }
        return persona.name.isEmpty ? "TA" : persona.name
    }

    // MARK: - 动作

    /// 评完之后让她回一句 —— 说了要有反应，不是自己对着墙说话。
    private func submitComment() {
        guard let moment = commentingOn else { return }
        let text = commentDraft
        commentingOn = nil

        moments.comment(text, on: moment, author: .me)

        let config = settings.llm
        let prompt = persona
        let memory = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        Task { @MainActor in
            await moments.replyToMyComment(
                on: moment,
                myComment: text,
                persona: prompt,
                config: config,
                memory: memory
            )
        }
    }

    private func askHerToPost() async {
        guard !busy else { return }
        busy = true
        note = nil
        defer { busy = false }

        let config = settings.llm
        let memory = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []

        if await moments.generateAndPost(persona: persona, config: config, memory: memory) == nil {
            note = "她这次没写出来（检查一下模型接入）。"
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        Task { @MainActor in
            defer { pickedPhoto = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                note = "这张图读不出来，换一张试试。"
                return
            }
            pendingImage = image
        }
    }

    // MARK: - 时间

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        if elapsed < 86400 * 7 { return "\(Int(elapsed / 86400)) 天前" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
