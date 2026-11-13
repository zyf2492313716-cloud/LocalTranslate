import Foundation

/// 翻译模式
enum TranslateMode: String, CaseIterable {
    /// rawValue 是存进配置的稳定标识，不随界面文案变化
    case translate
    case polish
    case summarize

    /// 界面上显示的名字
    var title: String {
        switch self {
        case .translate: return "翻译"
        case .polish: return "润色"
        case .summarize: return "总结"
        }
    }

    var instruction: String {
        switch self {
        case .translate:
            return """
            你是专业的翻译引擎。将用户文本翻译成目标语言。
            要求：只输出译文本身，不要解释、不要加引号、不要重复原文。
            如果原文已经是目标语言，原样返回。
            """
        case .polish:
            return """
            你是专业的文字润色助手。润色用户文本，使其表达更自然、地道、简洁。
            要求：保持原意不变，不要添加新信息，不要翻译成其他语言。
            只输出润色后的文本，不要解释。
            """
        case .summarize:
            return """
            你是专业的摘要助手。用目标语言为用户文本提炼要点。
            要求：结论先行，用简洁的要点列表输出，不要逐句复述。
            只输出摘要本身，不要解释。
            """
        }
    }
}

/// 支持的目标语言（Bob 兼容代码，方便和 Bob 生态对齐）
enum Languages {
    /// code -> 显示名
    static let all: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "英语"),
        ("ja", "日语"),
        ("ko", "韩语"),
        ("fr", "法语"),
        ("de", "德语"),
        ("es", "西班牙语"),
        ("ru", "俄语"),
        ("pt", "葡萄牙语"),
        ("it", "意大利语"),
        ("ar", "阿拉伯语"),
        ("hi", "印地语"),
        ("th", "泰语"),
        ("vi", "越南语"),
        ("id", "印尼语"),
        ("tr", "土耳其语"),
        ("nl", "荷兰语"),
        ("pl", "波兰语"),
        ("sv", "瑞典语"),
        ("uk", "乌克兰语"),
        ("he", "希伯来语"),
        ("el", "希腊语"),
        ("cs", "捷克语"),
        ("da", "丹麦语"),
        ("fi", "芬兰语"),
        ("no", "挪威语"),
        ("hu", "匈牙利语"),
        ("ro", "罗马尼亚语"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    /// 把语言代码变成提示词里好读的名字
    static func promptName(for code: String) -> String {
        if code == "auto" { return "自动检测的语言" }
        // Apple 翻译那边会把 zh-Hans 收敛成基础码 zh，提示里不能出现裸 "zh"
        if code == "zh" { return "简体中文" }
        return name(for: code)
    }
}

/// 流式回调
struct TranslationCallbacks {
    var onThink: ((String) -> Void)?
    var onDelta: ((String) -> Void)?
    var onDone: ((String, String) -> Void)?   // (完整译文, 完整思考)
    /// 结果可用但有提醒（比如被截断）。显示在归因行，不混进译文里。
    var onNotice: ((String) -> Void)?
    /// 长文分块时的进度文字（"3/12 块"），显示在服务卡标题旁
    var onProgress: ((String) -> Void)?
    /// 插件自带的词典数据（Cambridge / 有道），由宿主画成词典卡
    var onDictionary: ((DictionaryResult) -> Void)?
    var onError: ((String) -> Void)?
}

/// OpenAI 兼容的 chat/completions 客户端，支持 SSE 流式。
enum Translator {

    enum TranslateError: LocalizedError {
        case notConfigured
        case badURL
        case http(status: Int, message: String)
        case emptyResponse
        case network(String)
        case noKey(profile: String)
        case noProfile

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "还没配置 API Key、Base URL 或模型名，先去设置里填一下。"
            case .badURL:
                return "Base URL 不合法。"
            case .http(let status, let message):
                return "接口返回 \(status)：\(message)"
            case .emptyResponse:
                return "接口没有返回任何内容。"
            case .network(let message):
                return "网络错误：\(message)"
            case .noKey(let name):
                return "「\(name)」还没填 API Key，去设置的服务页里补一下。"
            case .noProfile:
                return "还没配置可用的翻译服务，去设置里加一个。"
            }
        }
    }

    /// 按服务条目构造请求。endpoint、密钥、超时都集中在这里，
    /// 三处调用点不再各自拼一遍。
    private static func makeRequest(profile: ServiceProfile, body: [String: Any], timeout: TimeInterval) -> Result<URLRequest, TranslateError> {
        guard profile.isValidURL else { return .failure(.badURL) }
        guard !profile.model.isEmpty else { return .failure(.noProfile) }
        guard let url = URL(string: profile.chatEndpoint) else { return .failure(.badURL) }
        let key = SecretStore.shared.apiKey(for: profile.keyAccount)
        // 本机回环网关（Magpie 这类）默认不设密钥，不能因为没 key 就拦下来；
        // 真需要鉴权时 Magpie 会返回 401，那个错会带着状态码报出来。
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
        if key.isEmpty && !isLoopback {
            return .failure(.noKey(profile: profile.name))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.network("请求构造失败：\(error.localizedDescription)"))
        }
        return .success(request)
    }

    /// 执行一次翻译。流式增量通过 callbacks 抛出。调用方负责放进 Task 里跑。
    /// DeepL / 有道：一次性请求，拿到整段译文
    private static func translateViaProvider(text: String,
                                             targetLanguage: String,
                                             profile: ServiceProfile,
                                             onProgress: ((String) -> Void)? = nil,
                                             onDictionary: ((DictionaryResult) -> Void)? = nil) async -> ProviderOutcome {
        let sourceForYoudao = LanguageDetector.detectLanguage(text)

        // 有道免密钥：句子走 aidemo，单词走 jsonapi_s（词典在 DictionaryService 里另外走一次）
        if profile.providerKind == .youdaoFree {
            switch await YoudaoFreeTranslator.translate(text: text, from: sourceForYoudao, to: targetLanguage) {
            case .success(let output): return .success(output)
            case .failure(let failure): return .failure(failure.message)
            }
        }

        // 彩云 / 火山：都是免密钥的 JSON 接口，各自一条链路
        if profile.providerKind == .caiyunFree {
            switch await CaiyunTranslator.translate(text: text, from: sourceForYoudao, to: targetLanguage) {
            case .success(let output): return .success(output)
            case .failure(let failure): return .failure(failure.message)
            }
        }
        if profile.providerKind == .volcengineFree {
            switch await VolcengineTranslator.translate(text: text, from: sourceForYoudao, to: targetLanguage) {
            case .success(let output): return .success(output)
            case .failure(let failure): return .failure(failure.message)
            }
        }

        // 必应免密钥：先抓页面拿令牌再翻译，单独一条链路
        if profile.providerKind == .bing {
            let source = sourceForYoudao
            return await BingTranslator.translate(text: text,
                                                  from: source == targetLanguage ? "auto" : source,
                                                  to: targetLanguage)
        }

        // Apple 系统翻译不走网络，没有 key、没有 baseURL、没有模型名
        if profile.providerKind == .apple {
            guard #available(macOS 15.0, *) else {
                return .failure("Apple 翻译需要 macOS 15 或更新系统")
            }
            do {
                return .success(try await AppleTranslator.translate(text, targetLanguage: targetLanguage))
            } catch {
                return .failure(ErrorMessages.explain("Apple 翻译：\(error.localizedDescription)"))
            }
        }

        // JavaScript 插件：请求与解析都由插件决定
        if profile.providerKind == .plugin {
            let file = profile.pluginFile ?? profile.model
            guard !file.isEmpty else { return .failure("插件服务还没选插件文件") }
            let outcome = await Task.detached {
                PluginRuntime.evaluateTranslate(plugin: file, text: text,
                                                source: Config.shared.sourceLanguage,
                                                target: targetLanguage)
            }.value
            switch outcome {
            case .success(let t):
                // 词典插件（Cambridge 等）的 toDict 在这条链路上带出来
                if let dictionary = PluginRuntime.consumeDictionary() {
                    onDictionary?(dictionary)
                }
                return .success(t)
            case .failure(let e): return .failure(e.localizedDescription)
            }
        }

        var key = SecretStore.shared.apiKey(for: profile.keyAccount)
        if !profile.providerKind.needsKey { key = key.isEmpty ? "-" : key }
        guard !key.isEmpty else { return .failure("「\(profile.name)」还没填 API Key") }

        // 谷歌/MyMemory 都把原文塞在 URL 里，长文必然 400 / 414。
        // 按 URL 编码后的长度切块，逐块翻译再拼回去。
        if profile.providerKind == .google || profile.providerKind == .mymemory || profile.providerKind == .bing {
            let limit = profile.providerKind == .google ? 3000 : (profile.providerKind == .bing ? 1200 : 420)
            let chunks = ProviderCodec.chunkByEncodedLength(text, limit: limit)
            if chunks.count > 1 {
                // 串行翻十几块要几十秒，用户会以为卡死。这里 4 路并发、保持原顺序。
                var results = [String?](repeating: nil, count: chunks.count)
                var done = 0
                var failed = false
                var failedReason = ""
                onProgress?("1/\(chunks.count) 块")
                await withTaskGroup(of: (Int, ProviderOutcome).self) { group in
                    var next = 0
                    func addTask(_ index: Int) {
                        guard index < chunks.count else { return }
                        let chunk = chunks[index]
                        group.addTask {
                            let outcome = await translateViaProvider(text: chunk, targetLanguage: targetLanguage,
                                                                     profile: profile, onProgress: nil)
                            return (index, outcome)
                        }
                    }
                    for _ in 0..<min(2, chunks.count) { addTask(next); next += 1 }
                    while let (index, outcome) = await group.next() {
                        switch outcome {
                        case .success(let t):
                            results[index] = t
                        case .failure(let reason):
                            group.cancelAll()
                            onProgress?("")
                            failedReason = reason
                            failed = true
                            return
                        }
                        done += 1
                        onProgress?("\(min(done + 1, chunks.count))/\(chunks.count) 块")
                        // 块之间留点间隔，免费接口连续打容易被判成刷接口
                        if profile.providerKind == .google {
                            try? await Task.sleep(nanoseconds: 120_000_000)
                        }
                        addTask(next); next += 1
                    }
                }
                if failed {
                    // 把真正的原因带出去：限流、网络、还是服务端 500，用户和自己都能看懂
                    let reason = failedReason.isEmpty ? "未知原因" : failedReason
                    if reason.contains("429") || reason.contains("限流") {
                        ProviderCooldown.mark(profile.id, seconds: 600, reason: "429")
                        return .failure("「\(profile.name)」被限流了（429），已自动暂停 10 分钟。")
                    }
                    return .failure("\(profile.providerKind.title) 长文分块翻译中断：\(reason)")
                }
                let joined = results.compactMap { $0 }.joined(separator: "\n")
                return joined.isEmpty ? .failure("长文分块后没拿到任何译文") : .success(joined)
            }
        }

        let request: ProviderRequest?
        let parse: (Data) -> ProviderOutcome
        switch profile.providerKind {
        case .deeplx:
            request = ProviderCodec.deeplxRequest(text: text, targetLanguage: targetLanguage,
                                                  key: key == "-" ? "" : key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseDeepLX
        case .mymemory:
            request = ProviderCodec.mymemoryRequest(text: text, targetLanguage: targetLanguage,
                                                    baseURL: profile.baseURL, key: key == "-" ? "" : key)
            parse = ProviderCodec.parseMyMemory
        case .deepl:
            request = ProviderCodec.deepLRequest(text: text, targetLanguage: targetLanguage,
                                                 key: key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseDeepL
        case .youdao:
            request = ProviderCodec.youdaoRequest(text: text, targetLanguage: targetLanguage,
                                                  key: key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseYoudao
        case .baidu:
            request = ProviderCodec.baiduRequest(text: text, targetLanguage: targetLanguage,
                                                key: key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseBaidu
        case .tencent:
            request = ProviderCodec.tencentRequest(text: text, targetLanguage: targetLanguage,
                                                    key: key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseTencent
        case .google:
            // 谷歌这个接口不要密钥，所以上面「没填 key 就报错」对它是误伤
            request = ProviderCodec.googleRequest(text: text, targetLanguage: targetLanguage,
                                                  baseURL: profile.baseURL)
            parse = ProviderCodec.parseGoogle
        case .claude:
            request = ProviderCodec.claudeRequest(text: text, targetLanguage: targetLanguage,
                                                  key: key, model: profile.model,
                                                  baseURL: profile.baseURL)
            parse = ProviderCodec.parseClaude
        case .gemini:
            request = ProviderCodec.geminiRequest(text: text, targetLanguage: targetLanguage,
                                                  key: key, model: profile.model,
                                                  baseURL: profile.baseURL)
            parse = ProviderCodec.parseGemini
        case .microsoft:
            request = ProviderCodec.microsoftRequest(text: text, targetLanguage: targetLanguage,
                                                     key: key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseMicrosoft
        case .caiyun:
            request = ProviderCodec.caiyunRequest(text: text, targetLanguage: targetLanguage,
                                                  key: key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseCaiyun
        case .niu:
            request = ProviderCodec.niuRequest(text: text, targetLanguage: targetLanguage,
                                               key: key, baseURL: profile.baseURL)
            parse = ProviderCodec.parseNiu
        case .amazon:
            request = ProviderCodec.amazonRequest(text: text, targetLanguage: targetLanguage,
                                                  key: key)
            parse = ProviderCodec.parseAmazon
        case .openai, .apple, .plugin, .bing, .youdaoFree, .caiyunFree, .volcengineFree:
            return .failure("走错了分支")
        }

        guard let request else {
            return .failure("请求参数不对，检查 Base URL 和 API Key 格式（有道是 appKey:appSecret）")
        }

        var urlRequest = URLRequest(url: request.url)
        if request.body.isEmpty && (profile.providerKind == .google || profile.providerKind == .mymemory) {
            urlRequest.httpMethod = "GET"
        } else {
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = request.body
        }
        urlRequest.timeoutInterval = Config.shared.timeoutSeconds
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            var data = Data()
            var response: URLResponse?
            // MyMemory 这个免费接口经常几十秒内抽风一次，重试一次比让用户重按快捷键强
            let attempts = profile.providerKind == .mymemory ? 2 : 1
            for attempt in 1...attempts {
                do {
                    let (d, r) = try await NetworkSession.shared.data(for: urlRequest)
                    data = d; response = r
                    break
                } catch {
                    if attempt == attempts { throw error }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let code = http.statusCode
                if code == 429 || code == 503 {
                    // 免费接口被限流是常态：先退避重试两次，仍不行就冷静十分钟
                    for attempt in 1...2 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_200_000_000)
                        if let (d, r) = try? await NetworkSession.shared.data(for: urlRequest),
                           let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode), !d.isEmpty {
                            return parse(d)
                        }
                    }
                    ProviderCooldown.mark(profile.id, seconds: 600, reason: "\(code)")
                    return .failure(code == 429
                        ? "「\(profile.name)」被限流了（429），已自动暂停 10 分钟，期间由其它引擎负责翻译。"
                        : "「\(profile.name)」暂时不可用（503），已自动暂停 10 分钟。")
                }
                let text = ErrorMessages.stripHTML(String(data: data, encoding: .utf8) ?? "")
                let finalURL = (response as? HTTPURLResponse)?.url?.absoluteString ?? ""
                if finalURL.contains("/sorry/") || text.contains("unusual traffic") || text.contains("系统检测到") {
                    // 谷歌把请求导向人机验证：整台机器的 IP 被临时限制了，重试没用
                    ProviderCooldown.mark(profile.id, seconds: 900, reason: "人机验证")
                    return .failure("「\(profile.name)」被谷歌要求人机验证（IP 被临时限制），已暂停 15 分钟。"
                                    + "在浏览器打开 google.com 手动过一次验证即可恢复；这段时间必应/Apple 照常翻译。")
                }
                if code == 302 || code == 301 {
                    let target = ErrorMessages.stripHTML(finalURL)
                    return .failure("\(profile.providerKind.title) 发生了跳转（\(code)）\(target.isEmpty ? "" : " → \(target)")")
                }
                let suffix = text.isEmpty ? "" : "：\(String(text.prefix(120)))"
                return .failure(ErrorMessages.explain("\(profile.providerKind.title) 返回 \(code)\(suffix)"))
            }
            return parse(data)
        } catch {
            return .failure("\(profile.providerKind.title) 请求失败：\(error.localizedDescription)")
        }
    }

    /// 渲染变量模板，支持 $query.text, $query.detectToLang, $query.detectFromLang（对齐 Bob FAQ）
    static func renderPromptTemplate(_ template: String, text: String, sourceLang: String, targetLang: String) -> String {
        template
            .replacingOccurrences(of: "$query.text", with: text)
            .replacingOccurrences(of: "$query.detectToLang", with: targetLang)
            .replacingOccurrences(of: "$query.detectFromLang", with: sourceLang)
    }

    /// 构造 OpenAI 兼容请求体（支持自定义指令模板与 reasoning_effort 推理强度档位）
    static func buildOpenAIBody(
        text: String,
        targetLanguage: String,
        mode: TranslateMode,
        customPrompt: String,
        profile: ServiceProfile,
        stream: Bool = true
    ) -> [String: Any] {
        let detectedFrom = Languages.promptName(for: LanguageDetector.detectLanguage(text))
        let targetName = Languages.promptName(for: targetLanguage)

        var system = mode.instruction
        if mode == .translate {
            system += "\n目标语言：\(targetName)。"
            if let source = Config.shared.sourceLanguagePrompt {
                system += "\n原文语言：\(source)。"
            }
        } else {
            system += "\n输出语言：\(targetName)。"
        }

        let extra = [customPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                     profile.extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !extra.isEmpty {
            let renderedExtra = renderPromptTemplate(extra, text: text, sourceLang: detectedFrom, targetLang: targetName)
            system += "\n\n用户自定义补充要求：\n\(renderedExtra)"
        }

        let userContent: String
        if let tpl = profile.userPromptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !tpl.isEmpty {
            userContent = renderPromptTemplate(tpl, text: text, sourceLang: detectedFrom, targetLang: targetName)
        } else {
            userContent = text
        }

        var body: [String: Any] = [
            "model": profile.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
            "stream": stream,
        ]

        if let effort = profile.reasoningEffort, !effort.isEmpty, effort != "default" {
            body["reasoning_effort"] = effort
        }
        return body
    }

    static func translate(
        text: String,
        targetLanguage: String,
        mode: TranslateMode,
        customPrompt: String = "",
        profile: ServiceProfile,
        callbacks: TranslationCallbacks
    ) async {
        // DeepL / 有道 走各自的协议，不套 OpenAI 的流式那套
        if profile.providerKind != .openai {
            let outcome = await translateViaProvider(text: text, targetLanguage: targetLanguage,
                                                     profile: profile,
                                                     onProgress: { callbacks.onProgress?($0) },
                                                     onDictionary: { callbacks.onDictionary?($0) })
            switch outcome {
            case .success(let translated):
                // 传统机器翻译走 format: lines 结构对齐拼回
                let aligned = LineAligner.align(translatedText: translated, to: text)
                callbacks.onDone?(aligned, "")
            case .failure(let message):
                callbacks.onError?(message)
            }
            return
        }

        let timeout = Config.shared.timeoutSeconds

        let body = buildOpenAIBody(
            text: text,
            targetLanguage: targetLanguage,
            mode: mode,
            customPrompt: customPrompt,
            profile: profile,
            stream: true
        )

        let prepared = makeRequest(profile: profile, body: body, timeout: timeout)
        guard case .success(let request) = prepared else {
            if case .failure(let error) = prepared {
                callbacks.onError?(error.localizedDescription)
            }
            return
        }
        let session = NetworkSession.shared
        do {
            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // 出错时把响应体读完再解析错误信息
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                    errorBody += "\n"
                }
                let code = http.statusCode
                let raw = ErrorMessages.stripHTML(extractErrorMessage(errorBody))
                let suffix = raw.isEmpty ? "" : "：\(String(raw.prefix(120)))"
                callbacks.onError?(ErrorMessages.explain("接口返回 \(code)\(suffix)"))
                return
            }

            var thinkBuffer = ""
            var contentBuffer = ""
            var finishReason: String? = nil

            // 实时拦截与分流 <think>...</think> 标签（对齐 Bob 1.15.0 / 1.21.0）
            let streamParser = ThinkTagStreamParser(
                onContent: { piece in
                    contentBuffer += piece
                    callbacks.onDelta?(piece)
                },
                onThink: { piece in
                    thinkBuffer += piece
                    callbacks.onThink?(piece)
                }
            )

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload.isEmpty { continue }
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else {
                    continue
                }
                if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                    finishReason = reason
                }
                guard let delta = choice["delta"] as? [String: Any] else {
                    continue
                }

                // 推理模型（如 DeepSeek reasoning）的独立字段分流
                for key in ["reasoning_content", "reasoning"] {
                    if let reasoning = delta[key] as? String, !reasoning.isEmpty {
                        thinkBuffer += reasoning
                        callbacks.onThink?(reasoning)
                    }
                }

                if let piece = delta["content"] as? String, !piece.isEmpty {
                    streamParser.feed(piece)
                }
            }
            streamParser.finish()

            // 双重保险：如果模型非流式返回或首尾残留未闭合的 think 标签，再次清洗
            var finalContent = contentBuffer
            var finalThink = thinkBuffer
            if finalContent.contains("<think>") || finalContent.contains("</think>") {
                let splitted = ThinkTagStreamParser.split(text: finalContent)
                finalContent = splitted.content
                if !splitted.think.isEmpty {
                    finalThink += "\n" + splitted.think
                }
            }

            let content = TranslationDiagnostics.sanitize(finalContent)
            let think = TranslationDiagnostics.sanitize(finalThink)
            let issues = TranslationDiagnostics.issues(content: content, think: think, finishReason: finishReason)

            if let error = issues.first(where: { $0.isError }) {
                callbacks.onError?(error.message)
                return
            }
            // 截断这类「有结果但不完整」的情况不报错，只在归因行提醒一句
            for issue in issues where !issue.isError {
                callbacks.onNotice?(issue.message)
            }
            callbacks.onDone?(content, think)
        } catch is CancellationError {
            // 用户取消，静默收尾
        } catch {
            callbacks.onError?("网络错误：\(error.localizedDescription)")
        }
    }

    /// 非流式取一段文本（词典要的是整块 JSON，不适合流式拼接）。
    static func completeJSON(system: String, user: String, profile: ServiceProfile) async -> Result<String, TranslateError> {
        let body: [String: Any] = [
            "model": profile.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
            // 同上：不发 temperature
        ]
        let prepared = makeRequest(profile: profile, body: body, timeout: min(Config.shared.timeoutSeconds, 60))
        guard case .success(let request) = prepared else {
            if case .failure(let error) = prepared { return .failure(error) }
            return .failure(.noProfile)
        }

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.http(status: http.statusCode, message: extractErrorMessage(String(data: data, encoding: .utf8) ?? "")))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.emptyResponse)
            }
            return .success(content)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 直接拿某个服务翻一段纯文本（不建卡片、不回调 UI），给词典兜底用。
    static func translatePlain(text: String, targetLanguage: String,
                               profile: ServiceProfile) async -> ProviderOutcome {
        await translateViaProvider(text: text, targetLanguage: targetLanguage, profile: profile)
    }

    /// 非流式 ping 一下，用于「测试连接」按钮。
    static func validate(profile: ServiceProfile) async -> Result<Void, TranslateError> {
        let body: [String: Any] = [
            "model": profile.model,
            "messages": [["role": "user", "content": "ping"]],
            // 之前这里带 max_tokens: 1 省成本，但有些模型直接拒绝该字段，
            // 「测试连接」就会把一个其实能用的服务判成失败。
            "stream": false,
        ]
        let prepared = makeRequest(profile: profile, body: body, timeout: min(Config.shared.timeoutSeconds, 30))
        guard case .success(let request) = prepared else {
            if case .failure(let error) = prepared { return .failure(error) }
            return .failure(.noProfile)
        }

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.http(status: http.statusCode,
                                      message: extractErrorMessage(String(data: data, encoding: .utf8) ?? "")))
            }
            return .success(())
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// 把请求 URL 压成 host，错误信息里不出现又长又难看的整条查询串
    private static func shortHost(_ url: String?) -> String {
        guard let url, let host = URL(string: url)?.host else { return "" }
        return host
    }

    static func extractErrorMessage(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(body.prefix(200))
        }
        if let err = obj["error"] as? [String: Any] {
            if let msg = err["message"] as? String { return msg }
        }
        if let msg = obj["message"] as? String { return msg }
        return String(body.prefix(200))
    }
}
