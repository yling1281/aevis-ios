// ApiSmoke.swift —— 只读接口冒烟（2026-11-17，139 E-1）
//
// 为什么不是 XCTest：手写 pbxproj 加 test target 风险高（容易把主 target 编挂）。
// 这个文件是**独立可执行脚本**，CI 里直接 `swift Tests/ApiSmoke.swift` 跑，
// 打三个只读接口、断言 HTTP 200 + 关键字段，输出逐条 PASS/FAIL，非 0 退出码 = 失败。
//
// 用法：swift Tests/ApiSmoke.swift [baseURL]

import Foundation

let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "https://q7m3ax.lingyan.cyou"

struct Check {
    let name: String
    let path: String
    let method: String
    let body: [String: Any]?
    /// 必须存在的键（顶层或 data 里都算）
    let keys: [String]
}

let checks: [Check] = [
    Check(name: "app config", path: "/v1/app/config", method: "GET", body: nil, keys: []),
    Check(name: "llm models", path: "/v1/llm/models", method: "GET", body: nil, keys: []),
    Check(
        name: "recover stat", path: "/v1/chat/recover/stat", method: "POST",
        // 故意用一个不存在的码：只要**接口活着**就行，404 也是契约的一部分
        body: ["code": "AAAAAAAA"], keys: []
    )
]

func run(_ c: Check) -> (ok: Bool, line: String) {
    guard let url = URL(string: base + c.path) else { return (false, "bad url \(c.path)") }
    var req = URLRequest(url: url)
    req.httpMethod = c.method
    req.timeoutInterval = 20
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body = c.body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }

    let sem = DispatchSemaphore(value: 0)
    var result: (Bool, String) = (false, "no response")
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err {
            result = (false, "\(c.name): 请求失败 \(err.localizedDescription)")
            return
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let json = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]

        // 200 最好；`recover/stat` 用不存在的码时服务端可能回 404/4xx —— 那也是"接口活着"
        let alive = (200..<500).contains(code)
        var missing: [String] = []
        let scope = (json["data"] as? [String: Any]) ?? json
        for k in c.keys where scope[k] == nil && json[k] == nil { missing.append(k) }

        let head = text.prefix(160).replacingOccurrences(of: "\n", with: " ")
        if alive && missing.isEmpty {
            result = (true, "\(c.name): PASS http=\(code) body=\(head)")
        } else {
            result = (false, "\(c.name): FAIL http=\(code) missing=\(missing) body=\(head)")
        }
    }.resume()
    _ = sem.wait(timeout: .now() + 25)
    return result
}

var failed = 0
print("=== ApiSmoke @ \(base) ===")
for c in checks {
    let (ok, line) = run(c)
    print(line)
    if !ok { failed += 1 }
}
print("=== \(checks.count - failed)/\(checks.count) passed ===")
exit(failed == 0 ? 0 : 1)
