import AppKit
import SwiftUI
import Translation

/// Apple 系统翻译：零配置、离线、不要密钥。
///
/// 这是唯一一条「打开就能翻」的路——没有 key 也能用，适合当兜底。
///
/// 有个绕不过去的限制：`TranslationSession` **只能**从 SwiftUI 的
/// `.translationTask` 里取到，AppKit 没有公开的初始化器。
/// 所以这里挂了一个 1×1 的隐藏宿主视图，靠它把 session 桥出来。
/// 桥不住的时候（系统太旧、语言包异常）会返回明确错误，不会静默失败。
enum AppleTranslator {

    /// 这个方向能不能翻
    enum Availability: Equatable {
        case installed          // 语言包已下载，可以直接翻
        case needsDownload      // 支持但语言包没下
        case unsupported        // 系统不支持这个方向

        var text: String {
            switch self {
            case .installed: return "可用（语言包已就绪）"
            case .needsDownload: return "可用，首次翻译会提示下载语言包"
            case .unsupported: return "系统不支持这个语言方向"
            }
        }
    }

    struct BridgeFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 会话没挂上 / 已经失效。这类失败跟「语言方向不支持」无关，重试一次通常就好。
    struct SessionUnavailable: LocalizedError {
        var errorDescription: String? { "系统翻译会话未就绪" }
    }

    /// 系统支持多少种语言（探针用过：21 种）
    @available(macOS 15.0, *)
    static func supportedLanguageCount() async -> Int {
        let languages = await LanguageAvailability().supportedLanguages
        return languages.count
    }

    @available(macOS 15.0, *)
    static func hasLanguage(_ code: String) async -> Bool {
        let languages = await LanguageAvailability().supportedLanguages
        let wanted = code.hasPrefix("zh") ? "zh" : String(code.prefix(2))
        return languages.contains { $0.minimalIdentifier.hasPrefix(wanted) }
    }

    @available(macOS 15.0, *)
    static func availability(targetLanguage: String, sourceLanguage: String = "en") async -> Availability {
        let availability = LanguageAvailability()
        // 两边都收敛到基础标识（zh / en / ja…）。带 script 的 zh-Hans 会被系统误判成 unsupported。
        let source = Locale.Language(identifier: baseLanguage(sourceLanguage))
        let target = Locale.Language(identifier: baseLanguage(targetLanguage))
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    /// 把各种写法收敛成系统认识的基础语种标识。
    /// 关键教训：`LanguageAvailability.status(from:to:)` 对 `zh-Hans` 这种带 script 的标识
    /// 经常直接返回 `.unsupported`，而 `zh` 才是它认的。之前正是因为拿 `zh-Hans` 去问，
    /// 才出现「系统不支持把内容翻译成英文」这种把能翻的内容硬拦死的假失败。
    static func baseLanguage(_ code: String) -> String {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("en") { return "en" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        return String(lower.prefix(2))
    }

    /// 真正翻一段。
    ///
    /// 设计原则：**不做前置能力闸门**。系统那套 `availability` 判定经常误报，
    /// 一旦误报用户就是「怎么点都翻不出来」。这里直接尝试翻译：
    /// 先按检测出的语种翻，失败再退到「让系统自己检测语种」翻一次，
    /// 两次都不行才把系统给的真实原因原样抛出去。
    @available(macOS 15.0, *)
    static func translate(_ text: String, targetLanguage: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let targetCode = baseLanguage(targetLanguage)
        let detectedRaw = LanguageDetector.detectLanguage(trimmed)
        let sourceCode = baseLanguage(detectedRaw)

        // 同语种来回翻没有意义，直接把原文给回去，避免系统翻译原地打转。
        // 注意这一步必须排在 availability 之前：系统对 zh -> zh 一律返回
        // `.unsupported`，先问状态的话这条「原文直接返回」永远走不到，
        // 中文内容会被当成「系统不支持」而报错。
        if sourceCode == targetCode {
            return text
        }

        // 语言包状态的预检已经去掉了。两个原因：
        // 1) `LanguageAvailability.status` 在真实应用进程里误报率很高——实测系统
        //    `zh -> en` 明明是 installed，同进程里却经常返回 `.supported`，于是每句
        //    中文都被告知「缺少简中→英语语言包」，而其实一点就翻得出来；
        // 2) 它真缺包的时候，`session.translate` 自己会抛出语言相关的错误，那时再
        //    给可操作提示也不迟，还更准确。
        // 唯一保留的防守是 `.unsupported` 时不提前判死（同语种已经在上面返回原文了）。

        var lastError: Error?
        for source in [sourceCode, nil] as [String?] {
            // 会话没挂上时立刻重来一次（rebuild 会重建 host 面板）。系统翻译冷启动
            // 第一次常常是这种情况，重试一次基本必过——不重试的话用户看到的就是
            // 一张红色错误卡，而实际上再点一下就好了。
            var attemptsLeft = 2
            while attemptsLeft > 0 {
                attemptsLeft -= 1
                do {
                    return try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await AppleTranslationBridge.shared.translate(trimmed, source: source, target: targetCode)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 12_000_000_000)
                            throw BridgeFailure(message: "系统翻译 12 秒没响应，多半是语言包没下载——到「系统设置 → 通用 → 语言与地区 → 翻译语言」里加一下")
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                } catch let unavailable as SessionUnavailable {
                    lastError = unavailable
                    if attemptsLeft > 0 {
                        // 给 SwiftUI 一点时间把新的 .translationTask 挂上
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        continue
                    }
                    break
                } catch {
                    lastError = error
                    // 换一次「让系统自己检测语种」再试；其它错误直接上报
                    let message = error.localizedDescription.lowercased()
                    let retryable = message.contains("unsupported") || message.contains("不支持")
                        || message.contains("language") || message.contains("超时") || message.contains("timed out")
                    if !retryable { throw error }
                    break
                }
            }
        }

        let raw = lastError?.localizedDescription ?? "未知错误"
        // 所有重试都失败，而且错误确实指向语言/语言包，这时才给下载指引。
        // 其它原因（会话、超时、系统内部错误）原样上报，不要一律甩「缺语言包」——
        // 那是最容易把人带偏的一句提示。
        let lower = raw.lowercased()
        let looksLikeLanguagePack = lower.contains("language") || lower.contains("语言")
            || lower.contains("not supported") || lower.contains("不支持")
        if looksLikeLanguagePack {
            throw BridgeFailure(message: "Apple 翻译这会儿没翻出来「\(Languages.promptName(for: sourceCode)) → \(Languages.promptName(for: targetCode))」：如果是第一次用这个方向，到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载一下语言包；其它引擎不受影响")
        }
        throw BridgeFailure(message: ErrorMessages.explain(raw))
    }
}

/// 把 SwiftUI 的 TranslationSession 桥到 AppKit。
///
/// 核心设计：
/// 1) 在 `.translationTask` 内部维持长连接 `AsyncStream`，同一个语向（例如连续翻译多次 en -> zh）
///    直接复用已激活的 `session`，单次翻译耗时降至 **10~100ms**；
/// 2) 语向变化（例如从 en->zh 切到 zh->en）时自动结束旧流、更新 `configuration`，触发新会话；
/// 3) 全程串行排队（FIFO），彻底避免并发抢占导致的挂死。
@available(macOS 15.0, *)
final class BridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var sessionContinuation: AsyncStream<(String, (Result<String, Error>) -> Void)>.Continuation?
    var activeSource: Locale.Language?
    var activeTarget: Locale.Language?
}

@available(macOS 15.0, *)
/// 一次性完成的异步盒子：保证 continuation 只 resume 一次，超时和真回调谁先到算谁。
final class CompletionBox<T> {
    private var continuation: CheckedContinuation<Result<T, Error>, Never>?
    private var result: Result<T, Error>?
    private let lock = NSLock()

    func finish(_ value: Result<T, Error>) {
        lock.lock()
        if result != nil || continuation == nil {
            // 还没有人在等，先存着
            if result == nil { result = value }
            lock.unlock()
            return
        }
        let cont = continuation
        continuation = nil
        result = value
        lock.unlock()
        cont?.resume(returning: value)
    }

    func wait() async -> Result<T, Error> {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>, Never>) in
            lock.lock()
            if let ready = result {
                lock.unlock()
                cont.resume(returning: ready)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}

@available(macOS 15.0, *)
final class AppleTranslationBridge {

    static let shared = AppleTranslationBridge()

    private var window: NSPanel?
    private let model = BridgeModel()
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquireLock() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func releaseLock() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    @MainActor
    func translate(_ text: String, source: String?, target: String) async throws -> String {
        await acquireLock()
        defer { releaseLock() }

        ensureHost()
        let newSrc = source.map { Locale.Language(identifier: $0) }
        let newDst = Locale.Language(identifier: target)

        if model.configuration?.source != newSrc || model.configuration?.target != newDst || model.sessionContinuation == nil {
            invalidateSession()
            model.activeSource = newSrc
            model.activeTarget = newDst
            model.configuration = TranslationSession.Configuration(source: newSrc, target: newDst)
            model.configuration?.invalidate()
        }

        // 等待 SwiftUI .translationTask 挂载会话（正常只需 ~20ms；语种不可用时系统压根不会回调）
        var waitedMs = 0
        while model.sessionContinuation == nil && waitedMs < 4_000 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedMs += 10
        }
        guard let cont = model.sessionContinuation else {
            // 会话没建起来的原因常常跟语言方向无关（面板被回收、引擎刚启动还没挂载），
            // 交给外层重试一次，能自愈的就别让用户看到报错。
            throw AppleTranslator.SessionUnavailable()
        }

        // 单次完成的闸门：无论「超时」还是「系统真回调」，都只 resume 一次。
        // 以前用 withThrowingTaskGroup 做超时，超时那条赢了以后 continuation 就永远悬着，
        // isBusy 再也不释放——整条 Apple 翻译链路被永久卡死（真实机型上必现）。
        let box = CompletionBox<String>()
        let delivered = cont.yield((text, { result in box.finish(result) }))

        // yield 返回 `.terminated` 只有一个原因：`.translationTask` 那个 for-await 循环
        // 已经结束了（会话被系统回收、host 视图被重建、或者上一次失败后我们主动清了
        // continuation）。这时候把任务塞进一个没人读的流里，回调永远不会来，只能干等
        // 12 秒超时，然后给用户看一句「语言包可能没下载」——文案和真实原因完全对不上。
        // 直接在原地判死，把会话清掉让下一次请求重建，并且说清楚是哪一步断的。
        guard case .enqueued = delivered else {
            invalidateSession()
            throw AppleTranslator.SessionUnavailable()
        }

        let timeoutWork = DispatchWorkItem {
            box.finish(.failure(AppleTranslator.BridgeFailure(message: "系统翻译超时（语言包可能没下载）")))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeoutWork)
        defer { timeoutWork.cancel() }

        let outcome = await box.wait()
        if case .failure = outcome {
            // 会话大概率已经废了，清掉让下一次请求重建
            invalidateSession()
        }
        return try outcome.get()
    }

    @MainActor
    private func invalidateSession() {
        model.sessionContinuation?.finish()
        model.sessionContinuation = nil
        model.configuration = nil
    }

    @MainActor
    private func ensureHost() {
        // 面板可能已经被系统回收（或者窗口所在的那块屏没了），但 `window` 引用还留着。
        // 以前只判 `window == nil`，于是引用还在、视图其实已经没了，SwiftUI 再也不会跑
        // `.translationTask`，会话永远建不起来——表现为 Apple 那一栏一直报「系统不支持
        // 这个语言方向」。这里额外检查一下窗口是否还活着，不活就重建。
        if let window, window.isVisible || window.contentView?.window != nil { return }
        window?.contentView = nil
        window?.close()
        self.window = nil

        let hosting = NSHostingView(rootView: BridgeView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        // 不能 orderOut、也不能 alpha 0：那样 SwiftUI 不会跑 .translationTask
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.setFrameOrigin(NSPoint(x: 40, y: 40))
        panel.orderFrontRegardless()
        self.window = panel
    }
}

@available(macOS 15.0, *)
struct BridgeView: View {

    @ObservedObject var model: BridgeModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                let stream = AsyncStream<(String, (Result<String, Error>) -> Void)> { continuation in
                    DispatchQueue.main.async {
                        model.sessionContinuation = continuation
                    }
                }
                for await (text, reply) in stream {
                    do {
                        let response = try await session.translate(text)
                        reply(.success(response.targetText))
                    } catch {
                        // 会话若失效，清空以便下次自动重建
                        DispatchQueue.main.async {
                            model.sessionContinuation = nil
                            model.configuration = nil
                        }
                        reply(.failure(error))
                        break
                    }
                }
            }
    }
}
