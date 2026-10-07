import Foundation

/// 群聊的「轮流说话」编排器。
///
/// ## 它负责什么
/// 用户在一个群里发一句话 → 让**群里的每个成员各回一句**（按 `group.memberIDs` 的顺序）。
/// 每条回复都带上 `speakerID` / `speakerName`，落进**群自己的那份聊天记录**
/// （`ChatStore`，拿群 id 当会话 key）。
///
/// ## 四条硬规矩（都不是可选项，见下面各自注释）
/// 1. **串行**：`ChatStore.replaceLast` / `finishStreamingLine` 都假设「最后一条 =
///    唯一那个正在吐字的 AI」。两个 AI 同时流式会把彼此的气泡顶乱 —— 所以一轮里
///    一个说完再下一个。
/// 2. **必须给模型做发言人前缀**：这条漏斗把所有非 user 历史都塞成 `assistant`
///    （见 `LLMService` 里那段）。群成员之间**必须**能从提示词里看出「这句是谁说的」，
///    否则两个 AI 会把对方的话认成自己的 —— 前缀在 `LLMService.buildMessages` 里按
///    `speakerName` 加，这里负责把名字写进消息。
/// 3. **必须有停止条件**：AI 之间不许无限对喷。这里定的是「**一轮 = 每个成员各说
///    一句，说完就停**」；用户不再发消息，群就静下来，不会自己一直聊下去。
/// 4. **重入锁**：上一轮没跑完时，新的发送直接忽略（`generating`）。
///
/// ## 先例
/// 自造历史 + 代码发起、不走用户输入这条套路，照的是
/// `ListenTogetherService.react`（一起听时 ta 跟着歌词说话）。
@MainActor
final class GroupChatService {
    static let shared = GroupChatService()
    private init() {}

    /// 正在跑一轮群聊。**重入锁** —— 上一轮没完，新的发送忽略。
    private(set) var generating = false

    // MARK: - 一轮

    /// 用户在这个群里说了一句话 —— 让每个成员各回一句。
    ///
    /// ⚠️ 调用方（`ChatView`）应当把它包在一个可取消的 `Task` 里，
    ///    这样用户在生成中点「停止」能真的停下来。
    func run(userText raw: String, group: ChatGroup) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !generating else { return }
        generating = true
        defer { generating = false }

        // 整个群共用一个会话 —— **拿群 id 当会话 key**（`ChatStore.byContact` 本来就是
        // `[UUID: [ChatMessage]]`，不用为群单开一套结构）。切过去之后，
        // 下面所有 `append` / `replaceLast` 操作的都是群这一份。
        // ⭐ 开轮时抓一次 owner 快照 —— 整轮里所有落库 / 流式都只用这一个 owner，
        //    **不再读 `ChatStore.shared.currentContactID`**：用户中途切走再切回，
        //    群这份记录也绝不会被写到别的会话上（见 `ChatStore.replaceLast(for:)`）。
        let owner = group.id
        ChatStore.shared.switchTo(owner)
        ChatStore.shared.append(ChatMessage(role: .user, text: text), for: owner)

        let settings = AppSettings.shared
        let config = settings.llm
        // 背景资料跟一对一聊天同一套：长期记忆（受开关管）+ 情侣空间（不受开关管）。
        var memory: [String] = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        memory.append(contentsOf: CoupleStore.shared.injectedLines())

        for memberID in group.memberIDs {
            // 用户中途按了「停止」→ 别把剩下的人也叫起来。
            if Task.isCancelled { break }
            // 成员可能已经被删了（悬空 id）→ 跳过，别崩。
            guard let contact = contact(for: memberID) else { continue }
            await speak(member: contact.persona,
                        memberID: memberID,
                        group: group,
                        owner: owner,
                        config: config,
                        memory: memory)
        }
        ChatStore.shared.commit()
    }

    // MARK: - 一个成员的一句

    /// 让**某一个**成员说一句。共享的历史在这一刻现取 —— 所以前面的人刚说完的话，
    /// 后面的人一开口就看得见。
    private func speak(member persona: Persona,
                       memberID: UUID,
                       group: ChatGroup,
                       owner: UUID,
                       config: LLMConfig,
                       memory: [String]) async {
        // 没配 API Key 就别开空占位了 —— 免得群里凭空多出一串空气泡。
        guard AppSettings.shared.isConfigured else { return }

        // 先占一条空位，ta 的字**流式**长在这条上。
        // ⚠️ 带上 speakerID / speakerName —— 界面靠它区分谁是谁，
        //    `LLMService` 也靠 `speakerName` 给后面的人加发言人前缀。
        ChatStore.shared.append(
            ChatMessage(role: .assistant,
                        text: "",
                        speakerID: memberID,
                        speakerName: persona.name),
            for: owner
        )

        // 现取历史：包含用户那句 + 前面成员已说完的每条（带 speakerName）。
        // ⭐ 按 owner 取，**不读 `ChatStore.shared.messages`** —— 用户切走时那份
        //    已经是别人的了，读错会把别人的聊天记录喂给这个 AI。
        let history = ChatStore.shared.history(for: owner).filter { $0.goesToModel }
        let prompt = systemPrompt(for: persona, memberID: memberID, group: group)

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: prompt,
                history: history,
                memory: memory,
                tools: DeviceTools.all(),
                // ⭐ 把群 id 带进去 —— 成员在群里调**钱包工具**时，转账 / 亲密付气泡
                //    要落进**群**这份，而不是用户此刻正在看的会话（见 `LLMService.conversationOwner`）。
                owner: owner
            ) {
                collected += piece
                // 流式上屏：改的是**群这份**的最后一条（就是刚开的那个占位）。
                // ⭐ 带 owner，用户切走切回都不会写错会话。
                ChatStore.shared.replaceLast(with: collected, for: owner)
            }
        } catch {
            // 出错 / 被取消 → 把没内容的占位扔掉，别留一串空气泡。
            // ⭐ 带 owner，别清到当前会话（别人的）头上。
            ChatStore.shared.removeLastIfEmpty(for: owner)
            return
        }

        // ⭐ 剥掉末尾的「心情标记」—— 群里也不该看见那个标记。
        // ⚠️ 这里**用纯剥**（`strippingMarker`）而**不**用 `consume`：
        //    `consume` 会把这条心情写进全局的 `MoodStore`，而那是**当前联系人**的
        //    状态 —— 群消息不该去改它。
        let clean = MoodStore.strippingMarker(from: collected)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            ChatStore.shared.removeLastIfEmpty(for: owner)
            return
        }
        ChatStore.shared.replaceLast(with: clean, for: owner)
    }

    // MARK: - 提示词

    /// 这个成员在群里说话时用的系统提示词 = 它自己的人设 + 一段「群规」。
    ///
    /// 群规这段是**产品语义**，不是接线：它告诉这个 AI「你在群里、还有哪些人、
    /// 只代表你自己说话」。少了它，模型会以为还是在跟用户一对一。
    private func systemPrompt(for persona: Persona, memberID: UUID, group: ChatGroup) -> String {
        var others: [String] = []
        for id in group.memberIDs where id != memberID {
            guard let name = contactName(for: id) else { continue }
            others.append(name)
        }
        let othersLine = others.isEmpty
            ? "群里现在只有你和他。"
            : "群里除了你还有：\(others.joined(separator: "、"))，以及他（对方本人）。"

        let groupRule = """
        你现在在一个群聊里，群名叫「\(group.displayName)」。
        \(othersLine)
        群里每个人说话都会带上名字（像「名字：说了什么」）。你只代表你自己说话：
        不要替别人回答，也不要复述别人刚说过的话；轮到你的时候，就说你想说的那一句。
        发言短一点，像平时在群里发消息那样。
        """
        return persona.systemPrompt + "\n" + groupRule
    }

    // MARK: - 零件

    private func contact(for id: UUID) -> Contact? {
        PersonaStore.shared.contacts.first { $0.id == id }
    }

    /// 成员名字；没起名字 / 找不到就给 `nil`（调用方跳过）。
    private func contactName(for id: UUID) -> String? {
        let name = contactNameRaw(for: id)
        return name.isEmpty ? nil : name
    }

    private func contactNameRaw(for id: UUID) -> String {
        (contact(for: id)?.persona.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
