import Foundation

/// 把一次采集快照 POST 到服务器。
///
/// 规矩（都是项目硬要求）：
/// - 只走 **HTTPS**，不加任何 ATS 例外；
/// - 请求头带 `X-Phone-Key`（密钥）与 `Content-Type: application/json`；
/// - `URLSession` 超时 20 秒；
/// - 失败**重试 1 次**（共 2 次），不搞队列、不无限重试。
enum StatusUploader {

    /// 单次上报。返回服务器状态码与「原话」（截前 200 字，供界面显示）。
    static func upload(
        snapshot: StatusSnapshot,
        urlString: String,
        key: String
    ) async -> StatusUploadResult {
        var result = StatusUploadResult()
        result.at = Date()

        guard let url = normalizedURL(urlString) else {
            result.success = false
            result.status = 0
            result.message = "上报地址不合法（必须是 https:// 开头）"
            return result
        }

        guard let data = try? JSONSerialization.data(withJSONObject: makeBody(snapshot)) else {
            result.success = false
            result.status = 0
            result.message = "本地组包失败"
            return result
        }

        var status = -1
        var message = "连不上服务器"
        for attempt in 1...2 {
            let outcome = await post(data: data, url: url, key: key)
            status = outcome.status
            message = outcome.message
            if (200..<300).contains(status) { break }
            // 第一次失败，等 1 秒再试一次。
            if attempt == 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        result.status = status
        result.message = String(message.prefix(200))
        result.success = (200..<300).contains(status)
        return result
    }

    // MARK: - 组包

    /// 组出上报 JSON。**同时发两套键**：
    /// 1. 服务器契约里那批**确切键名**（`location` / `lat` / `lon` / `battery` /
    ///    `charging` / `model` / `os` / `network` / `wifi` / `steps`）—— 服务器只认这几个；
    /// 2. 我们自己那批明细键（`place` / `city` / `latitude` / `machine` /
    ///    `systemVersion` / …）—— 服务器会一并存着，方便以后查，不冲突。
    ///
    /// ⚠️ 每一项都是**可选**的：拿不到就**不写这个键**（不写 null、也不写空串）。
    private static func makeBody(_ snapshot: StatusSnapshot) -> [String: Any] {
        var body: [String: Any] = [:]
        body["collectedAt"] = ISO8601DateFormatter().string(from: snapshot.collectedAt)

        // 设备 / 系统
        body["machine"] = snapshot.machine
        body["deviceName"] = snapshot.deviceName
        body["systemName"] = snapshot.systemName
        body["systemVersion"] = snapshot.systemVersion
        if !snapshot.machine.isEmpty {
            body["model"] = snapshot.machine
        }
        let osText = systemText(snapshot)
        if !osText.isEmpty {
            body["os"] = osText
        }

        // 电量：契约要的是 0-100 的整数百分比 + 是否充电。
        if snapshot.hasBattery {
            body["batteryLevel"] = snapshot.batteryLevel
            body["batteryCharging"] = snapshot.batteryCharging
            body["battery"] = snapshot.batteryLevel
            body["charging"] = snapshot.batteryCharging
        }

        // 位置：契约要的是中文地名 `location` + 坐标 `lat` / `lon`。
        if snapshot.hasLocation {
            body["latitude"] = snapshot.latitude
            body["longitude"] = snapshot.longitude
            body["horizontalAccuracy"] = snapshot.horizontalAccuracy
            body["place"] = snapshot.place
            body["city"] = snapshot.city
            body["district"] = snapshot.district
            body["street"] = snapshot.street
            if snapshot.hasSpeed {
                body["speed"] = snapshot.speed
            }

            body["lat"] = snapshot.latitude
            body["lon"] = snapshot.longitude
            if let name = locationText(snapshot) {
                body["location"] = name
            }
        }

        // 网络
        if snapshot.hasNetwork {
            body["networkOnline"] = snapshot.networkOnline
            body["networkKind"] = snapshot.networkKind
            if !snapshot.networkKind.isEmpty {
                body["network"] = snapshot.networkKind
            }
        }

        // WiFi：契约键 `wifi` + 明细键 `wifiName`，**拿不到就两个都不写**。
        if !snapshot.wifiName.isEmpty {
            body["wifiName"] = snapshot.wifiName
            body["wifi"] = snapshot.wifiName
        }

        // 步数
        if snapshot.hasSteps {
            body["steps"] = snapshot.steps
        }

        return body
    }

    /// 契约里的 `location`：优先用逆地理出来的完整中文地名；
    /// 完整地名为空时，用非空的 市 / 区 / 街道 拼一个；全空就返回 nil（不写这个键）。
    private static func locationText(_ snapshot: StatusSnapshot) -> String? {
        if !snapshot.place.isEmpty {
            return snapshot.place
        }
        let parts = [snapshot.city, snapshot.district, snapshot.street].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "")
    }

    /// 契约里的 `os`：拼成 `iOS 26.2` 这种好读的形式；拼不出来就退回原始版本号。
    private static func systemText(_ snapshot: StatusSnapshot) -> String {
        if snapshot.systemName.isEmpty { return snapshot.systemVersion }
        if snapshot.systemVersion.isEmpty { return snapshot.systemName }
        return "\(snapshot.systemName) \(snapshot.systemVersion)"
    }

    // MARK: - 单次请求

    private static func post(data: Data, url: URL, key: String) async -> (status: Int, message: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Phone-Key")
        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: responseData, encoding: .utf8) ?? ""
            return (status, text.isEmpty ? "HTTP \(status)" : text)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    // MARK: - 地址

    private static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme,
              scheme.lowercased() == "https" else { return nil }
        return url
    }
}
