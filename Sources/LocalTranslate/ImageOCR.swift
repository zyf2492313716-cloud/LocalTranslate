import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// 图片文件 OCR：访达选图 / 拖进来的图片，都能直接识别。
///
/// 和截图 OCR 的区别只是图片来源——识别、二维码、分段都复用同一套 ScreenOCR。
enum ImageOCR {

    struct Failure: Error {
        var message: String
    }

    struct Outcome {
        var text: String
        var qrCodes: [String]

        /// 把二维码内容拼在识别文本后面，方便一眼看到
        var combined: String {
            guard !qrCodes.isEmpty else { return text }
            let payloads = qrCodes.map { "二维码：\($0)" }.joined(separator: "\n")
            return text.isEmpty ? payloads : text + "\n\n" + payloads
        }
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp", "pdf",
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func loadCGImage(_ url: URL) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        // PDF 之类走 NSImage 兜底
        guard let image = NSImage(contentsOf: url) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 识别一张图片文件。`engine` 与截图 OCR 共用配置。
    static func recognize(file url: URL,
                          engine: OcrEngine = OcrEngine(rawValue: Config.shared.ocrEngine) ?? .system,
                          detectQR: Bool? = nil) async -> Result<Outcome, Failure> {
        guard let image = loadCGImage(url) else {
            return .failure(Failure(message: "打不开这个图片：\(url.lastPathComponent)"))
        }
        let qrEnabled = detectQR ?? Config.shared.ocrQRCode

        var text = ""
        switch await ScreenOCR.recognize(image, engine: engine) {
        case .success(let recognized): text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure(let message):
            if !qrEnabled { return .failure(Failure(message: message)) }
        }

        var codes: [String] = []
        if qrEnabled { codes = await ScreenOCR.detectQRcodes(image) }

        if text.isEmpty && codes.isEmpty {
            return .failure(Failure(message: "这张图里没有认出文字，也没有二维码"))
        }
        return .success(Outcome(text: text, qrCodes: codes))
    }

    /// 访达里当前选中的文件（拿不到就返回空，调用方退回文件选择面板）
    static func finderSelection() -> [URL] {
        let script = """
        tell application "Finder"
            set theSelection to selection as alias list
            set output to ""
            repeat with f in theSelection
                set output to output & (POSIX path of f) & linefeed
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return [] }
        let result = apple.executeAndReturnError(&error)
        guard error == nil, let raw = result.stringValue else { return [] }
        return raw.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
            .filter { isImage($0) }
    }

    /// 弹面板挑图片
    static func pickImages() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "选择要识别文字的图片"
        panel.prompt = "识别"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
