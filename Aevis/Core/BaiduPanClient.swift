import CryptoKit
import Foundation

enum BaiduPanError: LocalizedError {
    case notConfigured
    case notAuthorized
    case api(errno: Int)
    case http(status: Int, body: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填百度网盘的 AppKey / SecretKey。去「我 → 设置 → 百度网盘」填一下。"
        case .notAuthorized:
            return "还没授权百度网盘。去「我 → 设置 → 百度网盘」点「去授权」，登录后把页面上那串授权码贴回来。"
        case let .api(errno):
            return "百度网盘返回错误码 \(errno)\(Self.hint(errno))"
        case let .http(status, body):
            return "百度网盘 HTTP \(status)：\(body.prefix(160))"
        case let .badResponse(text):
            return "百度网盘返回的内容看不懂：\(text.prefix(160))"
        }
    }

    /// errno 的数字对用户没有意义，翻成人话。
    private static func hint(_ errno: Int) -> String {
        switch errno {
        case -6:
            return "（通行证失效了，重新授权一次就好）"
        case -7:
            return "（文件或目录名不对）"
        case -8:
            return "（目录非空）"
        case -9:
            return "（文件不存在）"
        case 2:
            return "（参数不对）"
        case 31066:
            return "（这个应用还没通过实名或权限审批，去开放平台看一眼）"
        default:
            return ""
        }
    }
}

/// 网盘里的一个文件或目录。
struct PanFile: Identifiable, Hashable {
    var id: Int64
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modifiedAt: Date?

    var sizeText: String {
        if isDirectory { return "" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1024 / 1024)
    }

    /// 列表里那一行说明。
    var detail: String {
        if isDirectory { return "文件夹" }
        var parts = [sizeText]
        if let modifiedAt {
            parts.append(RelativeTime.label(for: modifiedAt))
        }
        return parts.joined(separator: " · ")
    }
}

/// 百度网盘客户端。
///
/// ## 为什么必须走 OAuth
/// App **拿不到"用户的网盘"**。得先让用户在浏览器里点一次「同意授权」，
/// 百度给一个 code，用 code 换 `access_token`，之后才能读写。
/// 这是百度的规矩，绕不过去，也正因为如此才需要一个"开发者应用"出面。
///
/// ## 回调地址是内网地址怎么办（用户实际遇到的情况）
/// 授权完成后百度会跳回开发者登记的那个地址。如果登记的是内网
/// （`http://192.168.x.x/...`），手机上多半打不开 ——
/// **但地址栏里会带着 `?code=xxx`**，复制出来一样能用。
/// 更省事的是把后台的回调改成 `oob`，那样百度页面会**直接把授权码显示出来**。
/// 两种情况这个类都认：`cleanCode` 会把粘进来的整段 URL 洗成纯 code。
///
/// ## 两个必踩的坑（都写在对应位置了）
/// 1. 请求头**必须带 `User-Agent: pan.baidu.com`** —— 换别的（包括默认 UA）一律 403。
/// 2. `access_token` 约 30 天过期，要用 `refresh_token` **自动续**，
///    不能让用户重新授权一遍。
final class BaiduPanClient {

    static let shared = BaiduPanClient()

    /// 备份都放这个目录，省得用户在整个网盘里翻。
    static let backupDir = "/Aevis备份"

    private let authorizeEndpoint = "https://openapi.baidu.com/oauth/2.0/authorize"
    private let tokenEndpoint = "https://openapi.baidu.com/oauth/2.0/token"
    private let panBase = "https://pan.baidu.com/rest/2.0/xpan"
    private let uploadBase = "https://d.pcs.baidu.com"

    /// 百度网盘 API 只认这个 UA —— 这是接它最容易栽的一次。
    private let panUA = "pan.baidu.com"

    /// 分片大小。百度不支持一把梭上传，必须切片 + 每片报 MD5。
    private static let chunkSize = 4 * 1024 * 1024

    private var appKey: String { AppSettings.shared.baiduPanAppKey }
    private var secretKey: String { AppSettings.shared.baiduPanSecretKey }

    /// 登记的那个回调地址。留空就按 `oob` 走（授权码显示在页面上）。
    private var redirect: String {
        let value = AppSettings.shared.baiduPanRedirect
        return value.isEmpty ? "oob" : value
    }

    private init() {}

    // MARK: - 状态

    var isConfigured: Bool {
        !appKey.isEmpty && !secretKey.isEmpty
    }

    var isAuthorized: Bool {
        !AppSettings.shared.baiduPanToken.isEmpty
    }

    /// 通行证到期时刻。提前一小时就算过期，免得正好卡边界上失败。
    var expiresAt: Date? {
        let stamp = AppSettings.shared.baiduPanExpiresAt
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    // MARK: - 授权

    /// 拿去给浏览器打开的授权页。没填 AppKey 就返回 nil。
    func authorizeURL() -> URL? {
        guard isConfigured else { return nil }
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: "basic,netdisk"),
            URLQueryItem(name: "force_login", value: "1")
        ]
        return components?.url
    }

    /// 用授权码换通行证。
    func exchange(code raw: String) async throws {
        guard isConfigured else { throw BaiduPanError.notConfigured }
        let code = Self.cleanCode(raw)
        guard !code.isEmpty else {
            throw BaiduPanError.badResponse("授权码是空的")
        }

        var components = URLComponents(string: tokenEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "client_secret", value: secretKey),
            URLQueryItem(name: "redirect_uri", value: redirect)
        ]
        guard let url = components?.url else {
            throw BaiduPanError.badResponse("授权地址拼不出来")
        }
        Self.adopt(try await send(url, method: "GET"))

        // adopt 失败时不抛异常（它只记原文），所以这里要把原因捞出来抛给界面，
        // 否则用户点了授权、什么都没发生，也不知道为什么。
        let reason = AppSettings.shared.baiduPanLastError
        if !reason.isEmpty {
            throw BaiduPanError.badResponse(reason)
        }
        guard isAuthorized else {
            throw BaiduPanError.badResponse("百度没有返回通行证，再试一次")
        }
    }

    /// 把用户粘进来的东西洗成纯 code。
    ///
    /// 用户可能粘的是整条回调 URL（`http://192.168.1.5/cb?code=abc&state=`），
    /// 也可能只粘了 `code=abc`，还可能后面带着多余字符 —— 全都得认。
    static func cleanCode(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "code=") {
            text = String(text[range.upperBound...])
        }
        if let end = text.firstIndex(where: { $0 == "&" || $0 == "#" || $0 == " " || $0 == "\n" }) {
            text = String(text[..<end])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func adopt(_ json: [String: Any]) {
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            AppSettings.shared.baiduPanLastError =
                (json["error_description"] as? String) ?? (json["error"] as? String) ?? "没拿到 token"
            return
        }
        AppSettings.shared.baiduPanToken = token
        if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
            AppSettings.shared.baiduPanRefreshToken = refresh
        }
        let expires = (json["expires_in"] as? Double) ?? 2_592_000
        AppSettings.shared.baiduPanExpiresAt = Date().timeIntervalSince1970 + expires - 3600
        AppSettings.shared.baiduPanLastError = ""
    }

    func signOut() {
        AppSettings.shared.baiduPanToken = ""
        AppSettings.shared.baiduPanRefreshToken = ""
        AppSettings.shared.baiduPanExpiresAt = 0
    }

    /// 到期就用 refresh_token 悄悄续一次，用户不用再授权。
    private func ensureFreshToken() async throws {
        guard isAuthorized else { throw BaiduPanError.notAuthorized }

        let stamp = AppSettings.shared.baiduPanExpiresAt
        guard stamp > 0, Date().timeIntervalSince1970 >= stamp else { return }

        let refresh = AppSettings.shared.baiduPanRefreshToken
        guard !refresh.isEmpty else {
            signOut()
            throw BaiduPanError.notAuthorized
        }

        var components = URLComponents(string: tokenEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "client_secret", value: secretKey)
        ]
        guard let url = components?.url else {
            throw BaiduPanError.badResponse("续期地址拼不出来")
        }
        Self.adopt(try await send(url, method: "GET"))
        guard isAuthorized else { throw BaiduPanError.notAuthorized }
    }

    // MARK: - 读

    /// 列目录。
    func list(_ dir: String = "/") async throws -> [PanFile] {
        try await ensureFreshToken()
        let json = try await pan("/file", [
            "method": "list",
            "dir": dir,
            "order": "name",
            "limit": "1000"
        ])
        let items = (json["list"] as? [[String: Any]]) ?? []
        return items.compactMap(Self.file(from:))
    }

    /// 拿下载直链。
    func downloadLink(fsID: Int64) async throws -> URL {
        try await ensureFreshToken()
        let json = try await pan("/multimedia", [
            "method": "filemetas",
            "fsids": "[\(fsID)]",
            "dlink": "1"
        ])
        guard let items = json["list"] as? [[String: Any]],
              let first = items.first,
              let text = first["dlink"] as? String else {
            throw BaiduPanError.badResponse("没拿到下载链接")
        }
        // 直链本身还要再挂上 access_token，不带就是 403
        let token = AppSettings.shared.baiduPanToken
        let joined = text.contains("?")
            ? "\(text)&access_token=\(token)"
            : "\(text)?access_token=\(token)"
        guard let url = URL(string: joined) else {
            throw BaiduPanError.badResponse("下载链接不合法")
        }
        return url
    }

    /// 按下整个文件。
    func download(fsID: Int64) async throws -> Data {
        let url = try await downloadLink(fsID: fsID)
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue(panUA, forHTTPHeaderField: "User-Agent")
        return try await raw(request)
    }

    /// 按路径找一个文件。
    ///
    /// 网盘的接口**全都按 fs_id 走**，没有"给个路径直接拿"的口子，
    /// 所以只能列父目录再按名字匹配一下。慢一点，但省得调用方到处拼 id。
    func find(path: String) async throws -> PanFile? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard let slash = full.lastIndex(of: "/") else { return nil }

        let parent = slash == full.startIndex ? "/" : String(full[..<slash])
        let name = String(full[full.index(after: slash)...])
        guard !name.isEmpty else { return nil }

        return try await list(parent).first { $0.name == name }
    }

    // MARK: - 写

    /// 建目录（已经存在不算错）。
    func makeDirectory(_ path: String) async throws {
        try await ensureFreshToken()
        // 已存在时百度会返回 -8 之类，这里不当事
        _ = try? await pan("/file", [
            "method": "create",
            "path": path,
            "isdir": "1",
            "size": "0"
        ], method: "POST")
    }

    /// 保证备份目录在，顺手返回它的路径。
    @discardableResult
    func ensureBackupDir() async throws -> String {
        let files = (try? await list("/")) ?? []
        if !files.contains(where: { $0.name == "Aevis备份" && $0.isDirectory }) {
            try await makeDirectory(Self.backupDir)
        }
        return Self.backupDir
    }

    /// 上传一个文件。
    ///
    /// 百度不支持一把梭：必须
    /// **预创建**（precreate，先把每一片的 MD5 报上去，它好判断哪些片已经有了）
    /// → **逐片上传**（superfile2）
    /// → **收尾**（create）。
    func upload(_ data: Data, to remotePath: String) async throws {
        try await ensureFreshToken()

        let blocks = Self.blockMD5(data)
        let pre = try await pan("/file", [
            "method": "precreate",
            "path": remotePath,
            "size": "\(data.count)",
            "isdir": "0",
            "autoinit": "1",
            "block_list": Self.jsonArray(blocks)
        ], method: "POST")

        guard let uploadID = pre["uploadid"] as? String, !uploadID.isEmpty else {
            throw BaiduPanError.badResponse("预创建失败，没拿到 uploadid")
        }
        // 服务端可能回一句「这几片我这儿有」，那就只传它要的
        let required = Set((pre["block_list"] as? [Int]) ?? Array(blocks.indices))

        for index in blocks.indices where required.contains(index) {
            let start = index * Self.chunkSize
            let end = min(start + Self.chunkSize, data.count)
            try await uploadChunk(
                data.subdata(in: start..<end),
                path: remotePath,
                uploadID: uploadID,
                sequence: index
            )
        }

        _ = try await pan("/file", [
            "method": "create",
            "path": remotePath,
            "size": "\(data.count)",
            "isdir": "0",
            "uploadid": uploadID,
            "block_list": Self.jsonArray(blocks)
        ], method: "POST")
    }

    private func uploadChunk(_ slice: Data, path: String, uploadID: String, sequence: Int) async throws {
        var components = URLComponents(string: uploadBase + "/rest/2.0/pcs/superfile2")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "upload"),
            URLQueryItem(name: "access_token", value: AppSettings.shared.baiduPanToken),
            URLQueryItem(name: "type", value: "tmpfile"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "uploadid", value: uploadID),
            URLQueryItem(name: "partseq", value: "\(sequence)")
        ]
        guard let url = components?.url else {
            throw BaiduPanError.badResponse("分片地址拼不出来")
        }

        let boundary = "aevis-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"chunk\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(slice)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(panUA, forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        _ = try await send(request)
    }

    // MARK: - 底层

    /// 网盘接口：自动带上 access_token，并检查 errno。
    private func pan(_ path: String, _ query: [String: String], method: String = "GET") async throws -> [String: Any] {
        var items = query
        items["access_token"] = AppSettings.shared.baiduPanToken

        var components = URLComponents(string: panBase + path)
        components?.queryItems = items
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw BaiduPanError.badResponse("地址拼不出来：\(path)")
        }

        let json = try await send(url, method: method)
        if let errno = json["errno"] as? Int, errno != 0 {
            throw BaiduPanError.api(errno: errno)
        }
        return json
    }

    private func send(_ url: URL, method: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await raw(request)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BaiduPanError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return json
    }

    /// 最后一道：**所有请求都从这里出，UA 就统一在这儿设**。
    /// 散在各处设 UA 迟早会漏掉一处，而漏掉的那一处只会回一个没头没脑的 403。
    private func raw(_ request: URLRequest) async throws -> Data {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(panUA, forHTTPHeaderField: "User-Agent")
        }
        if request.timeoutInterval <= 0 {
            request.timeoutInterval = 30
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BaiduPanError.badResponse("连不上百度网盘：\(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw BaiduPanError.http(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }

    // MARK: - 零件

    private static func file(from item: [String: Any]) -> PanFile? {
        guard let id = int64(item["fs_id"]),
              let name = item["server_filename"] as? String,
              let path = item["path"] as? String else { return nil }
        return PanFile(
            id: id,
            name: name,
            path: path,
            isDirectory: (item["isdir"] as? Int) == 1,
            size: int64(item["size"]) ?? 0,
            modifiedAt: int64(item["server_mtime"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? Double { return Int64(number) }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// 每片的 MD5。百度要求先报这个，它好判断哪些片已经有了、不用重传。
    private static func blockMD5(_ data: Data) -> [String] {
        var out: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            out.append(md5(data.subdata(in: offset..<end)))
            offset = end
        }
        if out.isEmpty { out.append(md5(Data())) }
        return out
    }

    private static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
