import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatStore

    /// 用来在用户换字体/调字号时重新渲染。
    @ObservedObject private var fonts = FontStore.shared

    /// 快捷指令送来的信号（要问的话、要弹的界面）在这里等着被取走。
    @ObservedObject private var bridge = BridgeInbox.shared
    /// 表情包（输入框左边那个笑脸面板用；消息气泡那边也有自己的引用）。
    @ObservedObject private var emoji = EmojiPack.shared

    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var toolNote: String?
    /// 底下那个「更多」面板（微信的加号）开没开。
    @State private var showMorePanel = false
    /// 表情面板（输入框左边的笑脸点开）—— 用户 2026-09-30 要「我也能发表情包」。
    @State private var showEmojiPanel = false
    /// 右上角「TA 的资料」开没开。
    @State private var showPersona = false
    /// 顶栏那个「打电话」按钮 —— 用户 2026-10-01：
    /// 「就是右上角，你要就是有一个让他打电话」。
    /// 点下去直接进通话页（`router.startCall()`），系统来电界面那一步在
    /// `CallService.start()` 里自己做，界面这边不用管。
    @State private var showDialer = false
    @State private var sendTask: Task<Void, Never>?
    @State private var didLaunchTest = false

    /// 设置 / 朋友圈 / 一起听 / 通话这几个面板提到了**根视图**上 ——
    /// 聊天页现在是二级页面，截图自检要在它还没出现时就打开那些面板。
    @ObservedObject private var router = AppRouter.shared

    /// 从会话列表点进来之后，靠它退回去。
    @Environment(\.dismiss) private var dismiss

    // 附件：拍照 / 选图 → OCR → 塞进输入框
    //
    // ⚠️ **「文件」入口 2026-09-28 撤掉了**（用户原话：「加号的话，文件的话，
    //    你也是发不出去的啊，就只能按相册和拍照」）。说明白点：选了文件也只是
    //    读文字塞进输入框，他试过几次都发不出去，所以直接不给这个入口。
    //    `AttachmentService` 那条读文件的链路还留着（别的入口可能用得上）。
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var attaching = false
    @State private var showScreenPanel = false
    /// 加号里的「转发朋友圈」面板。
    @State private var shareToMoments = false
    /// 加号里的「转账 / 红包」面板（假钱包）。
    @State private var showWallet = false
    /// 点开的那条转账气泡（看详情）。
    @State private var transferDetail: ChatMessage?
    @FocusState private var composerFocused: Bool

    private var persona: Persona { personaStore.persona }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 她在动手的时候，这里会变成「她看了眼时间…」，比干等一个「正在输入」有信息量。
    private var statusText: String {
        if let toolNote { return toolNote + "…" }
        return isSending ? "正在输入…" : "在线"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // 微信那个加号下面的面板：点开才出来，收起就没了
                if showMorePanel {
                    morePanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // 表情面板（输入框左边笑脸点开）
                if showEmojiPanel {
                    EmojiPanelView(theme: settings.chatTheme) { item in
                        sendEmoji(item)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                composer
            }
            // 面板和输入栏**共用**这一层背景，而且一直铺到屏幕最下沿 ——
            // 之前输入框下面留白，就是背景没铺到底。
            .background(
                Rectangle()
                    .fill(.bar)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        // 顶栏是我们自己画的（微信那种：返回 + 头像 + 名字），
        // 所以把系统的导航栏藏掉，不然会顶着两个头。
        .toolbar(.hidden, for: .navigationBar)
        // 进了聊天就把底下那四个 tab 收掉 —— 微信也是这个行为，聊天页占满整屏。
        // 用户的原话：「我进入聊天了的话，下面那四个栏你就不用带上了。」
        .toolbar(.hidden, for: .tabBar)
        .onDisappear {
            sendTask?.cancel()
        }
        .onAppear {
            // 截图自检：把「更多」面板直接打开，否则截不到它。
            // （设置 / 朋友圈 / 一起听那几个开关搬到根视图了 ——
            //   它们要在聊天页还没出现的时候就能打开。）
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenMore") {
                showMorePanel = true
            }
            // 截图自检：直接把钱包（转账/红包）那张打开 —— 不然截不到它。
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenWallet") {
                showWallet = true
            }
            #endif
            drainBridgeInbox()
            // 录屏扩展在另一个进程里攒着文字，进聊天页先拉一次 ——
            // 这样你刚看完抖音回来问她，她就已经知道了。
            ScreenCompanion.shared.refreshFromExtension()
            runLaunchTestIfNeeded()
        }
        // 一开始打字就把「更多」面板收掉 —— 微信也是这个行为
        .onChange(of: composerFocused) { _, focused in
            if focused, showMorePanel {
                withAnimation(.snappy(duration: 0.22)) {
                    showMorePanel = false
                }
            }
            if focused, showEmojiPanel {
                withAnimation(.snappy(duration: 0.22)) {
                    showEmojiPanel = false
                }
            }
        }
        // 快捷指令可能是在 App 已经开着的时候发回来 —— 那就靠变化来触发。
        .onChange(of: bridge.ask) { _, _ in drainBridgeInbox() }
        .onChange(of: bridge.openCall) { _, _ in drainBridgeInbox() }
        .onChange(of: bridge.openListen) { _, _ in drainBridgeInbox() }
        .onChange(of: pickedPhotos) { _, items in
            handlePickedPhotos(items)
        }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                attach(from: image, source: "照片")
            }
            .ignoresSafeArea()
        }
        #endif
        // 「转发朋友圈」的选消息面板（加号里那个）。
        .sheet(isPresented: $shareToMoments) {
            ShareToMomentsSheet()
                .environmentObject(chat)
                .environmentObject(personaStore)
        }
        // 假钱包：转账 / 红包（用户 2026-09-29 要的）
        .sheet(isPresented: $showWallet) {
            WalletView()
        }
        // 点开一条转账看详情
        .sheet(item: $transferDetail) { message in
            TransferDetailSheet(message: message)
        }
        .sheet(isPresented: $showScreenPanel) {
            screenPanel
        }
        // 右上角那个头像按钮开的页 —— 只放"和这个人有关"的东西
        .sheet(isPresented: $showPersona) {
            PersonaSheet()
                .environmentObject(personaStore)
                .environmentObject(settings)
        }
        // 顶栏那个电话按钮 —— 直接进通话页。
        //
        // 🔴 **2026-10-01 真机实测之后改的**：以前这里弹一个两选项的对话框
        //    （「打给她（用苹果的来电界面）」/「直接打」）。但**探针实测的结论是
        //    「苹果那套界面弹不出来」** —— 全能签重签用的描述文件里没有
        //    `aps-environment`，`LiveCommunicationKit` 要的正是它。
        //
        //    留着一个**明知不通**的选项是骗人：老板点了它，看到的是
        //    "进了自己的通话页、灵动岛什么也没发生" —— 还以为是我们写坏了。
        //    所以那个选项**删掉**，对话框也一并删掉（只剩一条路，没得选）。
        //
        // ⚠️ 想恢复那个选项的唯一前提：**换一份带通话资格的描述文件**
        //    （要么买了开发者账号自己签，要么全能签那边认了这条）。
        //    在那之前，这里不再显示任何"苹果来电界面"的字样。
        //
        // ⚠️ 那句解释**只在真的失败之后**弹 —— 判据是 `SystemCall.lastFailure`。
        //    顺序是：点按钮 → 直接进通话页 → `CallService.start()` 去调系统界面
        //    → 成功就什么都不弹，失败才把原因摆出来，**不预先下结论**。
        .onChange(of: SystemCall.callFailureTick) { _, _ in
            if SystemCall.lastFailure != nil { showDialer = true }
        }
        .alert(
            "苹果那套来电界面用不了",
            isPresented: $showDialer
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(SystemCall.lastFailure
                 ?? "这台手机上，签名没给通话资格（全能签重签时"
                     + "「通话」那条权限没带过来），所以灵动岛/锁屏上的"
                     + "苹果来电界面调不出来。\n\n"
                     + "声音、计时、免提、打字都正常，只差灵动岛上那张卡。")
        }
    }

    // MARK: - 附件
    //
    // 取出的文字**直接放进输入框**，不是偷偷发出去。
    // 用户能在后面接着写"帮我总结一下"，发出去的是「内容 + 指令」——
    // 她收到的是一段能读的文字，不是一张她看不见的图。

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard let item = items.first else { return }
        pickedPhotos = []
        Task { @MainActor in
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorText = "这张图读不出来，换一张试试。"
                return
            }
            attach(from: image, source: "图片")
        }
    }

    private func attach(from image: UIImage, source: String) {
        attaching = true
        Task { @MainActor in
            defer { attaching = false }
            // 认字用原图（字大一点更容易认出来）；显示用的那份先压好。
            let picture = AttachmentService.compressed(image)
            let text = await AttachmentService.recognizeText(in: image)

            guard picture != nil || !text.isEmpty else {
                errorText = "这张图读不出来，换一张试试。"
                return
            }
            errorText = nil

            // 图留在聊天里显示，她拿到的是从图里认出来的文字。
            // 没认出字也要说一句 —— 不然她会以为收到了一张空图，转头胡猜。
            let block = text.isEmpty
                ? "（我发了一张图片，但里面没认出文字。）"
                : AttachmentService.composerBlock(text, source: source)
            send(text: block, image: picture)
        }
    }

    /// 启动时自动测一次连接。不通就直接说出来 ——
    /// 免得用户对着一句没反应的对话框猜是哪里坏了。
    private func runLaunchTestIfNeeded() {
        guard !didLaunchTest else { return }
        didLaunchTest = true
        guard settings.autoTestOnLaunch, settings.isConfigured else { return }

        let config = settings.llm
        Task { @MainActor in
            do {
                _ = try await LLMService.probe(config: config)
            } catch {
                errorText = "启动自检没连上：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 顶部
    //
    // 和底部输入栏**用同一种材质** —— 之前上面是渐隐模糊、下面是实底，
    // 两条颜色不一样，看着别扭（用户说的「上面颜色统一一下」）。

    private var header: some View {
        HStack(spacing: 11) {
            // 微信那样：最左边一个返回箭头（聊天页现在是二级页面了）
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.aevis(17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            AevisAvatar(size: settings.simpleMode ? 40 : 36, seed: persona.avatarSeed)

            VStack(alignment: .leading, spacing: 1) {
                Text(persona.name)
                    .font(.aevis(settings.simpleMode ? 18 : 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(statusText)
                    .font(.aevis(settings.simpleMode ? 13 : 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // 打电话 —— 用户 2026-10-01：
            // 「就是右上角，你要就是有一个让他打电话。如果点了让他打电话，
            //   你就自动手机退出去，就自动回到主界面，然后他就灵动岛就直接来了个电话」。
            //
            // ⚠️ 能做的和不能做的（别在别处再写一遍，就记这儿）：
            //    · **不能**：App 自己退回主界面。iOS 没有公开 API
            //      （`ShortcutBridge.goHome()` 那条是系统内部选择器，不敢在这条路上用 ——
            //       万一下一版系统把它摘了，用户点"打电话"就是两个 App 一起卡住）。
            //      所以这里不替用户按 Home，字面意思那一步做不到，就没做。
            //
            // 🔴 **2026-10-01 改法**：原来点它先弹一个"用苹果界面 / 用自己界面"的
            //    对话框。探针真机测出**苹果那套界面在侧载包上弹不出来**（签名没带
            //    通话资格）之后，那个选项就是**明知不通还摆着** —— 老板点了它只会
            //    看到"进了自己的通话页、灵动岛没动静"，还以为坏了。
            //
            //    现在**直接进通话页**，一条路。要不要弹那句解释，交给
            //    `CallService.start()` 里的结果说话（见 `showDialer` 的 alert）。
            Button {
                composerFocused = false
                settings.systemCallUI = true
                router.startCall()
            } label: {
                Image(systemName: "phone.fill")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(settings.accentColor)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .aevisGlass(cornerRadius: 20)
            .accessibilityLabel("打电话给\(persona.name.isEmpty ? "TA" : persona.name)")

            // ⚠️ 这里以前是**全局设置**按钮 —— 用户明确说过不对：
            // 「打开这个人的右上角，为什么跟设置一样的？联系人右上角应该是给对方
            //  改头像、姓名、人设、背景图之类的呀」。现在开的是「TA 的资料」。
            Button {
                composerFocused = false
                showPersona = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.aevis(16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .aevisGlass(cornerRadius: 20)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // 和底部那条同一种材质，颜色统一
        .background(Rectangle().fill(.bar).ignoresSafeArea(edges: .top))
    }

    // MARK: - 消息列表
    //
    // 气泡外观在这里取一份快照传下去 —— 气泡自己是纯渲染，
    // 不受观察机制影响，也就不会出现「改了设置这边不跟着变」。

    private var bubbleTheme: BubbleTheme {
        BubbleTheme(
            myLook: settings.myBubble,
            aiLook: settings.aiBubble,
            myColor: settings.bubbleColor(settings.myBubble),
            aiColor: settings.bubbleColor(settings.aiBubble),
            cornerScale: settings.cornerScale,
            fontColor: settings.fontColor,
            showMyAvatar: settings.showMyAvatar,
            showAiAvatar: settings.showAiAvatar,
            // 界面密度：只改留白，不改字号（字号是另一组开关）
            density: settings.densityScale,
            theme: settings.chatTheme
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: (settings.simpleMode ? 16 : 12) * CGFloat(settings.densityScale)) {
                    if chat.messages.isEmpty {
                        emptyState
                    }

                    ForEach(chat.messages) { message in
                        if message.kind == .call {
                            // 通话记录 —— 微信那种居中的一行小字，**不是气泡**。
                            // 做成气泡会让人以为她真发过这么一句话。
                            CallRecordBubble(text: message.text)
                                .id(message.id)
                        } else if message.kind == .transfer, let info = message.transfer {
                            // 转账 / 红包 —— 微信那种带图标的卡片。点开看详情。
                            TransferBubble(info: info, isMine: message.role == .user) {
                                transferDetail = message
                            }
                            .id(message.id)
                        } else {
                            MessageBubble(
                                message: message,
                                persona: persona,
                                theme: bubbleTheme,
                                simpleMode: settings.simpleMode
                            )
                            .id(message.id)
                        }
                    }

                    if let errorText {
                        noticeBubble(errorText)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            // ⚠️⚠️ **这一行才是「打开就停在最新那条」的关键，别删**。
            //
            // 以前只有下面那几个 `onChange` 滚到底 —— 那**只在消息超过一屏时有用**。
            // 消息不满一屏时（刚装的、刚聊几句的）**根本滚不动**：ScrollView 把内容
            // 顶到最上面、下面留一大片空白，看起来就是"停在最上面"。
            // 用户反复提了很多次「打开要跳到最新的聊天记录」，就是这个。
            //
            // `.defaultScrollAnchor(.bottom)` 让内容**默认贴底**：
            // 不满一屏 → 贴着输入框（上面留白）；超过一屏 → 直接显示最新那条。
            // 跟微信一致。（iOS 17 API；部署目标正好是 17。）
            .defaultScrollAnchor(.bottom)

            // 手指一拖就收
            .scrollDismissesKeyboard(.immediately)
            // 点消息区任意位置也能收
            .onTapGesture {
                composerFocused = false
            }
            // ⚠️⚠️ **打开聊天必须主动滚到底**（用户反复提过好几次）。
            //
            // 下面三个 `onChange` 只在「消息变了」的时候才滚 —— 而打开一个
            // **已经有历史记录**的聊天时，一条新消息都没有，三个 onChange
            // 一个都不响 → 界面就停在最上面，看起来就是"没滑到最新那条"。
            //
            // 滚两次是**故意的**：第一次立刻滚（布局已好时一次到位）；历史记录
            // 多的时候 LazyVStack 还在铺，"bottom"那个锚点可能还没生成，滚了等于
            // 没滚 —— 所以隔一拍再滚一次兜底。少这一次就变成"有时能到底、
            // 有时不能"的玄学。
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // 换了聊天对象（从别处切过来、路径没变、视图没重建）：
            // 两个联系人消息条数**正好一样**的话，上面那个 `count` 钩子不会响，
            // 所以再认一下"第一条消息换人了没有"。换人了就说明整段都换了 → 滚到底。
            .onChange(of: chat.messages.first?.id) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: errorText) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // ⚠️⚠️ **键盘弹出来 / 收起来，都要重新贴到底**（用户 2026-09-28 原话：
            //   「点击输入法的话就跟微信一样，就聊天就都顶到最下面，然后取消输入法
            //    就顶到最下面嘛」）。
            //
            // `.defaultScrollAnchor(.bottom)` 只管**内容高度变化**时的贴底；
            // 键盘一出现，变的是**可视区高度**，滚动位置会跟着漂 —— 表现就是
            // "点开键盘以后消息被顶上去了一截"。所以这里在系统通知里再贴一次。
            //
            // 为什么滚两次：键盘动画约 0.25 秒，布局是**边动边算**的，
            // 通知刚到时新高度还没生效。第一次在 60ms（动画中段）稳住，
            // 第二次在 240ms（动画结束后）拍板。少一次就会"有时贴有时不贴"。
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification)) { _ in
                stickToBottom(proxy, delay: 60, thenAnother: 180)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { _ in
                stickToBottom(proxy, delay: 60, thenAnother: 180)
            }
        }
    }

    /// 贴到底（带一次延迟补滚）。
    private func stickToBottom(_ proxy: ScrollViewProxy, delay: UInt64, thenAnother: UInt64) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            proxy.scrollTo("bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: thenAnother * 1_000_000)
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            AevisOrb()
                .scaleEffect(0.72)
            Text("\(Pronoun.spaced(persona.pronoun))在这儿。")
                .font(.aevis(settings.simpleMode ? 19 : 17, weight: .medium))
                .foregroundStyle(.primary)
            if settings.isConfigured {
                Text("说点什么开始吧。TA 能看时间、翻日历、记提醒、算数、读写剪贴板。")
                    .font(.aevis(settings.simpleMode ? 15 : 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else {
                Text("还差一步：右上角设置 →「模型接入」，填上你的 API Key，TA 才会说话。")
                    .font(.aevis(settings.simpleMode ? 15 : 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 30)
        .padding(.bottom, 16)
    }

    private func noticeBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .aevisGlass(cornerRadius: 14)
            Spacer(minLength: 30)
        }
    }

    // MARK: - 底部输入栏
    //
    // 三处修正（都是用户实测发现的）：
    // 1. 玻璃要整条加在容器上，不能加在 TextField 上（自带样式的控件不生效）
    // 2. 底下垫一条实底，消息不会从输入栏周围透上来
    // 3. 「收起」放在输入栏同一排，不再飘在键盘上方

    /// 输入栏 —— 按微信那样：一个输入框，右边一个「更多」或发送。
    ///
    /// 用户要求：「聊天界面就跟微信一样，你别的东西就堆在那个"更多"里。」
    /// 所以相册、拍照、文件、朋友圈、一起听、通话、设置**全收进下面那个面板**，
    /// 输入栏这一排只留最必要的控件，不再铺一排按钮。
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // 表情入口（微信输入框左边那个笑脸）—— 点开表情面板。
            Button {
                composerFocused = false
                withAnimation(.snappy(duration: 0.22)) {
                    showEmojiPanel.toggle()
                    if showEmojiPanel { showMorePanel = false }
                }
            } label: {
                Text(showEmojiPanel ? "⌨️" : "😊")
                    .font(.aevis(settings.simpleMode ? 20 : 18))
                    .frame(width: settings.simpleMode ? 38 : 34,
                           height: settings.simpleMode ? 38 : 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 1)

            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.aevis(settings.simpleMode ? 17 : 15))
                .focused($composerFocused)
                .disabled(isSending)
                .padding(.vertical, settings.simpleMode ? 10 : 8)
                .padding(.horizontal, 12)

            if composerFocused {
                // 收键盘。微信里是点空白处，这里给个明确的按钮更省事。
                Button {
                    composerFocused = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }

            // 有字才出现发送 —— 微信也是这个规矩
            if canSend || isSending {
                Button(action: send) {
                    Image(systemName: isSending ? "stop.fill" : "arrow.up")
                        .font(.aevis(settings.simpleMode ? 16 : 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: settings.simpleMode ? 38 : 34,
                               height: settings.simpleMode ? 38 : 34)
                        .background(
                            Circle().fill(isSending ? Color.gray.opacity(0.55) : settings.accentColor)
                        )
                        .contentShape(Circle())
                }
                .padding(.bottom, 1)
            }

            // 「更多」—— 微信里那个加号
            Button {
                composerFocused = false
                withAnimation(.snappy(duration: 0.22)) {
                    showMorePanel.toggle()
                }
            } label: {
                Image(systemName: showMorePanel ? "xmark" : "plus")
                    .font(.aevis(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: settings.simpleMode ? 38 : 34,
                           height: settings.simpleMode ? 38 : 34)
                    .aevisGlass(cornerRadius: settings.simpleMode ? 19 : 17)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 1)
        }
        .padding(6)
        .aevisGlass(cornerRadius: 26)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 表情面板（用户 2026-09-30 要「我也能发表情包」）
    //
    // 面板本体抽到 `EmojiPanelView`（微信 8 列 / iMessage 4 列 + 搜索 + 分类）。
    // 这里只留「点一个表情就发出去」这一件事。

    /// 点一个表情就发出去。内置表情发 emoji 字符（气泡会放大显示）；
    /// 自定义图片表情发图（正文写 `[名字]`，模型能懂那是什么）。
    private func sendEmoji(_ item: EmojiPack.Item) {
        if let img = emoji.image(for: item), let data = img.pngData() {
            send(text: "[" + item.name + "]", image: data)
        } else {
            send(text: item.emoji, image: nil)
        }
        showEmojiPanel = false
    }

    // MARK: - 「更多」面板（微信那个加号下面的东西）
    //
    // 用户要求：「聊天界面就跟微信一样，你别的东西就堆在那个'更多'里。」
    // 所以原来铺在底下的那排按钮全撤了，改成点加号才展开的面板。
    //
    // 顺便保留那条修正：面板和输入栏**共用一个铺到屏幕最下沿的背景**
    // （在 body 里统一加），不然输入框下面会留一条白。

    private let moreColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var morePanel: some View {
        LazyVGrid(columns: moreColumns, spacing: 16) {
            PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 3, matching: .images) {
                moreTile("相册", attaching ? "hourglass" : "photo.on.rectangle")
            }
            .disabled(attaching)

            #if canImport(UIKit)
            Button {
                showCamera = true
            } label: {
                moreTile("拍照", "camera")
            }
            .disabled(!AttachmentService.cameraAvailable)
            .opacity(AttachmentService.cameraAvailable ? 1 : 0.4)
            #endif

            // ⚠️ 这里以前有两个坑（用户 2026-09-28 提的）：
            //   ① 「文件」—— 选了也只是读出文字塞进输入框，他试几次都发不出去
            //      → 入口直接撤掉，只留相册和拍照。
            //   ② 「朋友圈」—— 点它是想**把聊天里的东西转过去**，不是想看朋友圈
            //      → 改成「转发朋友圈」，选一条消息发到朋友圈。
            Button {
                closeMorePanel()
                shareToMoments = true
            } label: {
                moreTile("转发朋友圈", "arrowshape.turn.up.right")
            }

            // 假钱包：转账 / 红包（用户 2026-09-29：「支付功能也是气泡」）
            Button {
                closeMorePanel()
                showWallet = true
            } label: {
                moreTile("转账 / 红包", "yensign.circle")
            }

            // 一起听 / 通话 默认不显示（见 `Experimental`）：这两个入口以前藏在
            // 「更多」面板里，买家点进去只会遇到"要订阅 / 要授权 / 连不上"。
            if Experimental.enabled {
                Button {
                    closeMorePanel()
                    // 一起听 → 直接开全屏播放器（它现在就是一起听的界面）
                    router.showPlayer = true
                } label: {
                    moreTile("一起听", "music.note.list")
                }

                Button {
                    closeMorePanel()
                    router.startCall()
                } label: {
                    moreTile("通话", "phone.arrow.up.right")
                }
            }

            Button {
                closeMorePanel()
                showScreenPanel = true
            } label: {
                moreTile("看屏幕", "record.circle")
            }

            Button {
                closeMorePanel()
                router.showSettings = true
            } label: {
                moreTile("设置", "slider.horizontal.3")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    /// 「让她看屏幕」—— 从聊天里直接开录屏，不用绕到设置去。
    ///
    /// 为什么非得在这儿也放一个：用户报「她说看不到我的屏幕」，
    /// 而录屏按钮埋在「设置 → 陪伴」里，他压根没找到，就以为功能坏了。
    /// 这里把按钮、说明、诊断三样摆在一起，点一下就知道卡在哪。
    private var screenPanel: some View {
        let companion = ScreenCompanion.shared
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ScreenCompanion.howToStart)
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BroadcastStartButton(width: 260)

                    if let problem = companion.extensionProblem {
                        Text(problem)
                            .font(.aevis(12.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(companion.diagnostics)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(ScreenCompanion.ocrLimit)
                        .font(.aevis(12))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("让她看屏幕")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { ScreenCompanion.shared.refreshFromExtension() }
        }
    }

    private func closeMorePanel() {
        withAnimation(.snappy(duration: 0.22)) {
            showMorePanel = false
        }
    }

    /// 面板里的一格：一个玻璃方块 + 一行小字。
    private func moreTile(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.aevis(20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .aevisGlass(cornerRadius: 16)
            Text(title)
                .font(.aevis(11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var placeholder: String {
        persona.name.isEmpty ? "说点什么…" : "和 \(persona.name) 说点什么…"
    }

    // MARK: - 快捷指令送来的信号

    /// 快捷指令「打开 URL」之后，App 可能是**刚被拉起来的**（那时聊天页还没出现），
    /// 也可能本来就开着。所以 onAppear 和值变化时都看一眼 —— 谁先到都不会漏。
    private func drainBridgeInbox() {
        if let text = bridge.ask,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bridge.ask = nil
            draft = text
            send()
        }
        if bridge.openCall {
            bridge.openCall = false
            router.startCall()
        }
        if bridge.openListen {
            bridge.openListen = false
            // 一起听 = 全屏播放器（见 AppRouter.showPlayer 的说明）
            router.showPlayer = true
        }
    }

    // MARK: - 发送

    private func send() {
        if isSending {
            stopSending()
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        send(text: text, image: nil)
    }

    /// 打断她正在生成的那句。
    private func stopSending() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        toolNote = nil
        chat.removeLastIfEmpty()
        SpeechService.shared.stop()
    }

    /// 真正干活的发送。
    ///
    /// `image` 只影响**显示**：聊天里出现一张图，而发给模型的是 `text`
    /// —— 从那张图里 OCR 出来的文字。用户要的就是这个：
    /// 「走的还是图片，只不过 TA 那边收到的是文字识别的东西。」
    private func send(text: String, image: Data?) {
        if isSending { stopSending() }

        errorText = nil
        toolNote = nil
        SpeechService.shared.stop()

        chat.append(ChatMessage(role: .user, text: text, imageData: image))
        chat.append(ChatMessage(role: .assistant, text: ""))

        let config = settings.llm
        let prompt = persona.systemPrompt
        // `goesToModel` 比原来那句「排除空文本的助手消息」更准：
        // 顺带把**通话记录**这类只给人看的系统消息挡在外面（她不该对着
        // 「通话时长 03:21」学说话）。
        let history = chat.messages.filter { $0.goesToModel }
        // 背景资料 = 长期记忆 +（快捷指令发过数据的话）屏幕使用时间 + 外面来的信息
        var context = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        // 情侣空间（在一起多少天 / 倒数日）。
        // ⚠️ **不挂 `memoryInjectEnabled` 开关**：那个开关管的是"她自动提炼的长期记忆"，
        //    而这里是用户自己手填的硬事实 —— 关掉记忆就让她"忘了生日"，
        //    那不是省事，那是 bug。
        context.append(contentsOf: CoupleStore.shared.injectedLines())
        let screenTime = ScreenTimeInsight.shared.digest()
        if !screenTime.isEmpty { context.append(screenTime) }
        // 位置 / 电量 / 步数 / 天气这些是**用户主动用快捷指令喂进来的**，
        // 跟「长期记忆」不是一回事，所以不受上面那个开关影响。
        context.append(contentsOf: AmbientContext.shared.digest())
        let remember = settings.memoryEnabled
        let shouldSpeak = settings.speakerEnabled
        let ttsConfig = settings.tts
        let systemVoice = persona.voiceIdentifier
        // 她叫什么 —— 送灵动岛（Live Activity）时要显示的名字。
        // 在这算好、传进闭包，闭包里就别再读 `persona`（那是主线程隔离的计算属性）。
        let herName = persona.name.isEmpty ? "TA" : persona.name

        isSending = true
        sendTask = Task { @MainActor in
            // accumulated = 整段（念出来、提炼记忆都用它）
            // pending     = 还没定稿的这一条
            var accumulated = ""
            var pending = ""

            /// 她换行就等于换一条消息 —— 这样看起来才是一条一条发出来的。
            ///
            /// ⚠️ 这里**绝对不能**在流结束时再「强制定稿一次」。
            /// 踩过的坑：`pending` 一直是靠 `replaceLast` 实时显示在最后一条上的，
            /// 结束时再调一次 `finishStreamingLine(pending)`，它会发现最后一条已经
            /// 不是空的了，于是**又追加一条一模一样的内容** ——
            /// 表现就是她每句话都说两遍。
            ///
            /// ⚠️ `@MainActor` **不能省**：`chat` 是主线程隔离的属性，
            ///    而 Swift 里**局部函数不会自动继承外层 `Task { @MainActor }` 的隔离**，
            ///    不标的话编译器要警告"从非隔离上下文访问主线程属性"。
            ///    （只加 `@MainActor` 而不是把整段搬到别处：调用点就在同一个
            ///      MainActor 任务里，搬走反而要来回 hop。）
            @MainActor
            func flushLines() {
                while let index = pending.firstIndex(of: "\n") {
                    let line = String(pending[pending.startIndex..<index])
                    pending.removeSubrange(pending.startIndex...index)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    chat.finishStreamingLine(trimmed)
                }
                // 正在吐的这条实时显示在最后一条上
                if !pending.isEmpty {
                    chat.replaceLast(with: pending)
                }
            }

            do {
                for try await piece in LLMService.streamReply(
                    config: config,
                    systemPrompt: prompt,
                    history: history,
                    memory: context,
                    tools: DeviceTools.all(),
                    onToolActivity: { title in
                        Task { @MainActor in
                            toolNote = title
                        }
                    }
                ) {
                    // 她开始说话了，把「她看了眼时间…」收掉
                    if toolNote != nil { toolNote = nil }
                    accumulated += piece
                    pending += piece
                    flushLines()
                }
                // 收尾：剩下的 pending 早就显示在最后一条上了，这里只要清掉
                // 多余的空占位就行 —— **不要再定稿一次**（见上面那段注释）。
                chat.removeLastIfEmpty()
                chat.commit()

                // ⭐ 她这一整段话说完 → 送上**灵动岛**（Live Activity）。
                // ⚠️ 每次回复**只调一次**（不是每行一次，所以挂在这里、不挂在
                //    `flushLines` 里）。`accumulated` 是整段、可能很长 ——
                //    `LiveIslandCenter` 会**在意层截断**，别把整段塞进活动状态。
                // ⚠️ 只在真有内容时调；空回复不打扰灵动岛。
                let said = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !said.isEmpty {
                    LiveIslandCenter.shared.push(name: herName, text: said)
                }
            } catch {
                chat.removeLastIfEmpty()
                if (error as? CancellationError) == nil {
                    errorText = error.localizedDescription
                }
            }

            isSending = false
            toolNote = nil
            sendTask = nil

            // 聊够了就顺手提炼一次长期记忆。
            // 放在回复之后 —— 不挡着说话，失败也只进记忆库的状态行。
            if remember {
                await MemoryStore.shared.extractIfNeeded(
                    config: config,
                    messages: chat.messages,
                    persona: persona
                )
            }

            if shouldSpeak, !accumulated.isEmpty {
                SpeechService.shared.speak(
                    accumulated,
                    config: ttsConfig,
                    systemVoiceIdentifier: systemVoice
                ) { message in
                    errorText = message
                }
            }

            // ⭐ 她发语音消息（2026-09-30）：文字之外再合成一条语音条（点一下播放）。
            //    只走外部 API 音色（系统音色导不出音频文件）；合成失败就静默跳过，
            //    文字已经在聊天里，不缺这一条。
            if settings.voiceMessageEnabled, !accumulated.isEmpty {
                let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    do {
                        let audio = try await SpeechService.shared.synthesize(text, config: ttsConfig)
                        var message = ChatMessage(role: .assistant, text: "", kind: .voice)
                        message.voiceData = audio
                        message.voiceDuration = SpeechService.duration(of: audio)
                        chat.append(message)
                    } catch {
                        // 语音没合成出来也不挡，文字已经在了。
                    }
                }
            }
        }
    }
}
