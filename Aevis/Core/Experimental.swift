import Foundation

/// 试验功能 —— **已撤开关**（用户 2026-09-30：「那个功能取消掉」）。
///
/// 现在四块（苹果音乐 / 百度网盘 / 一起听 / 实时通话）在正式版和内测版里**都出现**，
/// 不再藏在开关后面。代码留着这个枚举只是为了不改动那十几处 `Experimental.enabled`
/// 的读法 —— `enabled` 恒为 true。
///
/// ⚠️ 唯一的例外：**抖音**。它单独摘出来永远关（见 `DiscoverView`），
///    因为那是用户 2026-09-28 明确要关掉的，跟这四块不是一个待遇。
enum Experimental {

    /// 恒为 true：四块试验功能始终可见。
    /// （保留 set 是让历史代码里可能残留的赋值不至于编译报错。）
    static var enabled: Bool {
        get { true }
        set { _ = newValue }
    }

    /// 设置页里用来告诉用户"现在藏了哪几块"的一句话。
    static let hiddenSummary = "苹果音乐、百度网盘、一起听、实时通话"
}
