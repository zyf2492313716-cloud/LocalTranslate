import Foundation

/// 静默翻译的失败信息
struct SilentError: Error { let message: String }

/// 把"一段文字 + 若干服务 + 一个词典请求"并发跑完，结果喂给卡片。
/// 卡片只管显示，不认识网络。
final class TranslateRunner {

    static let shared = TranslateRunner()

    private var tasks: [Task<Void, Never>] = []

    private init() {}

    /// 取消当前这一轮所有在跑的活
    func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// 发起一轮翻译。profiles 为空时用当前开着的服务。
    /// 卡片那边一律用 profile.id 当键，显示时用 name，
    /// 免得两个服务同名就串台。
    /// 最近一次每个服务的结果，对照窗口用
    private(set) var latest: [(name: String, text: String)] = []
    private(set) var latestSource: String = ""

    func recordLatest(profile: ServiceProfile, text: String) {
        if let index = latest.firstIndex(where: { $0.name == profile.name }) {
            latest[index] = (profile.name, text)
        } else {
            latest.append((profile.name, text))
        }
    }

    func resetLatest(source: String) {
        latest = []
        latestSource = source
    }

    func run(
        source: String,
        mode: TranslateMode,
        targetLanguage: String,
        profiles: [ServiceProfile]? = nil,
        card: TranslationCard
    ) {
        cancelAll()
        resetLatest(source: source)

        let targets = (profiles?.isEmpty == false) ? profiles! : ProfileStore.enabled()
        guard !targets.isEmpty else {
            card.fail(model: "", message: "还没配置可用的翻译服务，去设置里加一个。")
            return
        }
        let usable = targets.filter { $0.isConfigured }
        guard !usable.isEmpty else {
            card.fail(model: targets[0].id, message: "服务配置不完整：Base URL 或模型名是空的。")
            return
        }

        let config = Config.shared
        let startedAt = Date()
        let effectiveTarget = LanguageDetector.resolveTargetLanguage(source: source, fallbackTarget: targetLanguage)

        for profile in usable {
            card.beginStream(model: profile.id)
            let task = Task { [weak card] in
                guard let card else { return }
                let callbacks = TranslationCallbacks(
                    onThink: { piece in card.appendThink(model: profile.id, piece: piece) },
                    onDelta: { piece in card.appendDelta(model: profile.id, piece: piece) },
                    onDone: { text, _ in
                        self.recordLatest(profile: profile, text: text)
                        card.complete(model: profile.id, text: text, seconds: Date().timeIntervalSince(startedAt))
                        if config.autoSpeakWhenDone {
                            DispatchQueue.main.async {
                                SpeechService.shared.speak(text)
                            }
                        }
                    },
                    onNotice: { message in
                        // 归因行会带上它（complete 之后刷新），不污染可复制的译文
                        card.setNotice(message)
                    },
                    onProgress: { text in
                        if !text.isEmpty { card.updateStatus(model: profile.id, text: text) }
                    },
                    onDictionary: { dictionary in
                        card.showDictionary(dictionary)
                    },
                    onError: { message in
                        // 限流/人机验证这类"不是我方能修"的失败：撤掉这张卡，
                        // 只在底部提示条说一句，避免整屏红色报错吓人。
                        if message.contains("限流") || message.contains("人机验证")
                            || message.contains("已自动暂停") || message.contains("中断") {
                            card.removeService(model: profile.id)
                            card.setNotice(message)
                        } else {
                            card.fail(model: profile.id, message: message)
                        }
                    }
                )
                // Apple 是离线引擎，语言包没装就完全没法翻。这种情况直接把这张卡撤掉，
                // 而不是甩一张红色报错卡——用户要的是译文，不是配置作业。
                if ProviderCooldown.isCoolingDown(profile.id) {
                    card.removeService(model: profile.id)
                    return
                }
                if profile.providerKind == .mymemory,
                   ProviderCodec.chunkByEncodedLength(source, limit: 420).count > 3 {
                    card.removeService(model: profile.id)
                    return
                }
                if profile.providerKind == .apple, #available(macOS 15.0, *) {
                    let availability = await AppleTranslator.availability(
                        targetLanguage: effectiveTarget,
                        sourceLanguage: LanguageDetector.detectLanguage(source))
                    if availability != .installed {
                        card.removeService(model: profile.id)
                        return
                    }
                }
                await Translator.translate(
                    text: source,
                    targetLanguage: effectiveTarget,
                    mode: mode,
                    customPrompt: config.systemPrompt,
                    profile: profile,
                    callbacks: callbacks
                )
            }
            tasks.append(task)
        }

        // 选中单词/词组时顺带问一次词典，跟翻译并行，不互相等
        let dictionaryProfile = usable.first ?? targets[0]
        if config.dictionaryEnabled, mode == .translate,
           DictionaryService.shouldUseDictionary(source, maxWords: config.dictionaryMaxWords) {
            if let offline = ECDictService.query(word: source) {
                card.showDictionary(offline)
            } else if let appleDict = AppleDictionaryService.query(word: source) {
                card.showDictionary(appleDict)
            } else {
                let task = Task { [weak card] in
                    guard let card else { return }
                    let result = await Translator.completeJSON(
                        system: DictionaryService.systemPrompt(targetLanguage: effectiveTarget),
                        user: DictionaryService.userPrompt(for: source),
                        profile: dictionaryProfile
                    )
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .success(let raw):
                        card.showDictionary(DictionaryService.parse(raw, fallbackWord: source))
                    case .failure(let error):
                        Debug.log("词典请求失败: \(error.localizedDescription)")
                    }
                }
                tasks.append(task)
            }
        } else {
            card.showDictionary(nil)
        }
    }

    /// 静默翻译：不显示卡片，结果直接进剪贴板。
    func runSilently(
        source: String,
        mode: TranslateMode,
        targetLanguage: String,
        completion: @escaping (Result<String, SilentError>) -> Void
    ) {
        cancelAll()
        let usable = ProfileStore.enabled().filter { $0.isConfigured }
        guard !usable.isEmpty else {
            completion(.failure(SilentError(message: "还没配置可用的翻译服务。")))
            return
        }

        let effectiveTarget = LanguageDetector.resolveTargetLanguage(source: source, fallbackTarget: targetLanguage)
        let task = Task {
            // 静默模式同样要「哪家能翻就用哪家」。
            // 以前只取第一个服务，第一个恰好是 Apple 又没装对应语言包时，
            // 整条静默替换就无声无息地失败了——用户只会觉得快捷键坏了。
            var lastError = ""
            for profile in usable {
                if ProviderCooldown.isCoolingDown(profile.id) { continue }
                if profile.providerKind == .apple, #available(macOS 15.0, *) {
                    let status = await AppleTranslator.availability(
                        targetLanguage: effectiveTarget,
                        sourceLanguage: LanguageDetector.detectLanguage(source))
                    if status != .installed {
                        lastError = "Apple 翻译缺语言包"
                        continue
                    }
                }
                if profile.providerKind == .mymemory,
                   ProviderCodec.chunkByEncodedLength(source, limit: 420).count > 3 {
                    lastError = "MyMemory 不支持长文"
                    continue
                }
                var collected = ""
                var failure: String?
                let callbacks = TranslationCallbacks(
                    onThink: { _ in },
                    onDelta: { collected += $0 },
                    onDone: { text, _ in collected = text },
                    onNotice: { message in
                        DispatchQueue.main.async { HUD.show(message) }
                    },
                    onError: { failure = $0 }
                )
                await Translator.translate(
                    text: source,
                    targetLanguage: effectiveTarget,
                    mode: mode,
                    customPrompt: Config.shared.systemPrompt,
                    profile: profile,
                    callbacks: callbacks
                )
                if let failure {
                    lastError = failure
                    Debug.log("静默翻译：\(profile.name) 失败，换下一家 —— \(failure)")
                    continue
                }
                let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    lastError = "\(profile.name) 返回空译文"
                    continue
                }
                completion(.success(collected))
                return
            }
            completion(.failure(SilentError(message: lastError.isEmpty ? "所有服务都没翻出来" : lastError)))
        }
        tasks.append(task)
    }
}
