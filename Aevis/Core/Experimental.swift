import Foundation

/// 试验功能的**总开关**。
///
/// 用户 2026-09-26 的口径：「苹果的音乐和百度网盘砍掉，一起听也是，电话也是 bug」。
/// 这四块都踩过坑 —— Apple Music 要订阅（买家大多没订）、百度网盘要 OAuth 授权、
/// 一起听和实时通话依赖网络与后台存活。买家装上去只会觉得"这 App 有毛病"。
///
/// ## 为什么是运行期开关，而不是做两个 target
/// 两个 target 要动 `project.yml` + CI 的 `xcodebuild` 步骤 + **再签一次嵌套的录屏扩展**
/// （扩展签不明白会整个 App 装不上，这条笔记里记着）。而这里要的结果只是"买家看不到"，
/// 一个开关就够：
///   - **默认关** = 买家版行为（那四个入口根本不出现）
///   - 设置 → 关于 里可以打开 = 自己测的时候全功能都在
///
/// ⚠️ 关掉的是**入口和她的工具**，不是把代码删掉 —— 数据格式、服务层都还在。
/// 想彻底恢复只要把开关打开。真要做成"两个独立的 App 同时装在一台手机上"，
/// 那是另一件事（要加 target + CI 多编一个），说一声再做。
enum Experimental {

    private static let key = "aevis.experimental"

    /// 显示苹果音乐 / 百度网盘 / 一起听 / 实时通话这些试验功能。
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 设置页里用来告诉用户"现在藏了哪几块"的一句话。
    static let hiddenSummary = "苹果音乐、百度网盘、一起听、实时通话"
}
