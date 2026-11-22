import Foundation

/// 用户协议和隐私政策的内容存储 —— 本地硬缓存 + 云端热更新。
///
/// ## 设计要点
/// - **本地硬缓存**：Documents/agreements/<name>.html，冷启动立刻能读
/// - **云端版本检查**：启动时请求 `/v1/app/agreements?name=<name>` 获取版本号
/// - **增量更新**：云端版本更高时才下载新内容，否则用本地缓存
/// - **降级兜底**：更新失败（网络/解析）保留旧缓存，绝不空白
///
/// ## 内容来源
/// - 硬编码兜底：Bundle 里打包一份 fallback HTML（app 发布时内置）
/// - 云端热更新：`https://aevis.cn/terms.html` 和 `https://aevis.cn/privacy.html`
///   （或走后端 API `/v1/app/agreements` 返回版本号和内容）
///
/// ## 版本号格式
/// 云端返回 `version: "2026-11-25"` 这种日期字符串，本地存 `version_<name>` 键对比。
/// 版本号更高（字符串比较）就更新，否则用缓存。
final class AgreementContentStore: ObservableObject {
    static let shared = AgreementContentStore()

    /// 协议类型
    enum Name: String, CaseIterable {
        case terms = "terms"
        case privacy = "privacy"
        
        /// 显示名称
        var displayName: String {
            switch self {
            case .terms: return "用户协议"
            case .privacy: return "隐私政策"
            }
        }
        
        /// 云端 URL
        var remoteURL: URL {
            switch self {
            case .terms: return URL(string: "https://aevis.cn/terms.html")!
            case .privacy: return URL(string: "https://aevis.cn/privacy.html")!
            }
        }
        
        /// Bundle 内置文件名
        var bundleResource: String {
            switch self {
            case .terms: return "terms-fallback"
            case .privacy: return "privacy-fallback"
            }
        }
    }
    
    // MARK: - 状态
    
    /// 各协议的当前内容（HTML 字符串）
    @Published private(set) var contents: [Name: String] = [:]
    
    /// 各协议的当前版本（日期字符串）
    @Published private(set) var versions: [Name: String] = [:]
    
    /// 是否正在加载
    @Published private(set) var isLoading = false
    
    /// 加载错误信息（用于调试）
    @Published private(set) var lastError: String?
    
    // MARK: - 存储路径
    
    private let cacheDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("agreements", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()
    
    private func cacheFileURL(_ name: Name) -> URL {
        cacheDirectory.appendingPathComponent("\(name.rawValue).html")
    }
    
    private func versionKey(_ name: Name) -> String {
        "aevis.agreement.version.\(name.rawValue)"
    }
    
    // MARK: - 初始化
    
    private init() {
        // 先读本地缓存（同步，立刻能显示）
        for name in Name.allCases {
            loadFromCache(name)
        }
    }
    
    // MARK: - 读取
    
    /// 获取协议内容（优先返回缓存，无缓存返回空字符串）
    func content(_ name: Name) -> String {
        contents[name] ?? ""
    }
    
    /// 获取协议版本号
    func version(_ name: Name) -> String {
        versions[name] ?? ""
    }
    
    // MARK: - 本地缓存
    
    /// 从磁盘缓存加载（同步）
    private func loadFromCache(_ name: Name) {
        let fileURL = cacheFileURL(name)
        
        // 1. 尝试读取磁盘缓存
        if let data = try? Data(contentsOf: fileURL),
           let html = String(data: data, encoding: .utf8), !html.isEmpty {
            contents[name] = html
            // 读取版本号
            versions[name] = UserDefaults.standard.string(forKey: versionKey(name)) ?? ""
            return
        }
        
        // 2. 无磁盘缓存，用 Bundle 内置兜底
        if let url = Bundle.main.url(forResource: name.bundleResource, withExtension: "html"),
           let data = try? Data(contentsOf: url),
           let html = String(data: data, encoding: .utf8) {
            contents[name] = html
            // 内置版本号
            versions[name] = "builtin"
            return
        }
        
        // 3. 连内置都没有，返回空（后续云端更新会填上）
        contents[name] = ""
        versions[name] = ""
    }
    
    /// 保存到磁盘缓存
    private func saveToCache(_ name: Name, content: String, version: String) {
        let fileURL = cacheFileURL(name)
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(version, forKey: versionKey(name))
            contents[name] = content
            versions[name] = version
        } catch {
            NSLog("AgreementContentStore: 保存缓存失败 \(name.rawValue): \(error)")
        }
    }
    
    // MARK: - 云端更新
    
    /// 检查并更新所有协议（启动时调用）
    @MainActor
    func checkAndUpdateAll() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        
        defer { isLoading = false }
        
        for name in Name.allCases {
            await checkAndUpdate(name)
        }
    }
    
    /// 检查并更新单个协议
    @MainActor
    private func checkAndUpdate(_ name: Name) async {
        // 1. 尝试从云端获取版本号（通过 HEAD 请求检查 Last-Modified）
        // 如果云端版本更高，才下载内容
        
        // 简化方案：直接请求内容，用 ETag / Last-Modified 做版本号
        var request = URLRequest(url: name.remoteURL)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        
        // 如果有本地版本，带上 If-Modified-Since（让服务器返回 304）
        let localVersion = versions[name] ?? ""
        if !localVersion.isEmpty && localVersion != "builtin" {
            // 假设版本号是日期字符串，转成 HTTP 日期格式
            request.setValue(localVersion, forHTTPHeaderField: "If-Modified-Since")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "AgreementContentStore", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "无效响应"])
            }
            
            // 304 Not Modified：云端没变，用本地缓存
            if httpResponse.statusCode == 304 {
                NSLog("AgreementContentStore: \(name.rawValue) 未更新（304）")
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                throw NSError(domain: "AgreementContentStore", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
            }
            
            // 解析内容
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                throw NSError(domain: "AgreementContentStore", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "内容为空"])
            }
            
            // 用 Last-Modified 或当前日期作为版本号
            let serverVersion = httpResponse.value(forHTTPHeaderField: "Last-Modified")
                ?? ISO8601DateFormatter().string(from: Date())
            
            // 保存到缓存
            saveToCache(name, content: html, version: serverVersion)
            NSLog("AgreementContentStore: \(name.rawValue) 已更新至 \(serverVersion)")
            
        } catch {
            // 更新失败，保留本地缓存，不上报错（让用户正常看旧版本）
            NSLog("AgreementContentStore: 更新 \(name.rawValue) 失败: \(error)")
            // 如果本地无缓存，记录错误（调试用）
            if contents[name]?.isEmpty ?? true {
                lastError = "加载 \(name.displayName) 失败: \(error.localizedDescription)"
            }
        }
    }
    
    /// 强制刷新单个协议（用户手动下拉刷新时调用）
    @MainActor
    func refresh(_ name: Name) async {
        await checkAndUpdate(name)
    }
}
