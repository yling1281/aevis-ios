import SwiftUI

/// 天气文案的**展示层**归一化（2026-11-25）。
///
/// 为什么不改 `APIClient.cnWeather`：那一层是"把 wttr.in 的英文翻成中文"，属于取数逻辑；
/// 用户看到英文的原因不止一种 —— 缓存里存着旧版写入的英文、后端换了数据源、或者
/// wttr.in 返回了没覆盖到的词（`Patchy rain nearby` / `Light freezing rain` …）。
/// 只在展示层收口，才能保证**不管上游给什么，屏幕上只可能是中文**。
///
/// 词表按用户要求收敛成 10 类：晴 / 多云 / 阴 / 小雨 / 中雨 / 大雨 / 雷阵雨 / 雪 / 雾 / 霾。
/// 命中不了的回落「未知」，**绝不把英文原样显示给用户**。
enum WeatherText {

    /// 归一化成中文（幂等：已经是这 10 个词的直接返回）。
    static func zh(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "未知" }

        // 上游已经是中文：按"最具体优先"匹配，避免「多云转晴」被"晴"抢走
        if raw.contains("雷") { return "雷阵雨" }
        if raw.contains("霾") { return "霾" }
        if raw.contains("雾") { return "雾" }
        if raw.contains("雪") { return "雪" }
        if raw.contains("大雨") || raw.contains("暴雨") { return "大雨" }
        if raw.contains("中雨") { return "中雨" }
        if raw.contains("小雨") || raw.contains("阵雨") { return "小雨" }
        if raw.contains("雨") { return "中雨" }
        if raw.contains("阴") { return "阴" }
        if raw.contains("多云") { return "多云" }
        if raw.contains("晴") { return "晴" }

        // 英文：顺序很重要 —— 先判"更强"的天气，再判强度修饰词。
        if s.contains("thunder") || s.contains("storm") { return "雷阵雨" }
        if s.contains("blizzard") { return "雪" }
        if s.contains("snow") || s.contains("sleet") || s.contains("ice") { return "雪" }
        if s.contains("haze") || s.contains("smoke") || s.contains("dust") { return "霾" }
        if s.contains("fog") || s.contains("mist") { return "雾" }

        // 雨：先看强度词。wttr.in 常见写法
        //   Patchy light rain / Light drizzle / Light rain shower → 小雨
        //   Moderate rain / Moderate or heavy rain shower       → 中雨
        //   Heavy rain / Torrential rain shower                 → 大雨
        if s.contains("rain") || s.contains("drizzle") || s.contains("shower") {
            if s.contains("torrential") || s.contains("heavy") || s.contains("violent") { return "大雨" }
            if s.contains("moderate") { return "中雨" }
            if s.contains("light") || s.contains("patchy") || s.contains("drizzle") { return "小雨" }
            return "中雨"   // 只说了 rain、没给强度 → 按中雨，不猜小雨
        }

        if s.contains("overcast") { return "阴" }
        if s.contains("cloud") { return "多云" }
        if s.contains("sunny") || s.contains("clear") { return "晴" }

        // 认不出来就别硬猜，也绝不显示英文原文
        return "未知"
    }

    /// 中文 → SF Symbol（入参应已过 `zh(_:)`）。
    static func symbol(_ zh: String) -> String {
        switch zh {
        case "雷阵雨": return "cloud.bolt.rain.fill"
        case "雪":     return "cloud.snow.fill"
        case "大雨":   return "cloud.heavyrain.fill"
        case "中雨":   return "cloud.rain.fill"
        case "小雨":   return "cloud.drizzle.fill"
        case "雾":     return "cloud.fog.fill"
        case "霾":     return "sun.haze.fill"
        case "阴":     return "cloud.fill"
        case "多云":   return "cloud.sun.fill"
        case "晴":     return "sun.max.fill"
        default:       return "cloud.fill"
        }
    }

    /// 一步到位：把任意上游描述变成（中文, 图标）。
    static func resolve(_ raw: String) -> (text: String, symbol: String) {
        let t = zh(raw)
        return (t, symbol(t))
    }
}
