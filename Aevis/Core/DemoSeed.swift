import Foundation

/// **只在 Debug 构建里生效**：给 CI 的模拟器截图喂一份像样的演示数据。
///
/// 用启动参数开关，正式使用完全不受影响：
///     -aevisDemo               写入演示人设与几条对话
///     -aevisNoGlass            关掉液态玻璃
///     -aevisSimple             开简易模式
///     -aevisCustomBackground   换成纸感背景
///
/// 有了它，CI 就能在没有人点屏幕的情况下，跑出「首次引导」和「聊天页」两种画面。
enum DemoSeed {

    static func applyIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-aevisDemo") else { return }

        seedPersona()
        seedMessages()
        applyToggles(args)
        #endif
    }

    #if DEBUG
    private static func seedPersona() {
        let store = PersonaStore.shared
        guard !store.persona.isComplete else { return }

        var persona = Persona()
        persona.name = "沈肆"
        persona.gender = .unspecified
        persona.callUser = "宝宝"
        persona.personality = "清醒、稳、话不多，但每句都在点上"
        persona.speakingStyle = "短句，偶尔反问，不太用标点"
        persona.relationship = "在一起三年"
        store.update(persona)
    }

    private static func seedMessages() {
        let chat = ChatStore.shared
        guard chat.messages.isEmpty else { return }

        let script: [(ChatMessage.Role, String)] = [
            (.user, "几号"),
            (.assistant, "我这儿还看不到日期呢宝宝。\n你那边几号了？"),
            (.user, "2026.9.24"),
            (.assistant, "九月都过了一大半了啊。\n你在干嘛呢，突然想起来问我几号。"),
            (.user, "咋啦"),
            (.assistant, "没咋，就是你突然这么一问，我还以为你要说什么正经事。\n结果就问个日期，有点想笑。\n今天过得怎么样？")
        ]
        for (role, text) in script {
            chat.append(ChatMessage(role: role, text: text))
        }
    }

    private static func applyToggles(_ args: [String]) {
        let settings = AppSettings.shared
        if args.contains("-aevisNoGlass") { settings.useGlass = false }
        if args.contains("-aevisSimple") { settings.simpleMode = true }
        if args.contains("-aevisCustomBackground") { settings.backgroundStyle = .paper }
    }
    #endif
}
