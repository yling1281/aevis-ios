import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

/// 给她的两只手：翻网盘、读网盘里的文件。
///
/// 为什么要做成工具，而不是界面上摆个按钮：
/// 用户问「网盘里那篇小说讲什么」，她得**自己去翻**才算数 ——
/// 否则只是用户把内容贴进来，那她并没有"读"到任何东西。
///
/// 没授权的时候这两个工具会返回一句明确的指引（而不是干巴巴报错），
/// 她可以照原话讲给用户听。
extension DeviceTools {

    static var panTools: [DeviceTool] {
        [listPanTool, readPanTool]
    }

    private static var listPanTool: DeviceTool {
        DeviceTool(
            name: "list_pan_files",
            title: "翻了翻你的网盘",
            description: """
            列出百度网盘某个目录下的文件和文件夹（名字、大小、改动时间）。
            用户问「网盘里有什么」「帮我找找某个文件」时用它。
            dir 默认是根目录，写法像 /小说 这样。
            需要用户先在「设置 → 百度网盘」里授权；没授权会返回一句提示。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "dir": ["type": "string", "description": "目录路径，默认 /"]
                ],
                "required": []
            ]
        ) { args in
            guard BaiduPanClient.shared.isAuthorized else {
                return "还没授权百度网盘，我翻不了。让用户去「设置 → 百度网盘」点「去授权」。"
            }
            let dir = (args["dir"] as? String) ?? "/"
            do {
                let files = try await BaiduPanClient.shared.list(dir)
                guard !files.isEmpty else { return "\(dir) 是空的。" }
                let lines = files.prefix(60).map { file -> String in
                    file.isDirectory ? "（文件夹）\(file.name)/" : "\(file.name)　\(file.sizeText)"
                }
                return "\(dir) 里一共 \(files.count) 项：\n" + lines.joined(separator: "\n")
            } catch {
                return "翻不了：\(error.localizedDescription)"
            }
        }
    }

    private static var readPanTool: DeviceTool {
        DeviceTool(
            name: "read_pan_file",
            title: "读了网盘里的文件",
            description: """
            读百度网盘里某个文件的内容：文本类（txt / md / json / csv / 代码）和 PDF。
            用户让你看网盘里的某个文件、或者问某个文件讲了什么时用它。
            要完整路径，比如 /小说/第一章.txt；不知道路径就先用 list_pan_files 翻一遍。
            一次最多取两万字，太长的只给开头。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "文件的完整路径"]
                ],
                "required": ["path"]
            ]
        ) { args in
            guard BaiduPanClient.shared.isAuthorized else {
                return "还没授权百度网盘，我读不了。让用户去「设置 → 百度网盘」点「去授权」。"
            }
            guard let path = args["path"] as? String, !path.isEmpty else {
                return "没给文件路径。"
            }
            do {
                guard let file = try await BaiduPanClient.shared.find(path: path) else {
                    return "网盘里没有 \(path) 这个文件。"
                }
                guard !file.isDirectory else {
                    return "\(path) 是个文件夹。用 list_pan_files 看看里面有什么。"
                }
                // 太大的先拦一道：十几 MB 的东西拉下来多半也不是文字，白费流量
                guard file.size <= 12 * 1024 * 1024 else {
                    return "\(path) 有 \(file.sizeText)，太大了，我不拉了。"
                }
                let data = try await BaiduPanClient.shared.download(fsID: file.id)
                let text = Self.extractText(from: data, name: file.name)
                guard !text.isEmpty else {
                    return "\(file.name) 里我读不出文字（可能是扫描件、图片，或者二进制文件）。"
                }
                return "\(file.name) 的内容：\n" + text
            } catch {
                return "读不了：\(error.localizedDescription)"
            }
        }
    }

    /// 从一段数据里抠出文字。
    ///
    /// PDF 走系统 PDFKit；其余按文本解码 —— 而且**中文要按 GB18030 兜一道**：
    /// 网盘里那些老 txt 十有八九是 GBK 存的，只试 UTF-8 会读出一堆乱码。
    static func extractText(from data: Data, name: String) -> String {
        let lowered = name.lowercased()

        #if canImport(PDFKit)
        if lowered.hasSuffix(".pdf"), let document = PDFDocument(data: data) {
            var out = ""
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let pageText = page.string else { continue }
                out += pageText + "\n"
                if out.count >= 20_000 { break }
            }
            let cleaned = condenseText(out)
            if !cleaned.isEmpty { return cap(cleaned) }
        }
        #endif

        if let text = String(data: data, encoding: .utf8) {
            let cleaned = condenseText(text)
            if !cleaned.isEmpty { return cap(cleaned) }
        }

        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gb18030) {
            return cap(condenseText(text))
        }
        return ""
    }

    /// 去掉空行、压掉行首空白 —— 原始文本塞进上下文很浪费。
    private static func condenseText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func cap(_ text: String) -> String {
        guard text.count > 20_000 else { return text }
        return String(text.prefix(20_000)) + "\n（后面还有，先给这么多）"
    }
}
