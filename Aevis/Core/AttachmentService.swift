import Foundation

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
    /// 只处理纯文本类的；PDF/Word 这类要额外解析库，先如实说读不了。
    static func readTextFile(at url: URL) -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let supported = ["txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "yml", "yaml", "swift", "js", "py", "html", "htm"]
        let ext = url.pathExtension.lowercased()
        guard supported.contains(ext) else {
            return nil
        }

        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // 有些中文文本是 GB18030，再试一次
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: String.Encoding(rawValue: gb)) {
            return text
        }
        return nil
    }

    /// 能被读取的文件类型（给 fileImporter 用）。
    static var allowedFileTypes: [String] {
        ["txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "yml", "yaml", "swift", "js", "py", "html", "htm", "pdf"]
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
