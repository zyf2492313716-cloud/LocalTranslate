import AppKit
import Vision
import ScreenCaptureKit

/// 截图取字：框选屏幕一块区域，用系统 Vision 识别出文字，再走翻译。
///
/// 分三层：
/// - 系统权限：屏幕录制（ScreenCaptureKit 要这个，和辅助功能是两个授权）
/// - 截图：自己画一层半透明遮罩让用户拖框，然后用 ScreenCaptureKit 抓那块
/// - 识别：Vision 的文字识别，中英日韩一起开
///
/// 识别不出文字时一定返回空字符串，由调用方明确告诉用户「没认出字」，
/// 不能让用户对着空卡片猜。
/// OCR 结果。失败信息要直接给用户看，所以不用 Result<T, Error>。
enum OcrOutcome {
    case success(String)
    case failure(String)
}

enum CaptureOutcome {
    case success(CGImage)
    case permissionDenied(String)
    case failure(String)
}

enum ScreenOCR {

    enum PermissionStatus: Equatable {
        /// CGPreflight 与真实 ScreenCaptureKit 截屏均通过
        case granted
        /// CGPreflight 返回 true 假阳性，但真实 ScreenCaptureKit 实测失败或被系统拒绝
        case preflightOnly(String)
        /// 系统预检未授权
        case denied(String)

        var isActuallyGranted: Bool {
            if case .granted = self { return true }
            return false
        }
    }

    /// 同步无弹窗读取：不仅看经常假阳性的 CGPreflightScreenCaptureAccess，
    /// 还通过 CGWindowList 检查是否真正允许读取其他应用层窗口标题。
    static var hasPermission: Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        return canReadOtherWindowTitles()
    }

    /// 经典 macOS 无弹窗启发式探测：无屏幕录制权限时，系统会擦除其他进程正常窗口的 kCGWindowName。
    static func canReadOtherWindowTitles() -> Bool {
        let myPID = getpid()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        var otherNormalWindows = 0
        var namedWindows = 0
        for item in list {
            let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let owner = (item[kCGWindowOwnerName as String] as? String) ?? ""
            if pid == myPID || layer != 0 || owner == "Dock" || owner == "Window Server" || owner == "WindowServer" {
                continue
            }
            otherNormalWindows += 1
            if let title = item[kCGWindowName as String] as? String, !title.isEmpty {
                namedWindows += 1
            }
        }
        // 如果屏幕上有其他正常应用窗口却一个标题也拿不到，说明系统真正拦截了录屏权限（即使 preflight 假阳性）
        if otherNormalWindows >= 2 && namedWindows == 0 {
            return false
        }
        return true
    }

    /// 权威实测探测：实际用 ScreenCaptureKit 截取 1x1 像素来验证是否真的具备录屏捕获能力。
    /// macOS 15/26 上常出现 CGPreflight 返回 true 但实际截图因每月授权或签名缓存被拒的假阳性情况。
    static func probePermission(timeoutSeconds: Double = 2.5) async -> PermissionStatus {
        guard CGPreflightScreenCaptureAccess() else {
            return .denied("系统「屏幕录制」开关未开启")
        }
        if !canReadOtherWindowTitles() {
            return .preflightOnly("预检显示通过，但系统拦截了其他窗口内容读取（典型授权缓存异常或未生效）")
        }

        return await withTaskGroup(of: PermissionStatus?.self) { group in
            group.addTask {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first else {
                        return .preflightOnly("未检测到可用显示器")
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.sourceRect = CGRect(x: 0, y: 0, width: 2, height: 2)
                    config.width = 2
                    config.height = 2
                    config.showsCursor = false
                    _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return .granted
                } catch {
                    return .preflightOnly(error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let result = first {
                return result
            }
            return .preflightOnly("实测录屏响应超时（可能有系统「录屏」确认弹窗待点击或被系统静默挂起）")
        }
    }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 清理当前 BundleID 卡死的 TCC 授权记录并重新拉起授权弹窗
    @discardableResult
    static func resetAndReRequestScreenCapture() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.localtranslate.app"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "ScreenCapture", bundleID]
        try? proc.run()
        proc.waitUntilExit()
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - 识别

    /// 识别一张图里的文字。多行按从上到下拼。
    /// 识别一次。系统 Vision 有偶发返回空的情况（大图、首次加载模型），
    /// 重试一次的代价远小于让用户重截一遍。
    static func recognize(_ image: CGImage, attempts: Int = 2) async -> String {
        for attempt in 0..<max(1, attempts) {
            let text = await recognizeOnce(image)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            if attempt + 1 < attempts {
                Debug.log("OCR 第一次没认出字，重试一次")
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        return ""
    }

    private static func recognizeOnce(_ image: CGImage) async -> String {
        let lines = await recognizeDetailed(image)
        let qr = await detectQRcodes(image)
        var merged: [String] = qr
        merged.append(contentsOf: paragraphize(lines, imageHeight: image.height))
        return merged.joined(separator: "\n\n")
    }

    /// 一条识别到的文字及其在图像中的位置。box 是 CGImage 坐标（原点在左下，单位：像素）。
    struct OCRLine {
        var text: String
        var box: CGRect
    }

    /// 带位置的识别。原图翻译要用这个把译文画回原来的位置。
    static func recognizeDetailed(_ image: CGImage) async -> [OCRLine] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [OCRLine] = observations.compactMap { obs in
                    guard let top = obs.topCandidates(1).first else { return nil }
                    return OCRLine(text: top.string, box: obs.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                Debug.log("OCR 失败: \(error.localizedDescription)")
                continuation.resume(returning: [])
            }
        }
    }

    /// 识别二维码
    static func detectQRcodes(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, _ in
                let observations = (request.results as? [VNBarcodeObservation]) ?? []
                continuation.resume(returning: observations.compactMap { $0.payloadStringValue })
            }
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(returning: []) }
        }
    }

    /// 带真实位置的段落聚类结果，供原图翻译精确覆盖渲染
    struct OCRParagraph {
        var text: String
        var rect: CGRect   // 图像像素坐标（原点左下，单位：像素）
    }

    /// 智能分段。把 Vision 给的一堆行按视觉上的段落合并成段。
    ///
    /// 判据（都是相对量，跨图尺寸通用）：
    /// - 垂直距离超过一行高 1.4 倍 → 视为新段落
    /// - 前一行以句末标点结束 → 视为新段落（对齐 OCR 服务商给的信息也可）
    /// - 同一 y 坐标的左右块合并为一行
    ///
    /// 顺序：Vision 用的坐标系原点在左下，越靠上 y 越大。这里按 y 降序排（顶行先出）。
    static func paragraphize(_ lines: [OCRLine], imageHeight: Int = 1000) -> [String] {
        paragraphizeDetailed(lines, imageWidth: imageHeight, imageHeight: imageHeight).map(\.text)
    }

    /// 智能分段并保留每个段落的真实包围盒（像素坐标），支持两栏 PDF 自动按栏阅读顺序分段
    static func paragraphizeDetailed(_ lines: [OCRLine], imageWidth: Int = 1000, imageHeight: Int = 1000) -> [OCRParagraph] {
        guard !lines.isEmpty else { return [] }

        // 自动探测双栏排版（例如英文文献/教材左右双栏），先读完左栏再读右栏，避免同一 Y 坐标左右串行
        if lines.count >= 6 {
            for splitX in [0.50, 0.47, 0.53, 0.44, 0.56] as [CGFloat] {
                let gutterHalf: CGFloat = 0.015
                var leftCol: [OCRLine] = []
                var rightCol: [OCRLine] = []
                var crosses = false
                for l in lines {
                    if l.box.maxX <= splitX - gutterHalf {
                        leftCol.append(l)
                    } else if l.box.minX >= splitX + gutterHalf {
                        rightCol.append(l)
                    } else {
                        crosses = true
                        break
                    }
                }
                if !crosses && leftCol.count >= 3 && rightCol.count >= 3 {
                    return paragraphizeSingleColumn(leftCol, imageWidth: imageWidth, imageHeight: imageHeight)
                         + paragraphizeSingleColumn(rightCol, imageWidth: imageWidth, imageHeight: imageHeight)
                }
            }
        }
        return paragraphizeSingleColumn(lines, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    private static func paragraphizeSingleColumn(_ lines: [OCRLine], imageWidth: Int, imageHeight: Int) -> [OCRParagraph] {
        guard !lines.isEmpty else { return [] }

        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)

        struct LineItem {
            let text: String
            let top: CGFloat     // 距图像顶部的像素（用于从上到下排序与行间距计算）
            let height: CGFloat
            let left: CGFloat
            let pixelBox: CGRect // 原点左下角（NSImage/CGImage像素坐标）
        }

        let sortedAll = lines.map { line -> LineItem in
            let boxTop = (1 - (line.box.origin.y + line.box.height)) * h
            let boxHeight = line.box.height * h
            let boxLeft = line.box.origin.x * w
            let boxWidth = line.box.width * w
            let pixelRect = CGRect(x: boxLeft, y: line.box.origin.y * h, width: boxWidth, height: boxHeight)
            return LineItem(text: line.text, top: boxTop, height: max(1, boxHeight), left: boxLeft, pixelBox: pixelRect)
        }.sorted { $0.top < $1.top }

        // 同一 y 附近的合并成一行（多列/左右块场景）
        var visualRows: [[LineItem]] = []
        var currentRow: [LineItem] = []
        var rowBaseline: CGFloat = -1
        for line in sortedAll {
            if currentRow.isEmpty {
                currentRow = [line]
                rowBaseline = line.top + line.height / 2
            } else if abs((line.top + line.height / 2) - rowBaseline) <= max(6, line.height * 0.6) {
                currentRow.append(line)
            } else {
                visualRows.append(currentRow)
                currentRow = [line]
                rowBaseline = line.top + line.height / 2
            }
        }
        if !currentRow.isEmpty { visualRows.append(currentRow) }
        visualRows = visualRows.map { $0.sorted { $0.left < $1.left } }

        let endsSentence: (String) -> Bool = { s in
            guard let last = s.last else { return false }
            return ".!?。！？…\"”』」』】".contains(last)
        }

        var result: [OCRParagraph] = []
        var textBuffer: [String] = []
        var boxBuffer: [CGRect] = []
        var prevBottom: CGFloat = 0
        var prevHeight: CGFloat = 0

        for (i, row) in visualRows.enumerated() {
            let lineTop = row[0].top
            let avgHeight = row.map { $0.height }.reduce(0, +) / CGFloat(row.count)
            let gap = i == 0 ? 0 : lineTop - prevBottom

            let startNewPara: Bool
            if i == 0 {
                startNewPara = false
            } else if gap > max(prevHeight * 1.4, avgHeight * 1.4) {
                startNewPara = true
            } else if gap > 4, textBuffer.last.map({ endsSentence($0) }) == true {
                startNewPara = true
            } else {
                startNewPara = false
            }

            let text = row.map(\.text).joined(separator: " ")
            let rowBox = row.map(\.pixelBox).reduce(into: CGRect.null) { $0 = $0.union($1) }

            if startNewPara {
                if !textBuffer.isEmpty {
                    let paraBox = boxBuffer.reduce(into: CGRect.null) { $0 = $0.union($1) }
                    result.append(OCRParagraph(text: textBuffer.joined(separator: "\n"), rect: paraBox))
                }
                textBuffer = [text]
                boxBuffer = [rowBox]
            } else {
                textBuffer.append(text)
                boxBuffer.append(rowBox)
            }
            prevBottom = lineTop + avgHeight
            prevHeight = avgHeight
        }
        if !textBuffer.isEmpty {
            let paraBox = boxBuffer.reduce(into: CGRect.null) { $0 = $0.union($1) }
            result.append(OCRParagraph(text: textBuffer.joined(separator: "\n"), rect: paraBox))
        }
        return result
    }

    // MARK: - 原图翻译

    /// 把译文画回原图对应的真实 BoundingBox 位置。返回画好的新图；失败返回 nil。
    /// 每一段取自 Vision 识别行的真实像素坐标并集，画白底圆角遮罩完全覆盖原文并精准绘制译文。
    static func originalImageTranslate(_ image: CGImage, targetLanguage: String,
                                       profile: ServiceProfile) async -> CGImage? {
        let lines = await recognizeDetailed(image)
        guard !lines.isEmpty else { return nil }
        let paragraphs = paragraphizeDetailed(lines, imageWidth: image.width, imageHeight: image.height)
        guard !paragraphs.isEmpty else { return nil }

        // 逐段翻译
        var translated: [(text: String, rect: CGRect)] = []
        translated.reserveCapacity(paragraphs.count)
        for para in paragraphs {
            let cleaned = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            var result = ""
            let sem = DispatchSemaphore(value: 0)
            let callbacks = TranslationCallbacks(
                onThink: { _ in },
                onDelta: { _ in },
                onDone: { text, _ in result = text; sem.signal() },
                onError: { msg in result = "⚠ \(msg)"; sem.signal() }
            )
            Task {
                await Translator.translate(text: cleaned, targetLanguage: targetLanguage,
                                           mode: .translate, profile: profile, callbacks: callbacks)
            }
            if sem.wait(timeout: .now() + 60) == .timedOut {
                result = "⚠ 翻译超时"
            }
            let resText = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resText.isEmpty {
                translated.append((text: resText, rect: para.rect))
            }
        }

        return compose(image: image, items: translated)
    }

    /// 把翻译段落按实际真实 boundingBox 绘制到图像上精确覆盖
    static func compose(image: CGImage, items: [(text: String, rect: CGRect)]) -> CGImage? {
        let w = image.width
        let h = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // 先绘制原图底图（像素 1:1 严格对齐）
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        for item in items {
            // 对真实包围盒做适度外扩（留出呼吸边距并遮盖毛边）
            var box = item.rect.insetBy(dx: -4, dy: -3)
            box.origin.x = max(2, min(box.origin.x, CGFloat(w) - box.width - 2))
            box.origin.y = max(2, min(box.origin.y, CGFloat(h) - box.height - 2))
            box.size.width = min(box.size.width, CGFloat(w) - box.origin.x - 2)
            box.size.height = min(box.size.height, CGFloat(h) - box.origin.y - 2)

            // 绘制底色遮罩块
            NSColor.white.withAlphaComponent(0.95).setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            path.fill()

            // 字体大小根据原行框高度自适应，留有下限与上限
            let fontSize = max(11, min(box.height * 0.45, 28))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.black,
            ]
            let str = NSAttributedString(string: item.text, attributes: attrs)
            let textRect = box.insetBy(dx: 4, dy: 2)
            str.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// 统一入口：系统 Vision 或云端引擎。云端的 key 存在钥匙串里。
    static func recognize(_ image: CGImage, engine: OcrEngine) async -> OcrOutcome {
        guard engine != .system else {
            let text = await recognize(image)
            return text.isEmpty ? OcrOutcome.failure("这块区域没识别到文字") : OcrOutcome.success(text)
        }

        // 大模型多模态 OCR：使用当前配置的可用大模型服务与密钥
        if engine == .llm {
            guard let profile = ProfileStore.firstUsable() else {
                return OcrOutcome.failure("大模型 OCR 需要在设置的服务列表中配置并启用一个大模型服务")
            }
            let key = SecretStore.shared.apiKey(for: profile.keyAccount)
            guard let request = OcrCodec.llmRequest(image: image, profile: profile, key: key) else {
                return OcrOutcome.failure("大模型 OCR 请求构造失败，检查模型名与 Base URL")
            }
            return await perform(request, engine: engine, parse: OcrCodec.parseLLM)
        }

        let key = SecretStore.shared.apiKey(for: engine.keyAccount)
        guard !key.isEmpty else {
            return OcrOutcome.failure("「\(engine.title)」还没填密钥，去设置里补一下")
        }

        let request: OcrRequest?
        let parse: (Data) -> ProviderOutcome
        switch engine {
        case .google:
            request = OcrCodec.googleRequest(image: image, key: key)
            parse = OcrCodec.parseGoogle
        case .youdao:
            request = OcrCodec.youdaoRequest(image: image, key: key)
            parse = OcrCodec.parseYoudao
        case .tencent:
            request = OcrCodec.tencentRequest(image: image, key: key)
            parse = OcrCodec.parseTencent
        case .baidu:
            // 百度要两步：先换 token 再识别
            guard let tokenRequest = OcrCodec.baiduTokenRequest(key: key) else {
                return OcrOutcome.failure("百度密钥格式不对，应该是 apiKey:secretKey")
            }
            let token: String
            switch await fetchBaiduToken(tokenRequest) {
            case .success(let value): token = value
            case .failure(let message): return OcrOutcome.failure(message)
            }
            guard let request = OcrCodec.baiduOcrRequest(image: image, token: token) else {
                return OcrOutcome.failure("百度 OCR 图片编码失败")
            }
            return await perform(request, engine: engine, parse: OcrCodec.parseBaidu)
        case .volcengine:
            guard let b64 = OcrCodec.base64(image),
                  let request = VolcEngines.ocrRequest(imageBase64: b64, key: key) else {
                return OcrOutcome.failure("火山 OCR 请求构造失败，检查 accessKey:secretKey")
            }
            return await perform(request, engine: engine, parse: VolcEngines.parseOcr)
        case .system, .llm:
            return OcrOutcome.failure("走错了分支")
        }

        guard let request else { return OcrOutcome.failure("图片编码失败，或者密钥格式不对") }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await NetworkSession.shared.data(for: urlRequest)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return OcrOutcome.failure("\(engine.title) 返回 \(http.statusCode)")
            }
            switch parse(data) {
            case .success(let text): return OcrOutcome.success(text)
            case .failure(let message): return OcrOutcome.failure(message)
            }
        } catch {
            return OcrOutcome.failure("\(engine.title) 请求失败：\(error.localizedDescription)")
        }
    }

    /// 发出去并解析
    private static func perform(_ request: OcrRequest, engine: OcrEngine,
                                parse: (Data) -> ProviderOutcome) async -> OcrOutcome {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await NetworkSession.shared.data(for: urlRequest)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return OcrOutcome.failure("\(engine.title) 返回 \(http.statusCode)")
            }
            switch parse(data) {
            case .success(let text): return OcrOutcome.success(text)
            case .failure(let message): return OcrOutcome.failure(message)
            }
        } catch {
            return OcrOutcome.failure("\(engine.title) 请求失败：\(error.localizedDescription)")
        }
    }

    private static var baiduTokenCache: (token: String, expiresAt: Date)?

    private static func fetchBaiduToken(_ request: URLRequest) async -> OcrOutcome {
        if let cached = baiduTokenCache, cached.expiresAt > Date() {
            return OcrOutcome.success(cached.token)
        }
        do {
            let (data, _) = try await NetworkSession.shared.data(for: request)
            guard case .success(let token) = OcrCodec.parseBaiduToken(data) else {
                return OcrOutcome.failure("百度 token 获取失败")
            }
            // 官方给 30 天，这里保守用 25 天
            baiduTokenCache = (token, Date().addingTimeInterval(25 * 24 * 3600))
            return OcrOutcome.success(token)
        } catch {
            return OcrOutcome.failure("百度 token 获取失败：\(error.localizedDescription)")
        }
    }

    /// 按选区从快照里裁出图。rect 是视图逻辑点（左上原点），快照是像素，所以要乘缩放倍率。
    static func crop(_ image: CGImage, to rect: CGRect, scale: CGFloat) -> CGImage? {
        let s = max(1, scale)
        var pixelRect = CGRect(x: rect.origin.x * s, y: rect.origin.y * s,
                               width: rect.width * s, height: rect.height * s).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        pixelRect = pixelRect.intersection(bounds)
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }

    // MARK: - 截图

    /// 抓屏幕上一块矩形（单位：屏幕逻辑点，原点在左上）。
    static func capture(rect: CGRect, screen: NSScreen) async -> CGImage? {
        if case .success(let image) = await captureDetailed(rect: rect, screen: screen) {
            return image
        }
        return nil
    }

    static func captureDetailed(rect: CGRect, screen: NSScreen) async -> CaptureOutcome {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { display in
                display.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }) ?? content.displays.first else {
                return .failure("未找到匹配的显示器")
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            let bounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
            // sourceRect 必须使用逻辑坐标点（top-left 原点），且严禁超出 display 边界，否则报 -3812
            let clamped = rect.intersection(bounds)
            guard !clamped.isNull, clamped.width >= 2, clamped.height >= 2 else {
                return .failure("截图选区超出显示器范围")
            }
            config.sourceRect = clamped
            config.width = max(1, Int(clamped.width * scale))
            config.height = max(1, Int(clamped.height * scale))
            config.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return .success(img)
        } catch {
            let nsErr = error as NSError
            let desc = error.localizedDescription
            Debug.log("截图失败 (\(nsErr.domain) \(nsErr.code)): \(desc)")
            if nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && (nsErr.code == -3801 || nsErr.code == -3802)
                || desc.contains("TCC") || desc.contains("declined") || desc.contains("拒绝") || desc.contains("不允许") {
                return .permissionDenied(desc)
            }
            return .failure(desc)
        }
    }
}
/// 框选遮罩：先抓一张全屏快照，再把快照调暗后铺满屏幕让用户框选。
///
/// 为什么不是"透明遮罩直接盖在活屏上"：
/// 1) 透明窗口的 28% 黑在这台机器上根本没渲染出来（用户按了截图快捷键一片正常，以为没反应）；
/// 2) 活屏遮罩会在真正抓图时被截进去，得靠 sleep 赌时序；
/// 3) 冻结快照做到「所见即所得」——框到的就是拿到的，还省掉第二次抓屏。
/// 只覆盖鼠标所在的那块屏幕——多屏各自铺一层会把坐标系搞复杂，收益不大。
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScreenSelectionWindow: NSObject {

    private var window: SelectionPanel?
    private var onFinish: ((CGRect?, NSScreen, CGImage?) -> Void)?
    private var screen: NSScreen?
    private var snapshot: CGImage?
    private var hiddenAuxWindows: [NSWindow] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    /// 回调第三个参数是「按选区裁剪好的图」；拿不到快照时是 nil，调用方自行回退到实时截图
    func begin(onFinish: @escaping (CGRect?, NSScreen, CGImage?) -> Void) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            onFinish(nil, NSScreen.main ?? NSScreen.screens[0], nil)
            return
        }
        self.screen = screen
        self.onFinish = onFinish

        // 先把自己弹出的设置 / 卡片等窗口收起来，别让它们进快照
        hiddenAuxWindows = []
        for w in NSApp.windows where w.isVisible && w.level.rawValue < NSWindow.Level.screenSaver.rawValue {
            if w === TranslationCard.shared.windowForTesting {
                TranslationCard.shared.close()
            } else if w.className != "NSStatusBarWindow" {
                hiddenAuxWindows.append(w)
                w.orderOut(nil)
            }
        }

        // 直接上遮罩，选完再抓图（抓之前会等遮罩退场，不会截进遮罩）
        self.present(screen: screen, snapshot: nil)
    }

    private func present(screen: NSScreen, snapshot: CGImage?) {
        let panel = SelectionPanel(contentRect: screen.frame,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false)
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true

        let overlay = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                           snapshot: snapshot) { [weak self] rect in
            self?.finish(rect)
        } onCancel: { [weak self] in
            self?.finish(nil)
        }
        panel.contentView = overlay
        self.window = panel
        panel.orderFrontRegardless()
        panel.makeKey()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak overlay] event in
            guard let self, let overlay else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.finish(nil)
                return nil
            }
            if event.keyCode == 49 {
                overlay.setSpacePressed(event.type == .keyDown)
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak overlay] event in
            guard let self, let overlay else { return }
            if event.type == .keyDown && event.keyCode == 53 {
                DispatchQueue.main.async { self.finish(nil) }
            } else if event.keyCode == 49 {
                DispatchQueue.main.async { overlay.setSpacePressed(event.type == .keyDown) }
            }
        }
    }

    private func finish(_ rect: CGRect?) {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor); self.globalKeyMonitor = nil }

        let screen = self.screen ?? NSScreen.main
        window?.orderOut(nil)
        window = nil
        let toRestore = hiddenAuxWindows
        hiddenAuxWindows = []
        let callback = onFinish
        onFinish = nil
        guard let screen else { return }

        var cropped: CGImage?
        if let rect, let snapshot {
            cropped = ScreenOCR.crop(snapshot, to: rect, scale: screen.backingScaleFactor)
        }
        if cropped == nil, let rect {
            // 让遮罩从 WindowServer 撤出去再抓，避免把暗底截进图里
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                callback?(rect, screen, nil)
                for w in toRestore { w.orderBack(nil) }
            }
            return
        }
        callback?(rect, screen, cropped)
        // 原先被收起来的窗口放回最底层：不丢草稿，也不再跳出来挡人
        for w in toRestore { w.orderBack(nil) }
    }
}

/// 快照 + 选区绘制层。坐标换算都在这里，别外泄。
private final class SelectionOverlayView: NSView {

    private let onFinish: (CGRect?) -> Void
    private let onCancel: () -> Void
    private let snapshot: CGImage?
    private var origin: NSPoint?
    private var lastPoint: NSPoint?
    private var isSpaceDown = false
    private var current: NSRect = .zero

    init(frame: NSRect, snapshot: CGImage?,
         onFinish: @escaping (CGRect?) -> Void, onCancel: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onFinish = onFinish
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("不支持 nib") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setSpacePressed(_ pressed: Bool) {
        isSpaceDown = pressed
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        lastPoint = origin
        current = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let originPt = origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let lastPt = lastPoint ?? point

        if isSpaceDown {
            // 按住空格平移选区（对齐 macOS ⌘⇧4 与 Bob 1.4.0 原生手感）
            let dx = point.x - lastPt.x
            let dy = point.y - lastPt.y
            origin = NSPoint(x: originPt.x + dx, y: originPt.y + dy)
            current = current.offsetBy(dx: dx, dy: dy)
        } else {
            current = NSRect(x: min(originPt.x, point.x), y: min(originPt.y, point.y),
                             width: abs(point.x - originPt.x), height: abs(point.y - originPt.y))
        }
        lastPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isSpaceDown = false
        // 太小的框当误触
        if current.width < 6 || current.height < 6 {
            onFinish(nil)
            return
        }
        onFinish(current)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            onCancel()
        } else if event.keyCode == 49 { // space
            isSpaceDown = true
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { // space
            isSpaceDown = false
        } else {
            super.keyUp(with: event)
        }
    }

    /// 把快照按「铺满 bounds」画出来。翻转过一次，避免在 flipped 视图里上下颠倒。
    private func drawSnapshot(in rect: NSRect) {
        guard let snapshot, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(snapshot, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        // 注意：这个非激活透明面板上，整屏半透明填充在实机上完全不显色
        // （小面积深色 pill 却能正常画出来）。与其赌合成行为，不如干脆不压暗：
        // 十字光标 + 白框 + 尺寸标签已经足够指示选区，选完立刻抓图。
        if snapshot != nil {
            NSColor.black.setFill()
            bounds.fill(using: .copy)
            drawSnapshot(in: bounds)
            NSColor.black.withAlphaComponent(0.28).setFill()
            bounds.fill(using: .sourceOver)
        }

        // 选区里恢复原亮度，看清框到了什么
        if current.width > 0, current.height > 0, snapshot != nil {
            drawSnapshot(in: current)
        }

        // 还没开始拉框时给一条操作提示，避免"按了没反应"的错觉
        if current.width < 1 || current.height < 1 {
            let hint = "拖拽选择要识别 / 翻译的区域　·　esc 取消　·　按住空格可平移选区"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
            let size = (hint as NSString).size(withAttributes: attrs)
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: 48,
                              width: size.width + 28, height: size.height + 14)
            let bg = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.black.withAlphaComponent(0.55).setFill()
            bg.fill()
            (hint as NSString).draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 7), withAttributes: attrs)
        }

        guard current.width > 0, current.height > 0 else { return }
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: current)
        path.lineWidth = 1.5
        path.stroke()

        let label = "\(Int(current.width)) × \(Int(current.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = (label as NSString).size(withAttributes: attrs)
        let labelRect = NSRect(x: current.minX, y: max(current.minY + 4, current.maxY + 4),
                               width: labelSize.width + 12, height: labelSize.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 2), withAttributes: attrs)
    }
}
