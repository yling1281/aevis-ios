import Foundation

enum CatalogError: LocalizedError {
    case badURL
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "接口地址不对。"
        case let .http(status):
            switch status {
            case 401, 403: return "Key 被拒绝了（\(status)）。"
            case 404: return "这个接口没提供清单（404），可以手动填。"
            default: return "接口返回 \(status)。"
            }
        }
    }
}

/// 从接口上「拉取」可用清单：模型列表、音色列表。
///
/// 现实里各家实现并不统一，所以策略是分层的，任何一层成功就返回：
/// 标准路径 → 换几个候选路径 → 解析几种常见结构 → 退回内置清单。
/// **绝不因为拉不到就卡死**，最后总还能手动填。
enum ModelCatalog {

    struct Entry: Identifiable, Hashable {
        var id: String
        var name: String
        var detail: String = ""
    }

    /// OpenAI 系常见的音色，作为拉不到时的兜底。
    static let builtInVoices: [Entry] = [
        "alloy", "ash", "ballad", "coral", "echo",
        "fable", "nova", "onyx", "sage", "shimmer", "verse"
    ].map { Entry(id: $0, name: $0) }

    /// GET {base}/models
    static func fetchModels(config: LLMConfig) async throws -> [Entry] {
        let url = try endpoint(base: config.baseURL, appending: "models")
        let data = try await get(url: url, key: config.apiKey)
        return parseEntries(from: data)
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// 音色清单。返回 (清单, 是否真的来自接口)。
    static func fetchVoices(config: TTSConfig) async throws -> ([Entry], Bool) {
        for path in ["audio/voices", "voices", "audio/voice/list", "audio/speech/voices"] {
            guard let url = try? endpoint(base: config.baseURL, appending: path) else { continue }
            guard let data = try? await get(url: url, key: config.apiKey) else { continue }
            let entries = parseEntries(from: data)
            if !entries.isEmpty {
                return (entries, true)
            }
        }
        return (builtInVoices, false)
    }

    // MARK: - 底层

    private static func endpoint(base: String, appending path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CatalogError.badURL }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/" + path) else { throw CatalogError.badURL }
        return url
    }

    private static func get(url: URL, key: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw CatalogError.http(status: http.statusCode)
        }
        return data
    }

    /// 兼容几种常见结构：
    /// `{data:[{id,name}]}` / `{models:[...]}` / `{voices:[...]}` / `["a","b"]`
    private static func parseEntries(from data: Data) -> [Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }

        if let array = object as? [String] {
            return array.map { Entry(id: $0, name: $0) }
        }
        guard let root = object as? [String: Any] else { return [] }

        // 有些服务把清单再包一层，例如 {data:{voices:[...]}}
        for nestedKey in ["data", "result", "response"] {
            if let nested = root[nestedKey] as? [String: Any] {
                let entries = parseEntries(fromDictionary: nested)
                if !entries.isEmpty { return entries }
            }
        }
        return parseEntries(fromDictionary: root)
    }

    private static func parseEntries(fromDictionary root: [String: Any]) -> [Entry] {
        for key in ["data", "models", "voices", "items", "results", "list"] {
            guard let array = root[key] as? [Any] else { continue }
            let entries = array.compactMap { element -> Entry? in
                if let name = element as? String {
                    return Entry(id: name, name: name)
                }
                guard let dict = element as? [String: Any] else { return nil }
                let identifier = (dict["id"] as? String)
                    ?? (dict["voice_id"] as? String)
                    ?? (dict["voiceId"] as? String)
                    ?? (dict["voice"] as? String)
                    ?? (dict["name"] as? String)
                guard let id = identifier, !id.isEmpty else { return nil }
                let display = (dict["name"] as? String)
                    ?? (dict["display_name"] as? String)
                    ?? (dict["displayName"] as? String)
                    ?? id
                let detail = (dict["description"] as? String)
                    ?? (dict["gender"] as? String)
                    ?? ""
                return Entry(id: id, name: display, detail: detail)
            }
            if !entries.isEmpty { return entries }
        }
        return []
    }
}
