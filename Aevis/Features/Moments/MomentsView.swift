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
    /// 底部评论条的焦点 —— 点「评论」要直接把键盘顶起来。
    @FocusState private var commentFocused: Bool

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
    /// 全屏发布页（右上角三点 → 发布朋友圈）
    @State private var showCompose = false

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

                // 2026-10-31 用户：「我要的是微信朋友圈那种信息流」。
                // 微信是**通栏一行一条 + 细分隔线**，没有卡片、没有圆角、没有间距。
                // 所以这里 spacing 归 0、去掉左右留白，每条后面插一根分隔线（左侧缩进）。
                LazyVStack(spacing: 0) {
                    // 🔴 2026-11-12 用户：「朋友圈的那些历史残留你还是在」——
                    //    顶部那个"说点什么…+发表"的输入卡就是残留。微信朋友圈没有它，
                    //    发动态只从右上角相机进（全屏 MomentsComposeView）。
                    //    这里删掉后，信息流第一行就是动态本身。

                    if moments.moments.isEmpty {
                        emptyState
                    }

                    ForEach(moments.moments) { moment in
                        feedRow(moment)
                        feedDivider
                    }
                }
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
                        // 2026-11-12 用户：「右边上面三个点要再加一个发布朋友圈，
                        // 做一个全屏的二级菜单，在那里面去发布」。
                        Button {
                            showCompose = true
                        } label: {
                            Label("发布朋友圈", systemImage: "square.and.pencil")
                        }

                        Divider()

                        Button {
                            Task { await askHerToPost() }
                        } label: {
                            Label("让 ta 发一条", systemImage: "sparkles")
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
            .fullScreenCover(isPresented: $showCompose) {
                MomentsComposeView { text, image, audience, ids in
                    // 我的一条
                    _ = moments.post(text: text, author: .me,
                                     image: image, audience: audience)
                    // 「所有人一起发」：选中的每个人各来一条同样的内容
                    for pid in ids {
                        _ = moments.post(text: text, author: .ta, image: image,
                                         audience: audience, authorID: pid)
                    }
                }
            }
            // 🔴 评论不再用系统 alert（那是"卡片弹出来"的典型），
            //    改成微信那样**贴着键盘的底部输入条**（safeAreaInset 会自己顶起来）。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if commentingOn != nil {
                    commentBar
                }
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
                // 2026-11-12 用户：「朋友圈要做一个遮罩，因为上面它直接跑到上面去了」。
                // 封面是通栏铺到状态栏/灵动岛下面的，不加顶部压暗的话，
                // 白色的时间/电量直接糊在亮色封面上看不见。
                // 三段：顶 45%（压住状态栏）→ 中间 10%（不脏图）→ 底部 55%（托住名字）。
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.45), location: 0.0),
                            .init(color: .black.opacity(0.10), location: 0.32),
                            .init(color: .black.opacity(0.55), location: 1.0),
                        ],
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
        // 微信没有"发一条"的输入卡 —— 它藏在右上角相机里。
        // 这里保留一个极简通栏（说话框就在信息流顶上），但**不再包玻璃卡片**，
        // 否则又变成"卡片流"了。
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

    /// 微信朋友圈那种一行（2026-10-31 重做）。
    ///
    /// 和原来"卡片流"的差别（这是用户点名要的）：
    /// - **通栏**：左边头像 + 右边正文，不再是一个个圆角卡片
    /// - **点赞/评论**：一块淡灰底、**贴着正文**，不是再套一层卡片
    /// - **分隔线**：每条之后一根，左侧缩进到正文起始位置（微信就是这么缩进的）
    /// - 时间在正文下方、跟「评论」同一行右侧
    private func feedRow(_ moment: Moment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AevisAvatar(
                source: moment.author.isMe ? .me : .ai,
                size: 40,
                seed: persona.avatarSeed
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(displayName(for: moment.author))
                    .font(mfont(15, weight: .medium))
                    .foregroundStyle(authorColor(moment.author))

                if !moment.text.isEmpty {
                    // 显示层再兜一道：历史数据里可能已经存进了 `<tool_call>…</tool_call>`，
                    // 落库清洗只对新数据生效（用户 2026-11-11 截图里那条就是这么来的）。
                    Text(MomentStore.stripToolCall(moment.text))
                        .font(mfont(15))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let image = moments.image(for: moment) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                // 微信那块灰底：点赞名单 + 评论，**整块**贴着正文，不是卡片
                if !moment.likes.isEmpty || !moment.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !moment.likes.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill")
                                    .font(mfont(10))
                                    .foregroundStyle(settings.accentColor)
                                Text(moment.likes.map { displayName(for: $0) }.joined(separator: "、"))
                                    .font(mfont(12.5))
                                    .foregroundStyle(authorColor(likesAnchor(moment)))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        ForEach(moment.comments) { comment in
                            HStack(alignment: .top, spacing: 4) {
                                Text(commentLabel(comment))
                                    .font(mfont(12.5, weight: .medium))
                                    .foregroundStyle(authorColor(comment.author))
                                Text(comment.text)
                                    .font(mfont(12.5))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                replyToName = displayName(for: comment.author)
                                commentDraft = ""
                                commentingOn = moment
                                commentFocused = true
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }

                // 时间 + 操作（微信：时间在左、评论在右，同一行）
                HStack(spacing: 12) {
                    Text(timeText(moment.createdAt))
                        .font(mfont(11.5))
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 8)

                    Button {
                        commentDraft = ""
                        replyToName = nil
                        commentingOn = moment
                        commentFocused = true
                    } label: {
                        Label("评论", systemImage: "bubble.right")
                            .font(mfont(12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        moments.toggleLike(moment)
                    } label: {
                        Image(systemName: moment.likes.contains(.me) ? "heart.fill" : "heart")
                            .font(mfont(13))
                            .foregroundStyle(moment.likes.contains(.me) ? settings.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(moment.author.isMe)
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // ScrollView 里没有 List，所以删除走长按菜单，不用 swipeActions
        .contextMenu {
            Button(role: .destructive) {
                moments.remove(moment)
            } label: {
                Label("删掉这条", systemImage: "trash")
            }
        }
    }

    /// 信息流的分隔线。左边缩进到正文起始位置（头像 40 + 间距 10 + 页面 14 = 64）。
    private var feedDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 64)
    }

    /// 微信里昵称是**蓝绿色**那种，跟着主题色走；自己的名字也一样的处理。
    private func authorColor(_ author: Moment.Author) -> Color {
        author.isMe ? settings.accentColor : settings.accentColor.opacity(0.9)
    }

    /// 点赞名单用谁的色：名单里只要有我，就用我的色。
    private func likesAnchor(_ moment: Moment) -> Moment.Author {
        moment.likes.contains(.me) ? .me : moment.author
    }

    /// 底部评论条 —— 微信那种贴着键盘的输入条（不是系统 alert 卡片）。
    private var commentBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 9) {
                TextField(replyToName.map { "回复 \($0)" } ?? "评论",
                          text: $commentDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(mfont(14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .focused($commentFocused)

                Button {
                    submitComment()
                } label: {
                    Text("发送")
                        .font(mfont(14, weight: .semibold))
                        .foregroundStyle(canSubmitComment ? settings.accentColor : Color.secondary)
                        .padding(.vertical, 9)
                }
                .disabled(!canSubmitComment)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var canSubmitComment: Bool {
        !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
