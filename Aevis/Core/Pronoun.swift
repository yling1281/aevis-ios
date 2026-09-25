import Foundation

/// 界面文案里指代 TA 的那个词。
///
/// ## 为什么要有这个东西
/// 人设的性别**默认是「不设定」**，那时候界面该叫 **TA**。
/// 但文案里曾经写死了 57 处「她」 —— 用户把性别设成「男」或「无性别」，
/// 界面还在叫「她」。**那个设置等于没生效**（2026-09-25 用户提出来才发现）。
///
/// 产品口径：这是**恋人**，不是「女友」—— 男 / 女 / 无性别 / 不设定都成立。
///
/// ## 用法
/// `Text("\(Pronoun.current)发动态的节奏")`
///
/// ⚠️ **不要再在界面文案里写死「她」/「他」**。要写就写 `Pronoun.current`。
/// ⚠️ 唯一该出现固定「她」的地方是 `Persona.GenderIdentity.pronoun`
///     —— 那里就是这个词的定义处。
enum Pronoun {

    /// 界面里指代 TA 的那个词，**拉丁词后面自带一个空格**。
    ///
    /// 为什么要带空格：直接写 `"\(Pronoun.current)发动态"`，
    /// 人设是「不设定」时渲染成 `TA发动态`，中英挤在一起很难看；
    /// 而如果是「她」「他」，加了空格反而怪（`她 发动态`）。
    /// 所以按词性决定要不要空格 —— 一处规则，57 个调用点都不用管。
    static var current: String { spaced(PersonaStore.shared.persona.pronoun) }

    /// 把「她 / 他 / TA / 空」统一成能直接插进中文句子的形态。
    static func spaced(_ value: String) -> String {
        let word = value.trimmingCharacters(in: .whitespaces)
        if word.isEmpty { return "TA " }
        // 只有拉丁字母（TA）才补空格
        let isLatin = word.unicodeScalars.allSatisfy { $0.isASCII }
        return isLatin ? word + " " : word
    }
}
