import Foundation
import Combine
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

/// 网易云扫码登录（原生二维码）。
///
/// 之前只有「在网页里登录」一条路（`NeteaseLogin` 那个 WKWebView）。
/// 用户 2026-10-31 要的是**默认弹一张二维码**，用手机上的网易云 App 扫一下就登进来了
/// —— 不用再在网页里点。
///
/// ## 流程
/// 1. `unikey`：`POST /weapi/login/qrcode/unikey` → 拿到 `unikey`。
/// 2. 把 `https://music.163.com/scan_qrcode?codekey=<unikey>` 画成二维码。
/// 3. 轮询 `POST /weapi/login/qrcode/client/login`（`key=unikey`）：
///    - 800 二维码过期 / 801 等着扫 / 802 扫了还没确认 / 803 确认成功。
/// 4. 803 时网易会在响应的 `Set-Cookie` 里把 `MUSIC_U` 等会话 cookie 发回来，
///    我们原样存进 `AppSettings`（和网页登录走的是同一份凭据）。
///
/// ⚠️ 这一套走的是 **weapi 加密通道**。之前 `NeteaseClient` 实测「搜索」那条 weapi 被掐了，
/// 但登录相关的 weapi 端点不一定同命 —— 所以这里的失败要**安静地退回网页版**。
/// 二维码拿不到 / 轮询不通，调用方就显示「改用网页版登录」，别崩。
///
/// ⚠️ 二维码里塞的 URL 格式（`scan_qrcode?codekey=`）是按公开资料拼的，
/// 网易那边换格式的话，扫出来不会跳转 —— 那种情况退回网页版即可。
@MainActor
final class NeteaseQRLogin: ObservableObject {
    static let shared = NeteaseQRLogin()

    enum Status: Equatable {
        case idle
        case loadingKey      // 正在要 unikey
        case waiting         // 二维码已出，等用户扫
        case scanned         // 扫了，等用户在手机上点确认
        case expired         // 二维码过期，需刷新
        case loggedIn        // 成功
        case failed(String)  // 拿不到二维码等非过期错误
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var unikey: String?
    @Published private(set) var qrImage: UIImage?

    private var task: Task<Void, Never>?

    private let base = "https://music.163.com"
    private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    private init() {}

    /// 开始：拿 unikey + 出二维码 + 开始轮询。
    func start() {
        guard task == nil else { return }
        status = .loadingKey
        task = Task { await run() }
    }

    /// 停掉轮询（离开页面时）。
    func stop() {
        task?.cancel()
        task = nil
        status = .idle
        unikey = nil
        qrImage = nil
    }

    /// 二维码过期后手动刷新一张。
    func refresh() {
        stop()
        start()
    }

    // MARK: - 主循环

    private func run() async {
        do {
            let key = try await fetchUnikey()
            guard !Task.isCancelled else { return }
            self.unikey = key
            self.qrImage = Self.makeQR("https://music.163.com/scan_qrcode?codekey=\(key)")
            self.status = .waiting

            // 轮询，最多 ~2 分钟（网易二维码有效期约 120s）。
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }

                let code = try await check(key: key)
                switch code {
                case 800:
                    self.status = .expired
                    return
                case 802:
                    if self.status != .scanned { self.status = .scanned }
                case 803:
                    self.status = .loggedIn
                    self.task = nil
                    return
                default:
                    break // 801 或其它：继续等
                }
            }
            self.status = .expired
        } catch {
            guard !Task.isCancelled else { return }
            self.status = .failed(error.localizedDescription)
        }
    }

    // MARK: - 接口

    /// 拿 unikey。复用 `NeteaseCrypto` 的 weapi 加密，自己发请求（要抓 Set-Cookie）。
    private func fetchUnikey() async throws -> String {
        guard let payload = NeteaseCrypto.weapi(params: ["type": 1]) else {
            throw NSError(domain: "qr", code: -1, userInfo: [NSLocalizedDescriptionKey: "加密失败"])
        }
        let (json, _) = try await post("/weapi/login/qrcode/unikey", payload)
        guard let unikey = json["unikey"] as? String, !unikey.isEmpty else {
            throw NSError(domain: "qr", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "没拿到 unikey（\(Self.brief(json))）"])
        }
        return unikey
    }

    /// 轮询扫码状态。返回网易的业务码；803 时顺手把会话 cookie 存下来。
    private func check(key: String) async throws -> Int {
        guard let payload = NeteaseCrypto.weapi(params: ["key": key, "type": 1]) else { return -1 }
        let (json, cookies) = try await post("/weapi/login/qrcode/client/login", payload)

        // 803 = 确认成功：从 Set-Cookie 里抠出网易的会话 cookie。
        if let code = json["code"] as? Int, code == 803 {
            let header = cookies
                .filter { $0.domain.lowercased().contains("163.com") }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            if header.contains("MUSIC_U=") {
                AppSettings.shared.neteaseCookie = header
            }
        }

        return (json["code"] as? Int) ?? -1
    }

    // MARK: - 请求（自己发，为了拿 Set-Cookie）

    private func post(_ path: String, _ form: [String: String]) async throws
        -> ([String: Any], [HTTPCookie]) {
        guard let url = URL(string: base + path + "?csrf_token=") else {
            throw NSError(domain: "qr", code: -1, userInfo: [NSLocalizedDescriptionKey: "路径拼错了"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue(base, forHTTPHeaderField: "Referer")
        request.setValue(base + "/", forHTTPHeaderField: "Origin")
        if !AppSettings.shared.neteaseCookie.isEmpty {
            request.setValue(AppSettings.shared.neteaseCookie, forHTTPHeaderField: "Cookie")
        }
        let body = "params=\(Self.enc(form["params"] ?? ""))&encSecKey=\(Self.enc(form["encSecKey"] ?? ""))"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Set-Cookie 在响应头里，要自己抠出来。
        let fields = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        var cookieHeaders: [String: String] = [:]
        for (k, v) in fields {
            if let key = k as? String, let value = v as? String {
                cookieHeaders[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: url)

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "qr", code: -1, userInfo: [NSLocalizedDescriptionKey: "返回不是 JSON"])
        }
        return (json, cookies)
    }

    private static func enc(_ text: String) -> String {
        // weapi 的 form 编码：只留安全字符，其它（尤其 + / =）必须编掉。
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: safe) ?? text
    }

    private static func brief(_ json: [String: Any]) -> String {
        let code = (json["code"] as? Int).map { "code=\($0) " } ?? ""
        return code + "字段：" + json.keys.sorted().prefix(6).joined(separator: ",")
    }

    // MARK: - 二维码图

    /// 用 CoreImage 现画一个二维码（iOS 自带，不引第三方库）。
    private static func makeQR(_ content: String) -> UIImage? {
        #if canImport(UIKit)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
        #else
        return nil
        #endif
    }
}
