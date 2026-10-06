import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 朋友圈。原生实现，不接任何第三方。
///
/// 两个人：我，和 ta。
/// ta能自己发（打开 App 时补发 / 聊天里被要求发 / 也能回我的评论）。
struct MomentsView: View {
    @ObservedObject private var moments = MomentStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared
    /// 我的名字 / 头像 / 个性签名 —— 「我在 ta 朋友圈里的样子」。
    @ObservedObject private var profile = ProfileStore.shared

    @Environment(\.dismiss) private var dismiss

    /// 从「发现」进来时，是 MainTabView 用**自定义转场**呈现的
    /// （为了做成微信那种「从右边滑进来」）—— 那种方式不走 fullScreenCover，
    /// 所以 `dismiss()` 在里面是失效的，得由外面把关闭动作传进来。
    /// 从设置里的「朋友圈」卡进来时是 fullScreenCover，那时它保持 nil。
    var onClose: (() -> Void)?

    /// 关掉自己。两种呈现方式都要能用。
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    @State private var draft = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var pendingImage: UIImage?

    @State private var commentingOn: Moment?
    @State private var commentDraft = ""
    /// 这条评论是回复谁的（nil = 直接评论动态）。
    @State private var replyToName: String?

    // —— 封面：微信那样，半屏通栏、无圆角 ——
    //
    // #26（用户 2026-09-30）推翻了 #19：「朋友圈你不要这样放大缩小，就是跟微信一样的」。
    // 所以撤掉「往下拉长高」「点一下全屏」，改成**固定半屏高**的通栏封面，
    // 右下角放 头像+名字+签名。
    @State private var viewportHeight: CGFloat = 600

    @State private var busy = false
    @State private var note: String?
    @State private var showClearConfirm = false
    /// 「装扮朋友圈」开没开。
    @State private var showDecor = false

    private var persona: Persona { personaStore.persona }

    // MARK: - 界面个性化（用户要求：朋友圈的外观也要能自己调）

    /// 字号缩放。
    private var fontScale: CGFloat { CGFloat(settings.momentFontScale) }

    /// 朋友圈里的字一律走这个 —— 这样"字号"那个开关一调，整页都跟着变，
    /// 不会出现"标题变了、时间没变"这种半拉子效果。
    private func mfont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .aevis(size * fontScale, weight: weight)
    }

    /// 卡片疏密：0 紧凑 / 1 标准 / 2 宽松。
    private var density: Int { min(max(settings.momentDensityIndex, 0), 2) }
    private var cardSpacing: CGFloat { [10, 14, 20][density] }
    private var cardCorner: CGFloat { CGFloat(settings.momentCorner) }

    /// 时间文字。两种口径由用户选：
    ///   relative → 刚刚 / 3 分钟前 / 2 小时前
    ///   clock    → 今天的写 21:04，更早的写 9-23 21:04
    private func timeText(_ date: Date) -> String {
        guard settings.momentTimeStyle == "clock" else { return Self.relative(date) }
        let calendar = Calendar.current
        let formatter = Self.clockFormatter
        formatter.dateFormat = calendar.isDateInToday(date) ? "HH:mm" : "M-d HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // 封面通栏（半屏、无圆角），单独占一行；下面那些才有左右留白。
                coverHeader

                LazyVStack(spacing: cardSpacing) {
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
            // ⚠️ 用新的 `.coordinateSpace(.named(_:))`：老写法
            //    `.coordinateSpace(name:)` 在 iOS 17 起是**废弃 API**，会出编译警告
            //    （这个项目的规矩是构建日志 0 警告）。
            .coordinateSpace(.named("momentsScroll"))
            // 内容不满一屏时也要能往下拖（否则拉不动封面）
            .scrollBounceBehavior(.always, axes: .vertical)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in
                            viewportHeight = height
                        }
                }
            )
            .navigationTitle("朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 返回键放**左边**，跟微信一样。
                // ⚠️ 以前这里是「关闭」放右边 —— 那是弹窗的习惯；
                // 现在朋友圈是"从右边滑进来的一整页"，返回键必须在左上。
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("返回")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await askHerToPost() }
                        } label: {
                            Label("让 ta 发一条", systemImage: "sparkles")
                        }
                        .disabled(busy || !settings.isConfigured)

                        Button {
                            showDecor = true
                        } label: {
                            Label("装扮朋友圈", systemImage: "paintbrush")
                        }

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
            .sheet(isPresented: $showDecor) {
                MomentsDecorSheet()
            }
            .alert(commentAlertTitle, isPresented: Binding(
                get: { commentingOn != nil },
                set: { if !$0 { commentingOn = nil; replyToName = nil } }
            )) {
                TextField("说点什么…", text: $commentDraft, axis: .vertical)
                Button("发出去") { submitComment() }
                Button("取消", role: .cancel) { commentingOn = nil; replyToName = nil }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
        }
        // ⚠️ 朋友圈现在**是自绘的一整页**（不再走 fullScreenCover 的"从下往上弹"），
        // 所以必须自己铺一层不透明背景 —— 否则下面那四个 tab 会从缝里透出来，
        // 看着像"页面没铺满"。
        // 用 AevisBackground 而不是写死颜色：用户换过自定义背景的话，这里跟着变。
        .background(AevisBackground().ignoresSafeArea())
    }

    // MARK: - 我发一条

    /// 封面当前该多高。#26：固定半屏（取可视区的 42%），不再随拖动/点击变。
    private var coverHeight: CGFloat {
        max(220, viewportHeight * 0.42)
    }

    /// 朋友圈封面 —— 微信那种：半屏通栏、无圆角，右下角 头像+名字+签名。
    ///
    /// **没设封面图就不显示**（不留一块空白占地方）。
    @ViewBuilder
    private var coverHeader: some View {
        if let data = settings.momentCoverData, let image = UIImage(data: data) {
            Color.clear
                .frame(height: coverHeight)
                .overlay(Image(uiImage: image).resizable().scaledToFill())
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [Color.black.opacity(0.02), Color.black.opacity(0.55)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                // 右下角：名字在头像左边，签名在名字下面。
                .overlay(alignment: .bottomTrailing) {
                    HStack(alignment: .bottom, spacing: 9) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(displayName(for: .me))
                                .font(mfont(16, weight: .semibold))
                                .foregroundStyle(.white)
                            if !profile.signature.isEmpty {
                                Text(profile.signature)
                                    .font(mfont(12))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                        }
                        AevisAvatar(source: .me, size: 62)
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                }
        }

        if settings.momentCoverData == nil, !settings.momentSignature.isEmpty {
            Text(settings.momentSignature)
                .font(mfont(14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .aevisGlass(cornerRadius: cardCorner)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AevisAvatar(source: .me, size: 34)

                TextField("说点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(mfont(15))
                    .padding(.vertical, 6)
            }

            // 我的**个性签名**（用户 2026-09-28 要的）——
            // 挂在我自己那一行下面。改的地方在「我 → 我的资料」或者「装扮朋友圈」。
            if !profile.signature.isEmpty {
                Text(profile.signature)
                    .font(mfont(12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
                    .fixedSize(horizontal: false, vertical: true)
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
                            .font(mfont(13))
                            .foregroundStyle(.red)
                    }

                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label("图", systemImage: "photo")
                        .font(mfont(14))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .aevisGlass(cornerRadius: 12)
                }
                .tint(Color.primary)

                Spacer(minLength: 0)

                Button(action: postMine) {
                    Text("发表")
                        .font(mfont(14, weight: .semibold))
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
        .aevisGlass(cornerRadius: cardCorner)
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

        // 我发完ta就来看一眼：点赞 + 评论。条数由设置控制，不会一口气刷一屏。
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
                .font(mfont(30))
                .foregroundStyle(.tertiary)
            Text("这里还空着")
                .font(mfont(16, weight: .medium))
                .foregroundStyle(.primary)
            Text(settings.momentsEnabled
                 ? "\(Pronoun.current)过一会儿就会发一条。你也可以先发。"
                 : "在设置里打开「让\(Pronoun.current)自己发」，\(Pronoun.current)就会时不时发一条。")
                .font(mfont(13))
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
                        .font(mfont(14.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(timeText(moment.createdAt))
                        .font(mfont(11.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Button {
                    moments.toggleLike(moment)
                } label: {
                    Image(systemName: moment.likes.contains(.me) ? "heart.fill" : "heart")
                        .font(mfont(14))
                        .foregroundStyle(moment.likes.contains(.me) ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(moment.author.isMe)
            }

            if !moment.text.isEmpty {
                Text(moment.text)
                    .font(mfont(15))
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
                                .font(mfont(10))
                                .foregroundStyle(.red)
                            Text(moment.likes.map { displayName(for: $0) }.joined(separator: "、"))
                                .font(mfont(12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(moment.comments) { comment in
                        HStack(alignment: .top, spacing: 5) {
                            Text(commentLabel(comment))
                                .font(mfont(12.5, weight: .medium))
                                .foregroundStyle(comment.author.isMe
                                                 ? settings.accentColor
                                                 : .primary)
                            Text(comment.text)
                                .font(mfont(12.5))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 点一条评论 = **回复它**（用户 2026-09-28：「朋友圈有回复功能」）。
                        // 用"点"而不是再加个按钮：评论行本来就窄，塞按钮会挤成一团。
                        .contentShape(Rectangle())
                        .onTapGesture {
                            replyToName = displayName(for: comment.author)
                            commentDraft = ""
                            commentingOn = moment
                        }
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
                    replyToName = nil
                    commentingOn = moment
                } label: {
                    Label("评论", systemImage: "bubble.right")
                        .font(mfont(12.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: cardCorner)
        // ScrollView 里没有 List，所以删除走长按菜单，不用 swipeActions
        .contextMenu {
            Button(role: .destructive) {
                moments.remove(moment)
            } label: {
                Label("删掉这条", systemImage: "trash")
            }
        }
    }

    /// 弹窗标题：回复某个人时写清楚回的是谁，不然容易发错人。
    private var commentAlertTitle: String {
        guard let replyToName, !replyToName.isEmpty else { return "评论" }
        return "回复 \(replyToName)"
    }

    /// 评论那一行的"谁说的"—— 回复别人时带上「回复 XX」。
    private func commentLabel(_ comment: MomentComment) -> String {
        let who = displayName(for: comment.author)
        if let target = comment.replyTo, !target.isEmpty {
            return "\(who) 回复 \(target)："
        }
        return who + "："
    }

    private func displayName(for author: Moment.Author) -> String {
        if author.isMe {
            let mine = ProfileStore.shared.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            return mine.isEmpty ? "我" : mine
        }
        return persona.name.isEmpty ? "ta" : persona.name
    }

    // MARK: - 动作

    /// 评完之后让ta回一句 —— 说了要有反应，不是自己对着墙说话。
    private func submitComment() {
        guard let moment = commentingOn else { return }
        let text = commentDraft
        let target = replyToName
        commentingOn = nil
        replyToName = nil

        moments.comment(text, on: moment, author: .me, replyTo: target)

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
            note = "\(Pronoun.current)这次没写出来（检查一下模型接入）。"
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

    /// 「时钟口径」用的格式化器。⚠️ 做成 static 是为了别每条动态都新建一个 ——
    /// DateFormatter 的构造很贵，列表里几十条就是几十次。
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
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
