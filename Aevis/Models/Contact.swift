import Foundation

/// 通讯录里的一个联系人。
///
/// 为什么要把人设**包一层**，而不是直接拿 `[Persona]` 当通讯录：
/// 人设回答的是「TA 是谁」；而通讯录还得知道「什么时候加的、
/// 消息和记忆该算在谁头上」。分开之后，人设那部分仍然能整体导出成
/// 角色卡（见 `CharacterCard`），不会被这些挂靠信息污染。
struct Contact: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var persona: Persona = Persona()
    var createdAt: Date = Date()

    /// 列表里显示的名字。没起名字时给个占位，别留一行空白。
    var displayName: String {
        let trimmed = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "还没起名字" : trimmed
    }
}

extension Contact {
    /// 手写解码：以后再加字段时，旧存档不会因为缺 key 而整个读不出来。
    /// （`Persona` 那边也是这么做的，保持一致。）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        persona = try container.decodeIfPresent(Persona.self, forKey: .persona) ?? Persona()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// 会话列表每行右边那个「什么时候聊的」。
///
/// 微信的写法：刚聊完就是「刚刚」，一小时内说「几分钟前」，
/// 当天给时刻，昨天写「昨天」，再早写日期。
enum RelativeTime {
    static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "" }
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return clock(date) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return day(date)
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
