import Foundation

/// LocalStore 的合并 / 导出扩展（2026-11-17，133）。
/// 不修改 Models.swift：这里自带 convs.json 路径（LocalStore.url 是 private，
/// 跨文件扩展访问不到），只读写 convs.json，不碰其它 UserDefaults 数据。
extension LocalStore {
    private static var convsURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("convs.json")
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
