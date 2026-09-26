import Foundation
import UIKit

/// 管理端跟账号后端说话的唯一通道。
///
/// 后端（`server/account/app.py`）是**纯标准库**写的 http.server，返回全是 JSON；
/// 所有 `/api/admin/*` 都要 `Authorization: Bearer <token>`（见那边的 `current_user`）。
enum AdminAPI {

    /// 服务器地址。**默认线路一**，但登录页可以在线路一/线路二之间切，也可以手填
    /// （在本机对着测试服务器跑的时候用）。域名只在 `AevisHosts` 里定义一处。
    static let defaultBase = AevisHosts.accountBase
    private static let baseKey = "aevis.admin.base"

    static var base: String {
        get {
            let saved = UserDefaults.standard.string(forKey: baseKey) ?? ""
            return saved.isEmpty ? defaultBase : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: baseKey) }
    }

    /// 现在走的是哪条线路（"线路一" / "线路二"）；手填了别的地址就是 nil。
    static var activeLineName: String? { AevisHosts.lineName(for: base) }

    /// 探测两条线路，选第一条能通的。
    ///
    /// 判断口径和主 App **共用**（`AccountEndpoint.reachable`）—— 两边各判一套的话，
    /// 会出现"主 App 走线路二、管理端走线路一"，排查时对不上号。
    /// 返回选中的线路名；两条都不通返回 nil，让上层照常报错。
    @discardableResult
    static func autoPickLine() async -> String? {
        // 现在这条要是通着，就不动它 —— 免得用户手动选的线路每次开屏都被改回去
        if activeLineName != nil, await AccountEndpoint.reachable(base) {
            return activeLineName
        }
        for line in AevisHosts.accountLines where await AccountEndpoint.reachable(line.base) {
            base = line.base
            return line.name
        }
        return nil
    }

    /// 按名字切线路（登录页上点「线路二」）。
    @discardableResult
    static func useLine(named name: String) -> Bool {
        guard let line = AevisHosts.accountLines.first(where: { $0.name == name }) else {
            return false
        }
        base = line.base
        return true
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case network(String)
        case badReply
        /// 任务被取消（用户切走页面了）。**这不是错误，别拿出来吓人** ——
        /// 原来它会被塞进 `.network`，界面上写"连不上服务器（已取消）"，
        /// 看着像后台断了，其实只是他自己翻到别的页去了。
        case cancelled

        var errorDescription: String? {
            switch self {
            case .http(401, _): return "登录过期了，重新登录一次。"
            case .http(403, _): return "这个账号不是管理员。"
            case .http(let code, let message):
                return message.isEmpty ? "服务器返回 \(code)。" : message
            case .network(let detail): return detail
            case .badReply: return "服务器返回的东西看不懂（格式对不上）。"
            case .cancelled: return ""
            }
        }
    }

    // MARK: - 调用

    /// 发一个请求，把返回的 JSON 解成 `T`。
    static func call<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        token: String? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await raw(path, method: method, body: body, token: token)
        do {
            return try makeDecoder().decode(T.self, from: data)
        } catch {
            // 拿不到想要的字段不该让整个界面炸 —— 交给上层按「空」处理。
            throw Failure.badReply
        }
    }

    /// 只关心成功失败的接口。返回原始 body，调用方多数时候不用看。
    @discardableResult
    static func fire(
        _ path: String,
        method: String = "POST",
        body: [String: Any]? = nil,
        token: String? = nil
    ) async throws -> Data {
        try await raw(path, method: method, body: body, token: token)
    }

    // MARK: - 内部

    private static func raw(
        _ path: String,
        method: String,
        body: [String: Any]?,
        token: String?
    ) async throws -> Data {
        guard let url = URL(string: AdminAPI.base + path) else {
            throw Failure.network("服务器地址不对：「\(AdminAPI.base)」")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("aevis-admin-ios", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                throw Failure.http(status, message(from: data))
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw Failure.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw Failure.cancelled
        } catch {
            throw Failure.network("连不上服务器（\(error.localizedDescription)）")
        }
    }

    /// 出错时后端会给 `{"error": "...", "message": "人话"}`，优先取 `message`。
    private static func message(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return (object["message"] as? String) ?? (object["error"] as? String) ?? ""
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
