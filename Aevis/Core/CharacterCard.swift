import Foundation

/// 角色卡导入。
///
/// 支持两种常见格式：
/// 1. **SillyTavern V2 / V1 的 JSON 卡片**（`{spec, data:{...}}` 或直接平铺）
/// 2. **PNG 卡片** —— 卡片图里藏了一个 `tEXt` 块，关键字是 `chara`（或 `ccv3`），
///    内容是 base64 过的 JSON。这是社区里最流行的分发方式。
///
/// 导入只做映射，不改人设的结构：能对上的填进去，对不上的**不硬塞**。
enum CharacterCard {

    struct Result {
        var persona: Persona
        /// 卡片里的开场白。导入后可以直接当第一条消息用。
        var firstMessage: String?
        /// 卡片里给出的原始名字，界面提示用。
        var sourceName: String
        /// 这个卡片是哪来的，界面提示用。
        var origin: String
    }

    // MARK: - 入口

    /// 从文件数据里尽力读出一张卡。读不出来就返回 nil。
    static func parse(_ data: Data) -> Result? {
        // 先试 PNG，再试纯 JSON
        if let payload = extractPNGPayload(data), let result = parseJSON(payload, origin: "PNG 角色卡") {
            return result
        }
        return parseJSON(data, origin: "JSON 角色卡")
    }

    /// 从卡片 JSON 里读。
    static func parseJSON(_ data: Data, origin: String) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // V2 把真正的字段藏在 data 里；V1 是平铺的。两种都吃。
        let body: [String: Any]
        if let nested = root["data"] as? [String: Any] {
            body = nested
        } else {
            body = root
        }

        let name = string(body, "name")
        let description = string(body, "description")
        let personality = string(body, "personality")
        let scenario = string(body, "scenario")
        let example = string(body, "mes_example")
        let firstMessage = string(body, "first_mes")

        // 名字、描述、性格全空，多半不是角色卡
        guard !name.isEmpty || !description.isEmpty || !personality.isEmpty else {
            return nil
        }

        var persona = Persona()
        persona.name = name

        // 性格：personality 为主，description 补充。
        // 卡片作者经常只填其中一个，所以两个都收。
        var traits: [String] = []
        if !personality.isEmpty { traits.append(personality) }
        if !description.isEmpty, description != personality { traits.append(description) }
        persona.personality = traits.joined(separator: "\n\n")

        // 场景 → 你们的关系（最接近的一栏）
        persona.relationship = scenario

        // 对话示例 → 说话方式。示例最能说明「这个人怎么说话」。
        persona.speakingStyle = cleanExample(example)

        // 性别不预设：卡片里根本没有这个字段，
        // 从名字或描述去猜性别是不负责任的（用户明确要求人设不预设性别）。
        persona.gender = .unspecified

        return Result(
            persona: persona,
            firstMessage: firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : firstMessage,
            sourceName: name,
            origin: origin
        )
    }

    private static func string(_ body: [String: Any], _ key: String) -> String {
        (body[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 卡片里的对话示例通常带 `<START>`、`{{user}}`、`{{char}}` 这类占位符，先清掉。
    private static func cleanExample(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var text = raw
        // 先处理「{{char}}:」这种带冒号的写法 ——
        // 只删 {{char}} 会留下一个孤零零的冒号在行首（对拍测试时发现的）。
        for token in ["{{char}}:", "{{char}}：", "{{char}}"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: "{{user}}", with: "对方")
        for token in ["<START>", "<start>", "<START >"] {
            text = text.replacingOccurrences(of: token, with: "")
        }

        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // 清掉占位符之后可能只剩一个冒号或逗号，这种行没有信息量
            .filter { line in
                line.contains { $0.isLetter || $0.isNumber }
            }
        return lines.prefix(12).joined(separator: "\n")
    }

    // MARK: - PNG 里的隐藏 JSON
    //
    // 结构：8 字节签名，然后一串 `[长度4][类型4][数据][CRC4]`。
    // 长度是**大端**的 4 字节。这些细节写错会静默读不到任何东西，
    // 所以全程用字节数组 + 显式边界判断，不用 Data 切片（切片下标溢出会直接崩）。

    static func extractPNGPayload(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count > 8, Array(bytes.prefix(8)) == signature else { return nil }

        var offset = 8
        // 正常卡片只有十来个块。给个上限，坏文件不至于死循环。
        var scanned = 0

        while offset + 8 <= bytes.count, scanned < 512 {
            scanned += 1

            guard let length = readUInt32(bytes, at: offset) else { return nil }
            let typeStart = offset + 4
            guard typeStart + 4 <= bytes.count else { return nil }
            let type = String(bytes: bytes[typeStart..<typeStart + 4], encoding: .ascii) ?? ""

            let payloadStart = typeStart + 4
            let payloadEnd = payloadStart + length
            // 末尾还要留 4 字节 CRC
            guard payloadEnd >= payloadStart, payloadEnd + 4 <= bytes.count else { return nil }
            let payload = Array(bytes[payloadStart..<payloadEnd])

            if type == "tEXt", let text = decodeTextChunk(payload),
               let decoded = decodeCardText(text) {
                return decoded
            }
            if type == "iTXt", let text = decodeITXtChunk(payload),
               let decoded = decodeCardText(text) {
                return decoded
            }
            if type == "IEND" { break }

            offset = payloadEnd + 4
        }
        return nil
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        var value = 0
        for index in offset..<(offset + 4) {
            value = value << 8 | Int(bytes[index])
        }
        return value
    }

    /// tEXt：`关键字\0正文`
    private static func decodeTextChunk(_ bytes: [UInt8]) -> String? {
        guard let separator = bytes.firstIndex(of: 0) else { return nil }
        let keyword = String(bytes: bytes[0..<separator], encoding: .utf8) ?? ""
        guard keyword == "chara" || keyword == "ccv3" else { return nil }
        let body = Array(bytes[(separator + 1)...])
        return String(bytes: body, encoding: .utf8)
            ?? String(bytes: body, encoding: .isoLatin1)
    }

    /// iTXt：`关键字\0 压缩标志1 压缩方法1 语言\0 翻译关键字\0 正文`
    /// 只处理**没压缩**的（卡片基本都是这种）。
    private static func decodeITXtChunk(_ bytes: [UInt8]) -> String? {
        guard let firstZero = bytes.firstIndex(of: 0) else { return nil }
        let keyword = String(bytes: bytes[0..<firstZero], encoding: .utf8) ?? ""
        guard keyword == "chara" || keyword == "ccv3" else { return nil }

        var cursor = firstZero + 1
        guard cursor + 1 < bytes.count else { return nil }
        let compressionFlag = bytes[cursor]
        cursor += 2  // 压缩标志 + 压缩方法

        guard cursor <= bytes.count,
              let languageEnd = bytes[cursor...].firstIndex(of: 0) else { return nil }
        cursor = languageEnd + 1

        guard cursor <= bytes.count,
              let translatedEnd = bytes[cursor...].firstIndex(of: 0) else { return nil }
        cursor = translatedEnd + 1

        guard cursor <= bytes.count, compressionFlag == 0 else { return nil }
        return String(bytes: Array(bytes[cursor...]), encoding: .utf8)
    }

    /// tEXt 里放的是 base64 过的 JSON。也有偷懒直接放 JSON 的，两种都试。
    private static func decodeCardText(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return Data(trimmed.utf8)
        }
        // base64 里可能夹换行，去掉再解
        let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: compact)
    }
}
