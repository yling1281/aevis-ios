import Foundation
import SwiftUI
import UIKit
import CryptoKit

/// LocalStore 的合并 / 导出扩展（2026-11-17，133）。
/// 不修改 Models.swift：这里自带 convs.json 路径（LocalStore.url 是 private，
/// 跨文件扩展访问不到），只读写 convs.json，不碰其它 UserDefaults 数据。
extension LocalStore {
    private static var convsURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("convs.json")
    }

    // MARK: - 角色列表本地缓存（2026-11-24，断网也能看会话列表）

    /// 角色列表缓存文件：`Documents/aevis-personas.json`。
    private static var personasURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("aevis-personas.json")
    }

    /// 把服务端拉到的角色列表存到本地（下次断网时用来顶上）。
    /// 永不抛异常：存不下也不能影响聊天。
    static func savePersonas(_ list: [Persona]) {
        guard !list.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: personasURL, options: .atomic)
        } catch {
            NSLog("[LocalStoreExt] savePersonas failed: \(error.localizedDescription)")
        }
    }

    /// 读本地角色缓存；没有/损坏一律返回 `[]`（调用方据此走兜底）。
    static func loadPersonas() -> [Persona] {
        guard let data = try? Data(contentsOf: personasURL),
              let list = try? JSONDecoder().decode([Persona].self, from: data)
        else { return [] }
        return list
    }

    /// 兜底：缓存为空（首次装/被清）但本地 convs.json 里已经有会话时，
    /// 用会话 pid 构造最小角色（name 用 pid），保证**至少能点进去看到历史**。
    /// 按最后活跃时间倒序（本地有记录的排前面）。
    static func fallbackPersonas() -> [Persona] {
        let pids = Array(exportAll().keys)
        guard !pids.isEmpty else { return [] }
        return pids
            .sorted { (lastAt($0) ?? .distantPast) > (lastAt($1) ?? .distantPast) }
            .map { Persona(id: $0, name: $0.isEmpty ? "角色" : $0, tagline: "", avatar: "") }
    }

    /// 读出全部会话，原样返回（发消息后备份上云用）。
    static func exportAll() -> [String: [[String: Any]]] {
        guard let data = try? Data(contentsOf: convsURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[String: Any]]]
        else { return [:] }
        return dict
    }

    /// 把云端会话合并进本地，返回本次新增的条数。
    ///
    /// 去重策略（关键）：以 (role, content, w, i, q) 五元组做指纹。
    /// 本地已有该 pid → 本地消息全程保留、绝不删除；云端只在"本地完全没出现过"
    /// 时才补进来，且补进来的也加入指纹集合，保证重复恢复是幂等的。
    /// 本地没有该 pid → 整段写入。
    static func merge(cloud: [String: [[String: Any]]]) -> Int {
        guard !cloud.isEmpty else { return 0 }

        var dict = (try? Data(contentsOf: convsURL))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]

        // 五元组指纹：带长度前缀，避免分隔符与正文冲突
        func fingerprint(_ row: [String: Any]) -> String {
            let role = row["role"] as? String ?? ""
            let content = row["content"] as? String ?? ""
            let w = row["w"] as? String ?? ""
            let i = row["i"] as? String ?? ""
            let q = row["q"] as? String ?? ""
            return [role, content, w, i, q]
                .map { "\($0.utf8.count):\($0)" }
                .joined()
        }

        var totalAdded = 0
        for (pid, cloudRows) in cloud {
            let localRows = dict[pid] as? [[String: Any]] ?? []
            if localRows.isEmpty {
                // 本地没有该 pid：整段写入
                dict[pid] = cloudRows
                totalAdded += cloudRows.count
                continue
            }

            // 本地已有：本地全留，云端只补本地没出现过的
            var seen = Set(localRows.map(fingerprint))
            var merged = localRows
            var added = 0
            for row in cloudRows {
                let fp = fingerprint(row)
                guard !seen.contains(fp) else { continue }
                merged.append(row)
                seen.insert(fp)
                added += 1
            }
            dict[pid] = merged
            totalAdded += added
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            NSLog("[LocalStoreExt] serialize failed")
            return totalAdded
        }
        do {
            try data.write(to: convsURL)
        } catch {
            NSLog("[LocalStoreExt] write failed: \(error.localizedDescription)")
        }
        return totalAdded
    }
}

// MARK: - 会话二级菜单需要的本地操作（2026-11-27）
//
// 全部落在本机：置顶/备注走 UserDefaults，清空/删除改 convs.json，
// 导出/导入是一个自包含 JSON（换机迁移用），不依赖服务端。

extension LocalStore {
    private static func pinKey(_ pid: String) -> String { "convpin_\(pid)" }
    private static func aliasKey(_ pid: String) -> String { "convalias_\(pid)" }

    static func isPinned(_ pid: String) -> Bool {
        UserDefaults.standard.bool(forKey: pinKey(pid))
    }

    static func setPinned(_ pid: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: pinKey(pid))
    }

    /// 返回操作后的状态，方便 UI 立刻翻转文案。
    @discardableResult
    static func togglePinned(_ pid: String) -> Bool {
        let next = !isPinned(pid)
        setPinned(pid, next)
        return next
    }

    /// 备注名（用户自己起的名字）。空 = 没设过。
    static func alias(_ pid: String) -> String {
        (UserDefaults.standard.string(forKey: aliasKey(pid)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setAlias(_ pid: String, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { UserDefaults.standard.removeObject(forKey: aliasKey(pid)) }
        else { UserDefaults.standard.set(t, forKey: aliasKey(pid)) }
    }

    /// 列表上该显示的名字：有备注用备注，没有用角色原名。
    static func displayName(_ pid: String, fallback: String) -> String {
        let a = alias(pid)
        return a.isEmpty ? fallback : a
    }

    /// 清空某个会话的消息，角色本身保留（下次进去还是这个人）。
    static func clearConv(_ pid: String) {
        var dict = (try? Data(contentsOf: convsURL))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        dict[pid] = [[String: Any]]()
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: convsURL)
        }
        setUnread(pid, 0)
    }

    /// 彻底删掉这个会话：消息 + 时间 + 未读 + 备注 + 置顶标记一起清。
    static func deleteConv(_ pid: String) {
        var dict = (try? Data(contentsOf: convsURL))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        dict.removeValue(forKey: pid)
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: convsURL)
        }
        let d = UserDefaults.standard
        d.removeObject(forKey: "convAt_\(pid)")
        d.removeObject(forKey: "unread_\(pid)")
        d.removeObject(forKey: aliasKey(pid))
        d.removeObject(forKey: pinKey(pid))
    }

    /// 会话最后一条消息的摘要（导出/列表预览共用）。
    static func lastLine(_ pid: String) -> String {
        guard let last = load(pid: pid).last else { return "" }
        if !last.img.isEmpty { return "[图片]" }
        if last.content.hasPrefix("[语音]") { return "[语音]" }
        return last.content.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - 导出 / 导入（换机迁移）

    struct ChatArchive: Codable {
        var app: String
        var schema: Int
        var exportedAt: String
        var convs: [String: [[String: String]]]
        var aliases: [String: String]
        var pins: [String]
    }

    /// 生成导出文件，返回可分享的 URL；失败返回 nil。
    static func exportChatArchive() -> URL? {
        let raw = exportAll()          // [pid: [[String: Any]]]
        var convs: [String: [[String: String]]] = [:]
        for (pid, rows) in raw {
            convs[pid] = rows.map { row in
                var out: [String: String] = [:]
                for (k, v) in row {
                    if let s = v as? String { out[k] = s }
                }
                return out
            }
        }
        // 备注 / 置顶：扫一遍已知 pid（convs 的 key + 本地角色缓存）
        var aliases: [String: String] = [:]
        var pins: [String] = []
        var pids = Set(convs.keys)
        for p in loadPersonas() { pids.insert(p.id) }
        for pid in pids {
            let a = alias(pid)
            if !a.isEmpty { aliases[pid] = a }
            if isPinned(pid) { pins.append(pid) }
        }
        let fmt = ISO8601DateFormatter()
        let archive = ChatArchive(app: "aevis", schema: 1,
                                  exportedAt: fmt.string(from: Date()),
                                  convs: convs, aliases: aliases, pins: pins)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(archive) else { return nil }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let url = dir.appendingPathComponent("aevis-chat-\(df.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("[LocalStore] export failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 导入导出文件。只补不覆盖（复用 merge 的去重规则），返回 (会话数, 新增消息数)。
    static func importChatArchive(from url: URL) throws -> (convs: Int, msgs: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        let archive = try dec.decode(ChatArchive.self, from: data)
        var cloud: [String: [[String: Any]]] = [:]
        for (pid, rows) in archive.convs {
            cloud[pid] = rows.map { $0 as [String: Any] }
        }
        let added = merge(cloud: cloud)
        for (pid, name) in archive.aliases where alias(pid).isEmpty {
            setAlias(pid, name)
        }
        for pid in archive.pins { setPinned(pid, true) }
        return (archive.convs.count, added)
    }
}


//
// 用户要求：「头像如果在的话就硬缓存，检测到更新了才给你更新」。
// 做法：
//   1. 加载过就落盘：`Documents/aevis-imgcache/<sha256(url)>.img`，元数据同目录 `.json`
//      （ETag / Last-Modified / 最后校验时间）；
//   2. 下次**先读磁盘立刻出图**，不转圈；断网也照样有图；
//   3. 后台再发一个带 `If-None-Match` / `If-Modified-Since` 的轻请求：
//      304 → 只更新时间戳，什么图都不换；200 → 覆盖磁盘并刷新 UI。
// 只服务头像这类小图，文件名按 URL 固定，不做容量淘汰（量级 = 角色数 + 1）。

final class ImageCache {
    static let shared = ImageCache()

    /// 同一个 URL 10 分钟内只校验一次，避免切 tab / 列表重绘反复打接口
    private let revalidateInterval: TimeInterval = 600
    private let fm = FileManager.default
    private let dir: URL

    private init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("aevis-imgcache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: 路径（文件名 = scope + URL 的 SHA256）
    //
    // 2.8：scope 参与哈希。头像必须跟 uid / persona id 绑定，否则同一个视图被复用去显示
    // 另一个人时，磁盘上如果两个 URL 恰好一致（例如后端返回空串），就可能串图。

    private func stem(_ url: URL, scope: String) -> String {
        SHA256.hash(data: Data((scope + "|" + url.absoluteString).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func imagePath(_ url: URL, scope: String) -> URL {
        dir.appendingPathComponent(stem(url, scope: scope) + ".img")
    }

    private func metaPath(_ url: URL, scope: String) -> URL {
        dir.appendingPathComponent(stem(url, scope: scope) + ".json")
    }

    private func readMeta(_ url: URL, scope: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: metaPath(url, scope: scope)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeMeta(_ url: URL, scope: String, _ meta: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: meta) else { return }
        try? data.write(to: metaPath(url, scope: scope), options: .atomic)
    }

    // MARK: 读 / 校验

    /// 磁盘缓存（小图同步读）。没有就 nil —— 调用方直接显示占位，**不要转圈**。
    func cached(_ url: URL, scope: String = "") -> UIImage? {
        guard let data = try? Data(contentsOf: imagePath(url, scope: scope)) else { return nil }
        return UIImage(data: data)
    }

    /// 条件请求：真变了才返回新图；304 / 未到校验间隔 / 断网都返回 nil（保留旧图）。
    /// 2.8：改用 APIClient 的线路 session —— 直连是自签证书，URLSession.shared 会直接 SSL 失败，
    /// 这正是「广场头像加载不出来」的根因；北京线路仍走 shared。
    func revalidate(_ url: URL, scope: String = "") async -> UIImage? {
        let meta = readMeta(url, scope: scope)
        let now = Date().timeIntervalSince1970
        if let checked = meta["checked"] as? Double, now - checked < revalidateInterval { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if let etag = meta["etag"] as? String, !etag.isEmpty {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lm = meta["lastModified"] as? String, !lm.isEmpty {
            req.setValue(lm, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, resp) = try await APIClient.mediaSession(for: url).data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }

            // 304：服务器说没变 —— 只刷新校验时间，图不动
            if http.statusCode == 304 {
                var m = meta
                m["checked"] = now
                writeMeta(url, scope: scope, m)
                return nil
            }
            guard (200..<300).contains(http.statusCode), let img = UIImage(data: data) else { return nil }
            try? data.write(to: imagePath(url, scope: scope), options: .atomic)
            writeMeta(url, scope: scope, [
                "etag": http.value(forHTTPHeaderField: "ETag") ?? "",
                "lastModified": http.value(forHTTPHeaderField: "Last-Modified") ?? "",
                "checked": now
            ])
            return img
        } catch {
            return nil       // 断网 / 超时：保留磁盘旧图，什么都不做
        }
    }
}

/// 头像专用：磁盘缓存优先 + 后台条件校验的 `AsyncImage` 替代品。
///
/// 与 `AsyncImage` 的区别：
/// - 只要磁盘有图就**立刻**显示，不会因为网络慢一直转圈；
/// - 占位只在「真的没图」时出现（首次加载 / 断网且无缓存）；
/// - 后台 304 时不重绘，图变了才更新。
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    /// 身份作用域：uid / persona.id / pack.id。参与磁盘文件名，防止列表复用时串图。
    var scope: String = ""
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: "\(scope)|\(url?.absoluteString ?? "")") {
            // 2.8 修「头像串图」：身份一变先清空上一张，再读新身份的磁盘图。
            // 旧版只在 `if let disk` 成功时赋值，新 URL 没有缓存时上一张会一直挂着。
            image = nil
            guard let url else { return }
            // 1) 先读磁盘：有就立刻出图（不转圈）
            image = HardCache.image(url: url, scope: scope)
            // 2) 后台条件请求：304 什么都不做，真变了才换
            if let fresh = await HardCache.refreshImage(url: url, scope: scope) { image = fresh }
        }
    }
}
