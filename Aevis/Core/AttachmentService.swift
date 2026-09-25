import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(Vision)
import Vision
#endif

#if canImport(UIKit)
import UIKit
#endif

/// 附件：拍照 / 选图 / 选文件 → 取出文字 → 塞进输入框。
///
/// OCR 用系统的 **Vision**：离线、免费、不用额外接口，
/// 而且中文识别质量比大多数第三方 API 好。
/// 取出的文字会**直接放进输入框**，用户可以在后面接着写指令 ——
/// 这样她收到的是「图片里的文字 + 你要我干什么」，而不是一张她看不见的图。
enum AttachmentService {

    /// 单次附件的字数上限。太长会把上下文撑爆，而且模型也读不完。
    static let maxCharacters = 6000

    // MARK: - OCR

    /// 从图片里认文字。
    static func recognizeText(in image: UIImage) async -> String {
        #if canImport(Vision) && canImport(UIKit)
        // 太大的图先缩一下，识别更快也更准
        let scaled = downscale(image, maxSide: 2000)
        guard let cgImage = scaled.cgImage else { return "" }

        // 用 Task.detached 同步跑，不用 continuation ——
        // perform 抛异常时 completion 不会被调用，用 continuation 会永久挂住。
        return await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
        #else
        return ""
        #endif
    }

    // MARK: - 读文件

    /// 读一个文件里的文字。
    ///
    /// 支持三类：
    /// - **纯文本**（txt / md / csv / json / 代码…）→ 直接读，带 GB18030 兜底
    /// - **PDF** → 系统 PDFKit，本来就自带的
    /// - **Word（docx）和 RTF** → 系统的富文本解析（`NSAttributedString`）
    ///
    /// ⚠️ 早先这里只认纯文本，但 `allowedFileTypes` 里却写着 pdf ——
    /// 也就是**能给用户选、选了却读不出来**。这种「菜单里有、点了没反应」最坑。
    static func readTextFile(at url: URL) -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard allowedFileTypes.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        switch ext {
        case "pdf":
            return pdfText(data)
        case "docx":
            return docxText(data)
        case "rtf":
            return richText(data)
        case "doc":
            // 老的 .doc 是二进制格式，系统读不了 —— 不假装能读
            return nil
        default:
            return plainText(data)
        }
    }

    /// PDF 抽文字。PDFKit 是系统自带的，不用额外库。
    private static func pdfText(_ data: Data) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else { return nil }
        let text = document.string ?? ""
        return text.isEmpty ? nil : text
        #else
        return nil
        #endif
    }

    /// RTF 抽文字 —— 走系统自带的富文本解析。
    private static func richText(_ data: Data) -> String? {
        #if canImport(UIKit)
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
        #else
        return nil
        #endif
    }

    // MARK: - docx
    //
    // ⚠️ 为什么不能像 rtf 那样走系统解析：**`NSAttributedString.DocumentType.officeOpenXML`
    // 在 iOS 上根本不存在**（那是 macOS 才有的），写上去就是**编译错误**。
    // 这一条是 CI 报出来的（`AccountCard` 那个可选值 `.isEmpty` 是同一轮的另一处）。
    //
    // 所以 docx 只能自己拆。它本质是个 zip，正文在 `word/document.xml` 里。
    // 需要两样东西，都只用系统自带的：
    // 1. **读 zip 目录** —— 格式几十年没变，几十行就够（下面）
    // 2. **解开裸 DEFLATE** —— 用 Foundation 的 `decompressed(using: .zlib)`。
    //    Apple 文档里 `.zlib` 就是**裸 DEFLATE**（RFC 1951），正好对上 zip 里存的。

    /// 从 docx 里抽出可读文字。
    private static func docxText(_ data: Data) -> String? {
        guard let xml = zipEntry(named: "word/document.xml", in: data),
              let raw = String(data: xml, encoding: .utf8) else { return nil }
        let text = stripXML(raw)
        return text.isEmpty ? nil : text
    }

    /// 从 zip 里取出一个成员。
    ///
    /// 只支持「不压缩（0）」和「deflate（8）」两种方式 —— docx 用的就是这两种。
    /// 加密的 zip 直接放弃（返回 nil），不假装能读。
    private static func zipEntry(named name: String, in archive: Data) -> Data? {
        // 1) 先找「中央目录结尾记录」（EOCD）。它一定在文件最后，
        //    后面最多跟 65535 字节的注释，所以从尾巴往前扫一段就够了。
        guard let eocd = lastIndex(of: 0x06054b50, in: archive, window: 66_000),
              let count = u16(archive, eocd + 10),
              let directoryOffset = u32(archive, eocd + 16),
              count > 0, count < 10_000 else { return nil }

        // 2) 顺着中央目录逐个比对名字
        var cursor = directoryOffset
        for _ in 0..<count {
            guard u32(archive, cursor) == 0x02014b50,
                  let method = u16(archive, cursor + 10),
                  let compressedSize = u32(archive, cursor + 20),
                  let nameLength = u16(archive, cursor + 28),
                  let extraLength = u16(archive, cursor + 30),
                  let commentLength = u16(archive, cursor + 32),
                  let localOffset = u32(archive, cursor + 42) else { return nil }

            let nameStart = cursor + 46
            guard nameStart + nameLength <= archive.count else { return nil }
            let entryName = String(
                decoding: archive[(archive.startIndex + nameStart)
                                  ..< (archive.startIndex + nameStart + nameLength)],
                as: UTF8.self
            )

            if entryName == name {
                // 3) ⚠️ 尺寸一律用**中央目录**里这份，不用本地头里的 ——
                //    本地头可能是 0（用了「数据描述符」的 zip 就是那样）。
                guard u32(archive, localOffset) == 0x04034b50,
                      let localNameLength = u16(archive, localOffset + 26),
                      let localExtraLength = u16(archive, localOffset + 28) else { return nil }

                let start = localOffset + 30 + localNameLength + localExtraLength
                guard compressedSize > 0, start + compressedSize <= archive.count else { return nil }
                let payload = archive.subdata(
                    in: (archive.startIndex + start)..<(archive.startIndex + start + compressedSize)
                )

                if method == 0 { return payload }
                guard method == 8 else { return nil }
                guard let inflated = try? (payload as NSData).decompressed(using: .zlib)
                else { return nil }
                return inflated as Data
            }

            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return nil
    }

    /// 从 XML 里把可读文字抠出来。
    ///
    /// 不做完整的 XML 解析 —— docx 的正文结构很固定：
    /// 段落是 `</w:p>`，文字在标签之间。所以「段落换行 + 其余标签丢掉 + 实体还原」就够读了。
    private static func stripXML(_ xml: String) -> String {
        var marked = xml
        for marker in ["</w:p>", "<w:br/>", "<w:br />", "</a:p>"] {
            marked = marked.replacingOccurrences(of: marker, with: "\n")
        }

        var text = ""
        var insideTag = false
        for character in marked {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; continue }
            if !insideTag { text.append(character) }
        }

        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'"
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return condenseLines(text)
    }

    private static func condenseLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - 直接读字节的小工具（都是**小端**）

    private static func u16(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let base = data.startIndex + offset
        return Int(data[base]) | (Int(data[base + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        var value = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | Int(data[base + index])
        }
        return value
    }

    /// 从尾巴往前找一个四字节魔数，最多回看 window 字节。
    private static func lastIndex(of magic: Int, in data: Data, window: Int) -> Int? {
        guard data.count >= 4 else { return nil }
        let lowest = max(0, data.count - window)
        var index = data.count - 4
        while index >= lowest {
            if u32(data, index) == magic { return index }
            index -= 1
        }
        return nil
    }

    /// 纯文本。UTF-8 读不出来就按 GB18030 再试一次 ——
    /// 中文 txt 十有八九是 GBK 存的，只按 UTF-8 读会整篇乱码。
    private static func plainText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }

    /// 能被读取的文件类型（给 fileImporter 用）。
    ///
    /// ⚠️ 这里加什么，`readTextFile` 就必须真能读 —— 两边必须同步，
    /// 否则就是「菜单里有、点了没反应」。
    static var allowedFileTypes: [String] {
        ["txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "yml", "yaml",
         "swift", "js", "py", "html", "htm", "pdf", "docx", "rtf"]
    }

    // MARK: - 组装

    /// 把附件内容包成一段可以直接放进输入框的文字。
    /// 刻意用显眼的分隔，让她一眼看出哪部分是"看到的东西"、哪部分是要做的事。
    static func composerBlock(_ text: String, source: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var body = trimmed
        var truncated = false
        if body.count > maxCharacters {
            body = String(body.prefix(maxCharacters))
            truncated = true
        }

        var block = "【\(source)里的内容】\n\(body)\n【内容结束】\n\n"
        if truncated {
            block += "（内容太长，只取了前 \(maxCharacters) 字）\n\n"
        }
        return block
    }

    // MARK: - 压缩

    /// 压成一张能存进聊天记录的 JPEG。
    ///
    /// 最长边 1280、质量 0.8：聊天里看得清，又不至于把消息存档撑大
    /// （消息是按 JSON 整个读写的，一条几 MB 的图会让每次落盘都变慢）。
    static func compressed(
        _ image: UIImage,
        maxSide: CGFloat = 1280,
        quality: CGFloat = 0.8
    ) -> Data? {
        #if canImport(UIKit)
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }

        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: quality)
        #else
        return nil
        #endif
    }

    // MARK: - 零件

    #if canImport(UIKit)
    /// 等比缩到最长边不超过 maxSide。
    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }

        let ratio = maxSide / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    #endif
}
