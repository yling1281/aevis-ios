import Foundation

/// 一个**群聊**。
///
/// 老板 2026-10 拍板要的：「至少 2 个 AI 在同一个群里一起聊，人数不限」。
///
/// ## 它是什么
/// 一个群 = 一群人（`memberIDs`，都是**通讯录里的联系人 id**）+ 一个名字。
/// 群自己也有一份聊天记录 —— 落在 `ChatStore` 里，**拿群的 `id` 当 key**
/// （`ChatStore.byContact` 本来就是 `[UUID: [ChatMessage]]`，不用改结构）。
///
/// ## 它和 `Contact`（联系人）的关系
/// 群**不含**人设 —— 人设永远在 `Contact.persona` 里，群只记「有哪些人」。
/// 所以「同一个联系人」可以既在一对一聊天里、又在好几个群里，
/// 不需要复制任何 persona。改一个人的人设，群里那个人的表现立刻跟着变。
///
/// ## ⚠️ 为什么类型叫 `ChatGroup`、不叫 `Group`
/// `Group` 是 **SwiftUI 自带的容器视图**（`Group { … }`），项目里有近十个页面在用。
/// Swift 里**同一个模块内的类型名会遮蔽掉 import 进来的同名类型** —— 一旦这里叫
/// `Group`，那些 `Group { … }` 会全部解析到这个结构体上、当场编不过。
/// 所以文件名照旧是 `Group.swift`，**类型名必须是 `ChatGroup`**。
///
/// ## ⚠️ 老存档兼容
/// `memberIDs` 给了默认 `[]`，并且手写 `init(from:)` 走 `decodeIfPresent` ——
/// 以后给群加字段（群头像、公告…）时，旧存档缺 key 也不会整份读崩。
/// 这是本项目的硬规矩（见 `Contact` / `Persona` / `HerApp` 各自的注释）。
struct ChatGroup: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// 群名。空的时候界面上给个占位，别留一行空白。
    var name: String = ""
    /// 群成员 —— **通讯录里联系人的 id**。顺序就是发言顺序。
    var memberIDs: [UUID] = []
    var createdAt: Date = Date()

    /// 界面上显示的名字。没起名字时给个占位。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名群聊" : trimmed
    }

    /// 成员个数（界面「N 个成员」用）。
    var memberCount: Int { memberIDs.count }

    // MARK: - 解码容错

    /// 手写解码：以后再加字段时，旧存档不会因为缺 key 而整个读不出来。
    /// （`Contact` / `Persona` / `HerApp` 那边也是这么做的，保持一致。）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) .flatMap { $0 } ?? UUID()
        name = (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 } ?? ""
        memberIDs = (try? container.decodeIfPresent([UUID].self, forKey: .memberIDs)).flatMap { $0 } ?? []
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)).flatMap { $0 } ?? Date()
    }

    /// 显式给一个空构造 —— 有了手写的 `init(from:)` 之后，
    /// 编译器**不再自动合成**逐一赋值的 `init()`，所以自己补一个。
    init(id: UUID = UUID(), name: String = "", memberIDs: [UUID] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.createdAt = createdAt
    }
}
