import Foundation

/// 一条命令的执行结果。
struct CommandResult {
    var output: String
    var exitCode: Int

    static func ok(_ text: String) -> CommandResult {
        CommandResult(output: text, exitCode: 0)
    }

    static func fail(_ text: String) -> CommandResult {
        CommandResult(output: text, exitCode: 1)
    }
}

/// 执行层的接口。
///
/// **为什么要有这层抽象**：真 Alpine（iSH）那套是周级工作量，得把整个 C 代码搬进来编译，
/// 而它一旦接上，命令台的界面、她调用命令的方式都不该跟着改。
/// 所以界面和工具只依赖这个协议 —— 以后把 AlpineShell 挂上来就行。
protocol ShellProvider {
    /// 给人看的名字，显示在命令台里。
    var displayName: String { get }
    /// 一句话说明它现在能不能用。
    var availability: String { get }
    var isAvailable: Bool { get }

    /// 执行一条命令。
    func run(_ command: String) async -> CommandResult
    /// 当前工作目录（用于提示符）。
    var workingDirectory: String { get }
}

/// 内置解释器：不是真 Linux，但是**能跑**的。
///
/// 所有文件操作都被关在 App 自己的一个工作目录里，`..` 之类逃不出去 ——
/// 这一点是硬要求，不能因为"是 AI 在跑"就放松。
final class BuiltinShell: ShellProvider {

    static let shared = BuiltinShell()

    let displayName = "内置命令台"
    var availability: String { "可用。不是真 Linux —— 支持文件、文本、网络这些常用命令。" }
    var isAvailable: Bool { true }

    private(set) var currentPath = "/"
    private let root: URL

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = support.appendingPathComponent("AevisWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var workingDirectory: String { currentPath }

    // MARK: - 执行

    func run(_ command: String) async -> CommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ok("") }

        let parts = tokenize(trimmed)
        guard let name = parts.first else { return .ok("") }
        let arguments = Array(parts.dropFirst())

        switch name {
        case "help", "?":
            return .ok(Self.helpText)
        case "pwd":
            return .ok(currentPath)
        case "cd":
            return changeDirectory(arguments.first)
        case "ls":
            return list(arguments.first)
        case "cat":
            return readFiles(arguments)
        case "mkdir":
            return makeDirectory(arguments.first)
        case "rm":
            return remove(arguments)
        case "mv":
            return move(arguments, copy: false)
        case "cp":
            return move(arguments, copy: true)
        case "echo":
            return .ok(arguments.joined(separator: " "))
        case "wc":
            return countLines(arguments)
        case "head", "tail":
            return headOrTail(arguments, fromHead: name == "head")
        case "grep":
            return grep(arguments)
        case "date":
            return .ok(Self.dateString())
        case "whoami":
            return .ok("aevis")
        case "uname":
            return .ok("Aevis 内置命令台（不是真 Linux）")
        case "env":
            return .ok("AEVIS_SHELL=builtin\nWORKSPACE=\(currentPath)\nLANG=zh_CN.UTF-8")
        case "curl":
            return await curl(arguments)
        case "clear":
            return .ok("__CLEAR__")
        default:
            return .fail("没有这个命令：\(name)\n输 help 看有哪些。")
        }
    }

    // MARK: - 文件

    private func changeDirectory(_ path: String?) -> CommandResult {
        let target = path ?? "/"
        guard let url = resolve(target) else {
            return .fail("路径越界了：\(target)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .fail("没有这个目录：\(target)")
        }
        currentPath = displayPath(url)
        return .ok("")
    }

    private func list(_ path: String?) -> CommandResult {
        guard let url = resolve(path ?? ".") else { return .fail("路径越界了。") }
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            guard !items.isEmpty else { return .ok("（空）") }
            let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item -> String in
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    return "  " + item.lastPathComponent + "/"
                }
                let size = values?.fileSize ?? 0
                return String(format: "%8d  %@", size, item.lastPathComponent)
            }
            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .fail("读目录失败：\(error.localizedDescription)")
        }
    }

    private func readFiles(_ paths: [String]) -> CommandResult {
        guard !paths.isEmpty else { return .fail("cat 要给文件名。") }
        var chunks: [String] = []
        for path in paths {
            guard let url = resolve(path) else { return .fail("路径越界了：\(path)") }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return .fail("读不了：\(path)")
            }
            chunks.append(text)
        }
        return .ok(chunks.joined(separator: "\n"))
    }

    private func makeDirectory(_ path: String?) -> CommandResult {
        guard let path else { return .fail("mkdir 要给目录名。") }
        guard let url = resolve(path) else { return .fail("路径越界了：\(path)") }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return .ok("已创建 \(path)")
        } catch {
            return .fail("创建失败：\(error.localizedDescription)")
        }
    }

    private func remove(_ arguments: [String]) -> CommandResult {
        let paths = arguments.filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else { return .fail("rm 要给文件名。") }
        guard paths != ["/"] else { return .fail("不能删根目录。") }

        var removed = 0
        for path in paths {
            guard let url = resolve(path) else { return .fail("路径越界了：\(path)") }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return .ok("删掉了 \(removed) 项")
    }

    private func move(_ arguments: [String], copy: Bool) -> CommandResult {
        let paths = arguments.filter { !$0.hasPrefix("-") }
        guard paths.count == 2 else {
            return .fail("\(copy ? "cp" : "mv") 需要「源 目标」两个参数。")
        }
        guard let from = resolve(paths[0]) else { return .fail("路径越界了：\(paths[0])") }
        guard var to = resolve(paths[1]) else { return .fail("路径越界了：\(paths[1])") }

        // 目标是已有目录时，放到它里面
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: to.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            to = to.appendingPathComponent(from.lastPathComponent)
        }

        do {
            if FileManager.default.fileExists(atPath: to.path) {
                try FileManager.default.removeItem(at: to)
            }
            if copy {
                try FileManager.default.copyItem(at: from, to: to)
            } else {
                try FileManager.default.moveItem(at: from, to: to)
            }
            return .ok("\(copy ? "复制" : "移动")好了：\(paths[0]) → \(paths[1])")
        } catch {
            return .fail("失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 文本

    private func countLines(_ paths: [String]) -> CommandResult {
        guard let path = paths.first else { return .fail("wc 要给文件名。") }
        guard let url = resolve(path) else { return .fail("路径越界了。") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .fail("读不了：\(path)")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return .ok(String(format: "%8d %8d %8d %@", lines, text.split(separator: " ").count, text.count, path))
    }

    private func headOrTail(_ arguments: [String], fromHead: Bool) -> CommandResult {
        var limit = 10
        var path: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-n", index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
                limit = max(1, value)
                index += 2
                continue
            }
            path = argument
            index += 1
        }
        guard let path else { return .fail("要给文件名。") }
        guard let url = resolve(path) else { return .fail("路径越界了。") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .fail("读不了：\(path)")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let slice = fromHead ? lines.prefix(limit) : lines.suffix(limit)
        return .ok(slice.joined(separator: "\n"))
    }

    private func grep(_ arguments: [String]) -> CommandResult {
        let plain = arguments.filter { !$0.hasPrefix("-") }
        guard plain.count >= 1 else { return .fail("grep 要给关键词，可以再给文件名。") }
        let keyword = plain[0]

        if plain.count >= 2 {
            guard let url = resolve(plain[1]) else { return .fail("路径越界了。") }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return .fail("读不了：\(plain[1])")
            }
            let hits = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.localizedCaseInsensitiveContains(keyword) }
            return .ok(hits.isEmpty ? "没找到。" : hits.joined(separator: "\n"))
        }

        // 没给文件就递归搜工作目录
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return .ok("没找到。")
        }
        var hits: [String] = []
        for case let item as URL in enumerator {
            guard hits.count < 60 else { break }
            guard let text = try? String(contentsOf: item, encoding: .utf8) else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.localizedCaseInsensitiveContains(keyword) {
                hits.append("\(displayPath(item)):\(number + 1): \(line)")
                if hits.count >= 60 { break }
            }
        }
        return .ok(hits.isEmpty ? "没找到。" : hits.joined(separator: "\n"))
    }

    // MARK: - 网络

    private func curl(_ arguments: [String]) async -> CommandResult {
        guard let raw = arguments.last, raw.lowercased().hasPrefix("http") else {
            return .fail("curl 要给一个 http/https 地址。")
        }
        guard let url = URL(string: raw) else { return .fail("地址看不懂。") }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue("Aevis/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return .ok("HTTP \(code)，\(data.count) 字节\n\n" + String(text.prefix(4000)))
        } catch {
            return .fail("请求失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 路径与分词

    /// 把用户给的路径变成真实 URL，并且**强制留在工作目录里**。
    private func resolve(_ path: String) -> URL? {
        var target = path.trimmingCharacters(in: .whitespaces)
        if target.isEmpty || target == "." { target = "." }
        if target == "~" { target = "/" }

        let candidate: URL
        if target.hasPrefix("/") {
            candidate = root.appendingPathComponent(String(target.dropFirst()))
        } else {
            let base = root.appendingPathComponent(String(currentPath.dropFirst()))
            candidate = base.appendingPathComponent(target)
        }

        let normalized = candidate.standardizedFileURL
        let guardRoot = root.standardizedFileURL
        guard normalized.path == guardRoot.path || normalized.path.hasPrefix(guardRoot.path + "/") else {
            return nil
        }
        return normalized
    }

    private func displayPath(_ url: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return "/" }
        let rest = String(full.dropFirst(base.count))
        return rest.isEmpty ? "/" : rest
    }

    /// 支持双引号与单引号，简单够用。
    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for character in input {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func dateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
        return formatter.string(from: Date())
    }

    static let helpText = """
    可用命令：
      help              看这份说明
      pwd / cd / ls     看当前位置、切换目录、列目录
      cat / head / tail 看文件内容
      mkdir / rm / mv / cp   建目录、删、移动、复制
      echo              输出一段文字
      wc / grep         数行数、搜内容（grep 不给文件名会递归搜整个工作目录）
      curl <网址>        抓一个网页
      date / whoami / uname / env
      clear             清屏

    文件都在 App 自己的工作目录里，出不去 —— 这不是限制你，是防止误删手机上的东西。
    """
}

/// 真 Alpine（iSH）的占位实现。
///
/// 接上它需要把 iSH 的 C 代码与 Alpine rootfs 一起编进 App（周级工作量），
/// 而且必须在真机上验证。在那之前它老老实实说自己不可用，
/// **不假装能用** —— 界面上会显示成「未接入」。
final class AlpineShell: ShellProvider {
    static let shared = AlpineShell()

    let displayName = "Alpine Linux"
    var availability: String { "未接入。接上它需要把 Alpine 的 rootfs 编进 App，属于后续阶段。" }
    var isAvailable: Bool { false }
    var workingDirectory: String { "/" }

    func run(_ command: String) async -> CommandResult {
        .fail("Alpine 沙箱还没接上。现在用的是内置命令台，功能少一些但能用。")
    }
}

/// 执行层的入口：优先用可用的那个。
enum Shell {
    static var provider: ShellProvider {
        AlpineShell.shared.isAvailable ? AlpineShell.shared : BuiltinShell.shared
    }

    static func run(_ command: String) async -> CommandResult {
        await provider.run(command)
    }
}

// MARK: - 让她也能用命令台

extension DeviceTools {

    /// 命令台对她来说就是「一只手」：需要读写文件、批量处理文本、抓页面原文时用。
    static var shellTool: DeviceTool {
        DeviceTool(
            name: "run_command",
            title: "在命令台里跑了一条命令",
            description: """
            在手机内的工作目录里执行一条命令。支持：
            ls / cat / echo / grep / head / tail / wc / mkdir / rm / mv / cp / curl / date / pwd / cd。
            用户要你整理文件、批量处理文本、读写某个文件、抓网页原文时用它。
            注意：只能操作工作目录里的文件，**碰不到手机上的其它东西**。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "要执行的命令，例如 ls 或 cat 笔记.txt"]
                ],
                "required": ["command"]
            ]
        ) { args in
            guard let command = args["command"] as? String,
                  !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "没给命令。"
            }
            let result = await Shell.run(command)
            if result.output == "__CLEAR__" {
                return "（清屏了，没有其它输出）"
            }
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return result.exitCode == 0 ? "执行完成，没有输出。" : "执行失败。"
            }
            return trimmed
        }
    }
}
