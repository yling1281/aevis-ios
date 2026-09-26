import Foundation
import UIKit

/// 管理端跟账号后端说话的唯一通道。
///
/// 后端（`server/account/app.py`）是**纯标准库**写的 http.server，返回全是 JSON；
/// 所有 `/api/admin/*` 都要 `Authorization: Bearer <token>`（见那边的 `current_user`）。
enum AdminAPI {

    /// 服务器地址。**默认写死线上那台**，但登录页可以改（在本机对着测试服务器跑的时候用）。
    static let defaultBase = "https://account.lingyan.cyou"
    private static let baseKey = "aevis.admin.base"

    static var base: String {
        get {
            let saved = UserDefaults.standard.string(forKey: baseKey) ?? ""
            return saved.isEmpty ? defaultBase : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: baseKey) }
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case network(String)
        case badReply

        var errorDescription: String? {
            switch self {
            case .http(401, _): return "登录过期了，重新登录一次。"
            case .http(403, _): return "这个账号不是管理员。"
            case .http(let code, let message):
                return message.isEmpty ? "服务器返回 \(code)。" : message
            case .network(let detail): return detail
            case .badReply: return "服务器返回的东西看不懂（格式对不上）。"
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
