import Foundation

/// 词典模式的纯逻辑：判断要不要走词典、构造提示词、把模型返回的文本解析成 DictionaryResult。
///
/// 设计约束：
/// - 只依赖 Foundation 与 Contract.swift 里的类型，不发请求、不 import AppKit。
///   这样 `swiftc -typecheck` 两个文件就能验，命令行 `--selftest` 也能脱离 UI 单独跑。
/// - 解析面向真实模型输出：代码围栏、前后解释文字、尾随逗号、中文 key、
///   字段类型不对（means 给成字符串）、被 max_tokens 截断——要么修好，要么安全返回 nil，
///   绝不崩溃、绝不打日志把用户选区内容带出去。
/// - 判据宁可漏判：判成词典模式最坏是一次空 JSON（退回普通翻译），
///   所以 shouldUseDictionary 只在明显是"单词/词组"时才返回 true。
enum DictionaryService {

    // MARK: - 配置常量

    /// 英文单词/短语的最大词数
    private static let maxLatinWords = 4
    /// 中日韩短语的最大字符数（不含空格）
    private static let maxCJKCharacters = 12
    /// 总字符数兜底，专门挡 URL、base64 这类不带空格也数不出词的东西
    private static let maxTotalCharacters = 80
    /// 一次解析最多尝试几段"没闭合的尾巴"，防病态文本把扫描拖成平方级
    private static let maxUnbalancedSpans = 4

    /// 句读标点。出现即判定为"句子"而不是"词条"
    private static let strongPunctuation: Set<Character> = [
        "。", "，", "、", "；", "：", "！", "？",
        ",", ";", ":", "!", "?",
    ]

    // MARK: - 是否走词典模式

    /// 判断这段文字是不是"单词/词组查询"，是才走词典模式。
    ///
    /// 依次挡掉：空文本、多行选区、过长文本、纯数字纯符号、带句读的句子，
    /// 再按语言分支限字数：中日韩按字符数（没有空格，数词不可靠），拉丁文按词数。
    static func shouldUseDictionary(_ text: String, maxWords: Int = 4) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 换行 = 多行选区，几乎一定是句子或段落
        if trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
            return false
        }
        guard trimmed.count <= maxTotalCharacters else { return false }

        // 至少要有一个字母或汉字，纯数字、纯符号查不出东西
        let hasLetter = trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) || isCJK($0) }
        guard hasLetter else { return false }

        var body = trimmed
        let cjkText = trimmed.unicodeScalars.contains(where: isCJK)

        if cjkText {
            // 中文短语后面不会带句读，带了（哪怕只有末尾一个）就当句子
            if trimmed.contains(where: { strongPunctuation.contains($0) }) { return false }
        } else {
            // 英文常见"连着句号一起复制"，只容忍末尾那一个 . 或 ,，其余句读一律判成句子
            if trimmed.dropLast().contains(where: { strongPunctuation.contains($0) }) { return false }
            if let last = trimmed.last, strongPunctuation.contains(last) {
                guard last == "." || last == "," else { return false }
                body = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { return false }
            }
        }

        // 中日韩分支：按字符数（"吃紧" 2 个字 → true，"这家公司今天发布了财报" → 末尾已被句读挡掉）
        let cjkCount = body.unicodeScalars.filter { isCJK($0) }.count
        if cjkCount > 0 {
            let nonSpace = body.filter { !$0.isWhitespace }.count
            if nonSpace > maxCJKCharacters { return false }
        }

        let words = body.split(whereSeparator: { $0.isWhitespace }).count
        // maxWords 由设置里的「最多算作词组的长度」传进来；不传时沿用默认值
        if words > Swift.max(1, maxWords) { return false }

        // 纯拉丁但没空格（长单词、误粘的路径）也要挡，词数判据在这种情况下失效
        if cjkCount == 0 && body.count > 60 { return false }
        return true
    }

    // MARK: - 提示词

    /// 给大模型的系统提示：只输出一个 JSON 对象，字段固定，释义语言跟随 targetLanguage。
    ///
    /// 这里刻意不写任何反引号示例：提示词里出现围栏，模型更可能把围栏一起吐出来，
    /// 解析侧就要多剥一层。字段名要求用小写英文，同时说明"查不了就返回空数组的壳"，
    /// 让调用方拿到 isEmpty 后退回普通翻译排版，而不是硬编一个假释义。
    static func systemPrompt(targetLanguage: String) -> String {
        let lang = languageName(for: targetLanguage)
        return """
        你是词典查询引擎。用户给出一个英语单词/短语或一个中文词语，你返回它的词典信息。
        只输出一个 JSON 对象，不输出任何其他文字。

        字段固定如下，字段名必须逐字使用小写英文：
        word: 字符串，原样返回用户查询的词条，不要改写、不要加引号。
        translations: 字符串数组，简明释义，最多 4 条，每条形如 "n. 压力"（词性 + 空格 + 释义）。
        phonetics: 对象数组，每项形如 {"type":"us","value":"ˈpreʃɚ"}；type 只能是 "us" 或 "uk"；value 是音标文本，不要包斜杠。
        parts: 对象数组，每项形如 {"part":"n.","means":["压力","压迫"]}；part 用 n. / vt. / vi. / adj. / adv. 这类缩写。
        exchanges: 对象数组，每项形如 {"name":"现在分词","words":["pressuring"]}；name 取 现在分词/过去式/过去分词/第三人称单数/比较级/最高级/复数。
        collocations: 对象数组，每项形如 {"phrase":"under pressure","translation":"在压力下"}，最多 5 条常见搭配。

        规则：
        1. 所有释义、搭配解释一律用\(lang)；词性缩写保持英文符号不变。
        2. 不要使用 markdown，不要加代码围栏，不要加任何解释、前后缀说明、思考过程、寒暄。
        3. 必须是合法 JSON：键和字符串用双引号，不要尾随逗号，不要单引号，字符串内不要出现裸换行。
        4. 某类信息没有就给它一个空数组，字段本身不要省略。音标不确定就留空数组，不要编造。
        5. 如果用户给的不成其为词条（已成句、是代码或数字、是人名地名等专有名词且无通用释义），
           只输出：{"word":"原词","translations":[],"phonetics":[],"parts":[],"exchanges":[],"collocations":[]}
        """
    }

    /// 用户消息：就是被查的词本身，加一行限定，防止模型把它当翻译任务。
    static func userPrompt(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        查询词条：\(trimmed)
        只查这一个单词/短语，按系统提示的字段输出 JSON。
        """
    }

    // MARK: - 解析

    /// 把模型返回的原始文本解析成 DictionaryResult。
    ///
    /// 链路：剥 markdown 围栏 → 截取第一个平衡的 {...}（或 [...]）区间 → 补全被截断的括号 →
    /// 去尾随逗号 → JSONSerialization → 逐字段宽松取值。任何一步失败都返回 nil，
    /// 调用方据此退回普通翻译排版。解析出对象但一个有用字段都没有，也当 nil 处理。
    static func parse(_ raw: String) -> DictionaryResult? {
        guard let dict = jsonObject(from: raw) else { return nil }
        return buildResult(from: dict)
    }

    /// 同上，但 JSON 里 word 缺失或为空时用调用方手里的原文回填（浮窗标题要用原词）。
    static func parse(_ raw: String, fallbackWord: String) -> DictionaryResult? {
        guard var result = parse(raw) else { return nil }
        if result.word.isEmpty {
            result.word = fallbackWord.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// 查词结果。用自定义枚举而不是 Result<String>，因为失败信息要直接给用户看。
    enum DictionaryLookupOutcome {
        case success(DictionaryResult)
        case failure(String)
    }

    /// 单独查一个词的完整词条。和卡片里那版用的是同一套提示词与解析，
    /// 区别只是这里把结果交出去，由词典窗口自己排版。
    /// 把「熟能生巧。」这类带标点的查询词收拾干净：词典是按词条索引的，
    /// 带句号/逗号一定查不到，然后掉进兜底分支报一堆不相干的错误。
    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = CharacterSet.punctuationCharacters.union(.symbols)
            .subtracting(CharacterSet(charactersIn: "-'"))
        while let first = text.unicodeScalars.first, junk.contains(first) {
            text.removeFirst()
        }
        while let last = text.unicodeScalars.last, junk.contains(last) {
            text.removeLast()
        }
        return text
    }

    static func lookup(word rawWord: String) async -> DictionaryLookupOutcome {
        let word = normalize(rawWord)
        guard !word.isEmpty else { return .failure("没有可查的词") }

        // 1. 优先尝试本地离线简明英汉词典 (ECDict)
        if let offline = ECDictService.query(word: word) {
            return .success(offline)
        }

        // 2. 尝试苹果系统原生词典 (DCSCopyTextDefinition，离线牛津/现代汉语秒出)
        if let appleDict = AppleDictionaryService.query(word: word) {
            return .success(appleDict)
        }

        // 2.5 日语优先走 MOJi（英文源都查不了日语）
        if MojiDictionary.shouldHandle(word), let moji = await MojiDictionary.lookup(word: word) {
            return .success(moji)
        }

        // 3. 有道词典（免密钥，英美音标 + 词性释义 + 词形变化）
        //    单词越长越不像词条，交给后面的翻译链路
        if word.split(separator: " ").count <= 2, word.count <= 24,
           let youdao = await YoudaoFreeTranslator.lookup(word: word) {
            return .success(youdao)
        }

        // 4. 剑桥词典（免密钥）：英汉释义，有道没收录时兜底
        if let cambridge = await CambridgeDictionary.lookup(word: word) {
            return .success(cambridge)
        }

        guard let profile = ProfileStore.firstUsable() else {
            // 没有对话类模型：用免密钥翻译引擎给一个最简词条（词 + 译文），
            // 总比甩一句"Base URL 不合法"强。
            if let fallback = await translationFallback(word: word) {
                return .success(fallback)
            }
            return .failure("这个词在本地词典里没有收录；配一个大模型服务可以查到音标和例句。")
        }
        let result = await Translator.completeJSON(
            system: systemPrompt(targetLanguage: Config.shared.targetLanguage),
            user: userPrompt(for: word),
            profile: profile
        )
        switch result {
        case .success(let raw):
            guard let entry = parse(raw, fallbackWord: word), !entry.isEmpty else {
                return .failure("返回的内容不是词典格式")
            }
            return .success(entry)
        case .failure(let error):
            return .failure(error.localizedDescription)
        }
    }

    /// 用免密钥引擎翻一下，拼成最小可用词条
    private static func translationFallback(word: String) async -> DictionaryResult? {
        let target = LanguageDetector.resolveTargetLanguage(source: word,
                                                            fallbackTarget: Config.shared.targetLanguage)
        for profile in ProfileStore.enabled() where profile.isConfigured {
            guard profile.providerKind != .apple && profile.providerKind != .plugin else { continue }
            let outcome = await Translator.translatePlain(text: word, targetLanguage: target, profile: profile)
            if case .success(let text) = outcome, !text.isEmpty {
                return DictionaryResult(word: word, translations: [text], phonetics: [], parts: [],
                                        exchanges: [], collocations: [], examples: [], synonyms: [], antonyms: [])
            }
        }
        return nil
    }

    private static func buildResult(from dict: [String: Any]) -> DictionaryResult? {
        let word = stringValue(value(in: dict, aliases: wordAliases)) ?? ""
        var translations = stringList(value(in: dict, aliases: translationsAliases))
        let parts = parseParts(value(in: dict, aliases: partsAliases))
        let phonetics = parsePhonetics(value(in: dict, aliases: phoneticsAliases))
        let exchanges = parseExchanges(value(in: dict, aliases: exchangesAliases))
        let collocations = parseCollocations(value(in: dict, aliases: collocationsAliases))
        let examples = parseExamples(value(in: dict, aliases: examplesAliases))
        let synonyms = stringList(value(in: dict, aliases: synonymsAliases))
        let antonyms = stringList(value(in: dict, aliases: antonymsAliases))

        // 模型经常只给 parts 不给简明释义，而浮窗最上面那几行恰恰要"词性 + 义项"，
        // 所以从 parts 兜底合成，界面分区不至于空出来。
        if translations.isEmpty {
            var synthesized: [String] = []
            for part in parts.prefix(4) {
                guard let first = part.means.first else { continue }
                synthesized.append(part.part.isEmpty ? first : "\(part.part) \(first)")
            }
            translations = synthesized
        }
        let result = DictionaryResult(
            word: cleanLine(word),
            translations: cap(dedupe(translations), 8),
            phonetics: cap(phonetics, 4),
            parts: cap(parts, 12),
            exchanges: cap(exchanges, 8),
            collocations: cap(collocations, 8),
            examples: cap(examples, 6),
            synonyms: cap(synonyms, 10),
            antonyms: cap(antonyms, 10)
        )
        // 空壳（模型按规则 5 明确"查不了"）→ nil，让调用方走普通翻译，不显示一个空词典区
        return result.isEmpty ? nil : result
    }

    // MARK: - JSON 文本修复

    /// 从任意脏文本里榨出一个 JSON 对象。多轮尝试，前一轮失败才走更激进的修补。
    ///
    /// 文本里可能先出现正文用的花括号（"说明 {见下} 结果：{…}"），所以不是只取第一个区间，
    /// 而是把所有容器区间按顺序都试一遍；都不成才试补括号和全角标点归一。
    private static func jsonObject(from raw: String) -> [String: Any]? {
        let noFence = stripCodeFences(raw)
        for source in [noFence, normalizeLookalikeCharacters(noFence)] {
            for candidate in containerSpans(in: source) {
                if let dict = deserialize(removeTrailingCommas(candidate)) { return dict }
                // 被 max_tokens 截断：补右括号之后往往就是一份合法文档
                if let closed = closeUnbalancedTail(candidate),
                   let dict = deserialize(removeTrailingCommas(closed)) { return dict }
            }
        }
        return nil
    }

    /// 找出文本里所有容器区间：闭合的按原样收，没闭合的把尾巴也收着（交给补全逻辑）。
    /// 尾巴数量设上限，避免病态输入（一堆不配对的花括号）把扫描拖成平方级。
    private static func containerSpans(in text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var index = 0
        var unbalancedUsed = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "{" || ch == "[" {
                if let end = balancedEnd(in: chars, from: index) {
                    out.append(String(chars[index...end]))
                    index = end + 1
                    continue
                }
                if unbalancedUsed < maxUnbalancedSpans {
                    unbalancedUsed += 1
                    out.append(String(chars[index...]))
                }
            }
            index += 1
        }
        return out
    }

    /// 扫描到深度归零的位置。字符串字面量里的括号和转义都不能算数，所以只能自己走一遍。
    /// 返回容器闭合字符的下标（含），没闭合返回 nil。
    private static func balancedEnd(in chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<chars.count {
            let ch = chars[index]
            if inString {
                if escaped { escaped = false; continue }
                switch ch {
                case "\\": escaped = true
                case "\"": inString = false
                default: break
                }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// 补全被截断的 JSON：先处理断在半路的字符串/键值对，再按栈补右括号。
    /// 推理模型和 max_tokens 截断都会给出这种半截文档，直接丢弃太浪费。
    private static func closeUnbalancedTail(_ text: String) -> String? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var lastColonOutsideString: Int?
        var lastCommaOutsideString: Int?

        for (index, ch) in chars.enumerated() {
            if inString {
                if escaped { escaped = false; continue }
                if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": stack.append(ch == "{" ? "}" : "]")
            case "}", "]": if !stack.isEmpty { stack.removeLast() }
            case ":": lastColonOutsideString = index
            case ",": lastCommaOutsideString = index
            default: break
            }
        }

        var tail = String(chars)
        if inString {
            // 断在字符串里，补个右引号收尾
            tail += "\""
        } else if let colon = lastColonOutsideString,
                  colon > (lastCommaOutsideString ?? -1),
                  chars.count - 1 - colon <= 1 {
            // 断在 "key": 后面，值都还没开始，把这个残缺键值对整段丢掉
            tail = String(chars[0..<precedingSeparator(chars, before: colon)])
        }
        // 逆序补齐
        for closer in stack.reversed() { tail.append(closer) }
        return tail
    }

    /// 找到 colon 之前那个 , 或 { 的位置，用于丢弃残缺的最后一个键值对。
    private static func precedingSeparator(_ chars: [Character], before index: Int) -> Int {
        var i = index - 1
        var depth = 0
        var inString = false
        var escaped = false
        while i >= 0 {
            let ch = chars[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                i -= 1
                continue
            }
            switch ch {
            case "\"": inString = true
            case "}", "]": depth += 1
            case "{", "[":
                if depth == 0 { return i + 1 }
                depth -= 1
            case ",":
                if depth == 0 { return i + 1 }
            default: break
            }
            i -= 1
        }
        return 0
    }

    /// 剥掉 markdown 代码围栏。取"围栏对之间"的段落里最长的那一段，
    /// 因为模型有时先给一个示例块再给结果块；顺手去掉 json 语言标记。
    private static func stripCodeFences(_ text: String) -> String {
        guard text.contains("```") || text.contains("~~~") else { return text }
        var best = ""
        for marker in ["```", "~~~"] {
            let pieces = text.components(separatedBy: marker)
            guard pieces.count >= 3 else { continue }
            // 奇数下标是围栏之间的内容
            for index in stride(from: 1, to: pieces.count, by: 2) {
                let piece = pieces[index]
                if piece.contains("{"), piece.count > best.count { best = piece }
            }
        }
        if best.isEmpty {
            // 只有开围栏没有闭围栏：把围栏标记本身去掉，交给后面的括号平衡扫描
            return text.replacingOccurrences(of: "```", with: "").replacingOccurrences(of: "~~~", with: "")
        }
        var body = best.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["json", "JSON", "json5", "javascript"] {
            if body.hasPrefix(tag) { body = String(body.dropFirst(tag.count)) }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉 ]} 之前的尾随逗号。必须自己扫描：正则会把字符串值里的 "a, }" 也改坏。
    private static func removeTrailingCommas(_ text: String) -> String {
        let chars = Array(text)
        var output = ""
        output.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        for (index, ch) in chars.enumerated() {
            if inString {
                output.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true; output.append(ch); continue }
            guard ch == "," else { output.append(ch); continue }
            var next = index + 1
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            if next < chars.count, chars[next] == "}" || chars[next] == "]" { continue }  // 丢掉这个逗号
            output.append(ch)
        }
        return output
    }

    /// 把全角引号/逗号/冒号换成半角。只在正常解析失败后作为兜底试一次，
    /// 因为中文模型常在 JSON 结构里混进全角标点。
    private static func normalizeLookalikeCharacters(_ text: String) -> String {
        var result = text
        let pairs: [(String, String)] = [
            ("\u{FEFF}", ""),
            ("\u{201C}", "\""),   // 左双引号
            ("\u{201D}", "\""),   // 右双引号
            ("\u{FF0C}", ","),    // 全角逗号
            ("\u{FF1A}", ":"),    // 全角冒号
            ("\u{3001}", ","),    // 顿号
        ]
        for (from, to) in pairs {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    private static func deserialize(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = object as? [String: Any] { return dict }
        // 顶层被包成数组：取第一个对象元素
        if let array = object as? [Any] {
            for item in array { if let dict = item as? [String: Any] { return dict } }
        }
        return nil
    }

    // MARK: - 字段取值（宽松）

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let cleaned = cleanLine(string)
            return cleaned.isEmpty ? nil : cleaned
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let pieces = array.compactMap { stringValue($0) }
            return pieces.isEmpty ? nil : pieces.joined(separator: "；")
        default:
            return nil
        }
    }

    /// 取值成字符串数组。真实输出里同一份信息可能是数组、可能是单条字符串、
    /// 也可能是一串用分号顿号连起来的文本，这里统一摊平。
    private static func stringList(_ value: Any?) -> [String] {
        switch value {
        case let array as [Any]:
            var out: [String] = []
            for item in array {
                if let string = stringValue(item) {
                    out.append(contentsOf: splitListString(string))
                }
            }
            return out
        case let string as String:
            return splitListString(string)
        case let dict as [String: Any]:
            // 对象形态 {"1":"压力","2":"压迫"}：取值
            var out: [String] = []
            for key in dict.keys.sorted() {
                if let string = stringValue(dict[key]) { out.append(contentsOf: splitListString(string)) }
            }
            return out
        default:
            return []
        }
    }

    /// 分条。故意不按 ASCII 逗号拆：英文释义里 "n. force, constraint" 拆开会毁掉整行。
    private static func splitListString(_ string: String) -> [String] {
        let separators = CharacterSet(charactersIn: "；;、\u{FF0C}\n|•\u{3000}")
        let pieces = string.components(separatedBy: separators)
        return pieces.map { cleanLine($0) }.filter { !$0.isEmpty }
    }

    private static func parsePhonetics(_ raw: Any?) -> [Phonetic] {
        var out: [Phonetic] = []
        switch raw {
        case let array as [Any]:
            for item in array {
                if let dict = item as? [String: Any] {
                    let type = normalizedPhoneticType(
                        stringValue(value(in: dict, aliases: ["type", "kind", "类型", "区域", "口音", "region"])) ?? "",
                        hint: stringValue(value(in: dict, aliases: ["key", "name", "标签"])) ?? ""
                    )
                    let value = cleanPhonetic(
                        stringValue(value(in: dict, aliases: ["value", "phonetic", "音标", "text", "symbol", "ipa", "pronunciation"])) ?? ""
                    )
                    if !value.isEmpty { out.append(Phonetic(type: type.isEmpty ? "uk" : type, value: value)) }
                } else if let string = stringValue(item) {
                    // 只有裸音标字符串：按 us/uk 顺序猜，模型列两条的常见顺序就是美英或英美
                    let value = cleanPhonetic(string)
                    guard !value.isEmpty else { continue }
                    out.append(Phonetic(type: out.isEmpty ? "uk" : "us", value: value))
                }
            }
        case let dict as [String: Any]:
            // 对象形态 {"us":"...","uk":"..."} 或 {"us-phonetic":"..."}
            for (key, item) in dict {
                let type = normalizedPhoneticType(key, hint: key)
                guard !type.isEmpty, let string = stringValue(item) else { continue }
                let value = cleanPhonetic(string)
                if !value.isEmpty { out.append(Phonetic(type: type, value: value)) }
            }
            out.sort { $0.type == "us" && $1.type != "us" }
        case let string as String:
            // 单一音标字段。多数词典只列一个时给的是英式，所以标 uk，避免界面显示成美音
            let value = cleanPhonetic(string)
            if !value.isEmpty { out.append(Phonetic(type: "uk", value: value)) }
        default:
            break
        }
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.type)\u{1}\($0.value)").inserted }
    }

    /// 把 us / uk / 美式 / 英式 / UK / en-us 之类统一成 "us" 或 "uk"，认不出返回空串。
    private static func normalizedPhoneticType(_ raw: String, hint: String) -> String {
        let key = normalizedKey(raw.isEmpty ? hint : raw) + "|" + normalizedKey(hint)
        if key.contains("us") || key.contains("美") || key.contains("kk") { return "us" }
        if key.contains("uk") || key.contains("gb") || key.contains("英") || key.contains("dj") { return "uk" }
        return ""
    }

    /// 音标文本常写成 /ˈpreʃɚ/ 或 [ˈpreʃɚ]，剥掉包裹符号，界面自己排版。
    private static func cleanPhonetic(_ string: String) -> String {
        var value = cleanLine(string)
        let wraps: [(Character, Character)] = [("/", "/"), ("[", "]"), ("(", ")"), ("「", "」")]
        for (open, close) in wraps {
            if value.count >= 2, value.first == open, value.last == close {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }
        for prefix in ["音标:", "音标：", "美:", "英:", "US:", "UK:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func parseParts(_ raw: Any?) -> [WordPart] {
        var out: [WordPart] = []
        switch raw {
        case let array as [Any]:
            for item in array {
                if let dict = item as? [String: Any] {
                    let part = normalizePart(
                        stringValue(value(in: dict, aliases: ["part", "pos", "词性", "type", "name", "role", "speech"])) ?? ""
                    )
                    var means = stringList(value(in: dict, aliases: ["means", "definitions", "释义", "意思", "义项", "translation", "meanings"]))
                    if means.isEmpty, part.isEmpty {
                        // 既没词性也没义项，说明这条不是词性分区，丢掉
                        continue
                    }
                    if means.isEmpty, let whole = stringValue(value(in: dict, aliases: ["text", "value"])) {
                        means = splitListString(whole)
                    }
                    out.append(WordPart(part: part, means: cap(dedupe(means), 8)))
                } else if let string = stringValue(item) {
                    // 字符串形态 "n. 压力；压迫"：把开头的词性抠出来
                    let (part, means) = splitLeadingPart(string)
                    out.append(WordPart(part: part, means: means))
                }
            }
        case let dict as [String: Any]:
            // 对象形态 {"n.":["压力"],"vt.":["逼迫"]}
            for (key, item) in dict {
                let part = normalizePart(key)
                let means = stringList(item)
                if !means.isEmpty || !part.isEmpty { out.append(WordPart(part: part, means: cap(dedupe(means), 8))) }
            }
        default:
            break
        }
        return out
    }

    /// 词性归一：模型会写 noun / 名词 / n / N.，界面想要统一的 "n." 缩写。
    private static func normalizePart(_ raw: String) -> String {
        let trimmed = cleanLine(raw)
        guard !trimmed.isEmpty else { return "" }
        let key = normalizedKey(trimmed).replacingOccurrences(of: ".", with: "")
        if let mapped = partNameMap[key] { return mapped }
        // 已经带点的缩写（"aux."）原样保留，只是统一小写避免 "N." / "n." 混排
        if trimmed.hasSuffix(".") { return trimmed.lowercased() }
        // 纯字母的短词（"noun" 之类表里没收录的）补一个点，和分区风格保持一致
        if key.count <= 6, key.allSatisfy({ $0.isLetter && $0.isASCII }) { return trimmed + "." }
        return trimmed
    }

    /// 把 "n. 压力；压迫" 拆成 ("n.", ["压力","压迫"])
    private static func splitLeadingPart(_ string: String) -> (String, [String]) {
        let parts = string.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = parts.first, head.count <= 6 else { return ("", splitListString(string)) }
        let headText = String(head)
        let looksLikePart = headText.contains(".") || partNameMap[normalizedKey(headText)] != nil
        guard looksLikePart else { return ("", splitListString(string)) }
        let rest = parts.count > 1 ? splitListString(String(parts[1])) : []
        return (normalizePart(headText), rest)
    }

    private static func parseExchanges(_ raw: Any?) -> [Exchange] {
        var out: [Exchange] = []
        var merged: [String: [String]] = [:]
        var order: [String] = []

        func add(name: String, words: [String]) {
            guard !name.isEmpty, !words.isEmpty else { return }
            if merged[name] == nil { order.append(name); merged[name] = [] }
            merged[name]?.append(contentsOf: words)
        }

        switch raw {
        case let array as [Any]:
            for item in array {
                if let dict = item as? [String: Any] {
                    let rawName = stringValue(value(in: dict, aliases: ["name", "form", "type", "名称", "形式", "变形", "kind"])) ?? ""
                    add(name: normalizeExchangeName(rawName),
                        words: stringList(value(in: dict, aliases: ["words", "word", "value", "values", "变形结果", "变形"])))
                } else if let string = stringValue(item) {
                    let pieces = string.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    if pieces.count == 2 {
                        add(name: normalizeExchangeName(String(pieces[0])), words: splitListString(String(pieces[1])))
                    }
                }
            }
        case let dict as [String: Any]:
            // 牛津/有道风格的短码：{"pl":"priorities","ing":"...","ed":"..."}
            for (key, item) in dict {
                add(name: normalizeExchangeName(key), words: stringList(item))
            }
        default:
            break
        }
        for name in order {
            out.append(Exchange(name: name, words: cap(dedupe(merged[name] ?? []), 6)))
        }
        return out
    }

    /// 变形名归一：短码转成界面要显示的中文名字；认不出就原样保留，别丢信息。
    private static func normalizeExchangeName(_ raw: String) -> String {
        let trimmed = cleanLine(raw)
        guard !trimmed.isEmpty else { return "" }
        let key = normalizedKey(trimmed)
        if let mapped = exchangeNameMap[key] { return mapped }
        return trimmed
    }

    private static func parseCollocations(_ raw: Any?) -> [Collocation] {
        var out: [Collocation] = []
        switch raw {
        case let array as [Any]:
            for item in array {
                if let dict = item as? [String: Any] {
                    let phrase = cleanLine(stringValue(value(in: dict, aliases: ["phrase", "collocation", "短语", "搭配", "text"])) ?? "")
                    let translation = cleanLine(stringValue(value(in: dict, aliases: ["translation", "meaning", "释义", "中文", "解释", "description"])) ?? "")
                    // 没有译文的搭配在界面上就是一行孤零零的英文，不如不显示
                    if !phrase.isEmpty, !translation.isEmpty { out.append(Collocation(phrase: phrase, translation: translation)) }
                } else if let string = stringValue(item) {
                    // 字符串形态 "under pressure 在压力下"：按第一个空白切，后半必须含中日韩
                    let pieces = string.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    if pieces.count == 2, pieces[1].unicodeScalars.contains(where: isCJK) {
                        out.append(Collocation(phrase: String(pieces[0]), translation: cleanLine(String(pieces[1]))))
                    }
                }
            }
        case let dict as [String: Any]:
            for (key, item) in dict {
                let phrase = cleanLine(key)
                guard !phrase.isEmpty, let translation = stringValue(item) else { continue }
                out.append(Collocation(phrase: phrase, translation: translation))
            }
        default:
            break
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.phrase).inserted }
    }

    // MARK: - 小工具

    /// 按别名优先序取值：先精确、再忽略大小写/空格/下划线、最后互为子串。
    /// 子串匹配只对长度 >= 2 的别名开，单字（"词"）一律不模糊匹配，避免误命中"词性"。
    private static func value(in dict: [String: Any], aliases: [String]) -> Any? {
        for alias in aliases {
            if let found = dict[alias] { return found }
        }
        let normalizedAliases = aliases.map { normalizedKey($0) }
        for alias in normalizedAliases where !alias.isEmpty {
            for (key, found) in dict where normalizedKey(key) == alias { return found }
        }
        for alias in normalizedAliases where alias.count >= 2 {
            for (key, found) in dict {
                let normalized = normalizedKey(key)
                guard normalized.count >= 2 else { continue }
                if normalized.contains(alias) || alias.contains(normalized) { return found }
            }
        }
        return nil
    }

    private static func normalizedKey(_ string: String) -> String {
        let lowercased = string.lowercased()
        var out = ""
        for ch in lowercased where !ch.isWhitespace && ch != "_" && ch != "-" && ch != " " {
            out.append(ch)
        }
        return out
    }

    private static func cleanLine(_ string: String) -> String {
        var value = string
        value = value.replacingOccurrences(of: "\u{FEFF}", with: "")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉行首的行内 markdown 记号，模型偶尔给 "- 压力" 或 "**n.** 压力"
        while value.hasPrefix("-") || value.hasPrefix("*") || value.hasPrefix("•") || value.hasPrefix(">") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // 去掉包裹词条的引号
        let quotePairs = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in quotePairs {
            if value.count >= 2, value.hasPrefix(open), value.hasSuffix(close) {
                value = String(value.dropFirst().dropLast())
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private static func cap<T>(_ items: [T], _ limit: Int) -> [T] {
        items.count > limit ? Array(items.prefix(limit)) : items
    }

    /// 汉字/假名/谚文。这些语言里没有空格分词，字数上限才是有效判据。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)      // CJK 统一汉字
            || (0x3400...0x4DBF).contains(value)      // 扩展 A
            || (0xF900...0xFAFF).contains(value)      // 兼容汉字
            || (0x3040...0x30FF).contains(value)      // 日文假名
            || (0xAC00...0xD7AF).contains(value)      // 韩文音节
    }

    /// 语言代码 → 提示词里的可读语言名。
    ///
    /// 这里自带一张精简表而不是复用 Translator.swift 里的 Languages：
    /// 本模块要能单独 typecheck 和单测，跨文件依赖会让验证命令编不过。
    private static func languageName(for code: String) -> String {
        let normalized = normalizedKey(code)
        if normalized.isEmpty || normalized == "auto" { return "用户指定的语言" }
        if let name = languageNames[normalized] { return name }
        // zh-CN / zh_Hans / en-US 这类带地区的写法：取主语言子标签再查
        let primary = String(code.lowercased().prefix(while: { $0 != "-" && $0 != "_" }))
        let key = normalizedKey(primary)
        return languageNames[key] ?? code
    }

    // MARK: - 常量表

    private static let wordAliases = ["word", "headword", "term", "query", "词条", "原词", "单词", "词汇"]
    private static let translationsAliases = [
        "translations", "translation", "简明释义", "中文释义", "释义",
        "definitions", "definition", "means", "simple",
    ]
    private static let phoneticsAliases = ["phonetics", "phonetic", "pronunciation", "音标", "发音"]
    private static let partsAliases = ["parts", "part", "wordPart", "wordParts", "词性", "speech", "pos", "partsOfSpeech", "definitionsDetailed"]
    private static let exchangesAliases = ["exchanges", "exchange", "inflections", "forms", "变形", "词形变化", "变化"]
    private static let collocationsAliases = ["collocations", "collocation", "phrases", "搭配", "短语", "词组"]
    private static let examplesAliases = ["examples", "example", "sentences", "sentence", "例句", "句子"]
    private static let synonymsAliases = ["synonyms", "synonym", "同义词", "近义词"]
    private static let antonymsAliases = ["antonyms", "antonym", "反义词"]

    /// 例句有两种常见返回：纯字符串数组，或者 {sentence, translation} 对象数组。
    /// 都拼成一行一条，界面直接列表显示。
    private static func parseExamples(_ value: Any?) -> [String] {
        if let list = value as? [String] {
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { item -> String? in
            let sentence = (stringValue(item["sentence"]) ?? stringValue(item["text"])
                            ?? stringValue(item["example"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = (stringValue(item["translation"]) ?? stringValue(item["zh"])
                               ?? stringValue(item["chinese"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty && translation.isEmpty { return nil }
            if translation.isEmpty { return sentence }
            if sentence.isEmpty { return translation }
            return sentence + " — " + translation
        }
    }

    private static let partNameMap: [String: String] = [
        "n": "n.", "noun": "n.", "名词": "n.",
        "v": "v.", "verb": "v.", "动词": "v.",
        "vt": "vt.", "vtdot": "vt.", "及物动词": "vt.",
        "vi": "vi.", "不及物动词": "vi.",
        "adj": "adj.", "adjective": "adj.", "a": "adj.", "形容词": "adj.",
        "adv": "adv.", "adverb": "adv.", "副词": "adv.",
        "prep": "prep.", "preposition": "prep.", "介词": "prep.",
        "conj": "conj.", "conjunction": "conj.", "连词": "conj.",
        "pron": "pron.", "pronoun": "pron.", "代词": "pron.",
        "aux": "aux.", "auxiliary": "aux.", "助动词": "aux.",
        "int": "int.", "interj": "interj.", "interjection": "interj.", "感叹词": "interj.",
        "num": "num.", "numeral": "num.", "数词": "num.",
        "art": "art.", "article": "art.", "冠词": "art.",
        "det": "det.", "determiner": "det.",
        "abbr": "abbr.", "abbreviation": "abbr.",
        "phr": "phr.", "phrase": "phr.", "短语": "phr.",
    ]

    private static let exchangeNameMap: [String: String] = [
        "ing": "现在分词", "presentparticiple": "现在分词", "presparticiple": "现在分词", "现在分词": "现在分词", "动名词": "现在分词",
        "ed": "过去式", "past": "过去式", "pasttense": "过去式", "did": "过去式", "过去式": "过去式",
        "done": "过去分词", "pp": "过去分词", "ppl": "过去分词", "pastparticiple": "过去分词", "过去分词": "过去分词",
        "s": "第三人称单数", "3": "第三人称单数", "third": "第三人称单数", "thirdperson": "第三人称单数",
        "thirdpersonsingular": "第三人称单数", "第三人称单数": "第三人称单数", "单三": "第三人称单数",
        "pl": "复数", "plural": "复数", "pluralform": "复数", "复数": "复数",
        "r": "比较级", "er": "比较级", "comparative": "比较级", "more": "比较级", "比较级": "比较级",
        "t": "最高级", "est": "最高级", "superlative": "最高级", "most": "最高级", "最高级": "最高级",
        "orig": "原形", "origin": "原形", "original": "原形", "base": "原形", "baseform": "原形", "原形": "原形",
    ]

    private static let languageNames: [String: String] = [
        "zhhans": "简体中文", "zhhan": "简体中文", "zh": "简体中文", "zhcn": "简体中文", "chinese": "简体中文",
        "zhhant": "繁體中文", "zhtw": "繁體中文", "zhhk": "繁體中文",
        "en": "英语", "ja": "日语", "ko": "韩语", "fr": "法语", "de": "德语", "es": "西班牙语",
        "ru": "俄语", "pt": "葡萄牙语", "it": "意大利语", "ar": "阿拉伯语", "hi": "印地语",
        "th": "泰语", "vi": "越南语", "id": "印尼语", "tr": "土耳其语", "nl": "荷兰语",
        "pl": "波兰语", "sv": "瑞典语", "uk": "乌克兰语", "he": "希伯来语", "el": "希腊语",
        "cs": "捷克语", "da": "丹麦语", "fi": "芬兰语", "no": "挪威语", "hu": "匈牙利语", "ro": "罗马尼亚语",
    ]

    // MARK: - 自测

    /// 硬编码一堆畸形 JSON 跑 parse，返回失败描述数组；空数组表示全通过。
    /// 供 `LocalTranslate --selftest dictionary` 这类命令行自测调用，纯函数、无副作用。
    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ label: String, _ ok: Bool) {
            if !ok { failures.append("✗ \(label)") }
        }

        let clean = """
        {"word":"pressure","translations":["n. 压力","vt. 压迫"],\
        "phonetics":[{"type":"us","value":"ˈpreʃɚ"},{"type":"uk","value":"ˈpreʃə(r)"}],\
        "parts":[{"part":"n.","means":["压力","压迫"]},{"part":"vt.","means":["对…施加压力"]}],\
        "exchanges":[{"name":"现在分词","words":["pressuring"]}],\
        "collocations":[{"phrase":"under pressure","translation":"在压力下"}]}
        """
        let full = parse(clean)
        check("clean JSON 基本字段",
              full?.word == "pressure"
              && full?.translations.count == 2
              && full?.phonetics.count == 2
              && full?.phonetics.first?.type == "us"
              && full?.parts.count == 2
              && full?.parts.last?.means.count == 1
              && full?.exchanges.first?.name == "现在分词"
              && full?.collocations.first?.phrase == "under pressure")

        // 1. 带围栏
        let fenced = "```json\n" + clean + "\n```"
        check("剥掉 ```json 围栏", parse(fenced)?.word == "pressure")
        let fencedNoTag = "```\n" + clean + "\n```"
        check("剥掉无语言标记的围栏", parse(fencedNoTag)?.word == "pressure")

        // 2. 前后有解释文字
        let chatty = "好的，我查到了 pressure 的词典信息：\n" + clean + "\n希望对你有帮助！"
        check("忽略 JSON 前后的解释文字", parse(chatty)?.translations.count == 2)
        let chattyBrace = "说明 {这是普通花括号} 继续：\n" + clean
        check("跳过正文里的伪花括号", parse(chattyBrace)?.word == "pressure")
        let brokenBrace = "先解释一下 {这里有个没配对的括号：\n" + clean
        check("正文里未配对的花括号不影响后面的 JSON", parse(brokenBrace)?.word == "pressure")

        // 3. 尾随逗号
        let trailing = """
        {"word":"x","translations":["a","b",],"parts":[{"part":"n.","means":["m1","m2",]},],\
        "exchanges":[{"name":"复数","words":["xs"],},],}
        """
        let trailingResult = parse(trailing)
        check("去尾随逗号",
              trailingResult?.translations == ["a", "b"]
              && trailingResult?.parts.first?.means == ["m1", "m2"]
              && trailingResult?.exchanges.first?.words == ["xs"])

        // 4. 字段缺失
        let minimal = "{\"word\":\"in demand\",\"translations\":[\"n. 需求\"]}"
        let minimalResult = parse(minimal)
        check("只给必要字段也能出结果",
              minimalResult?.word == "in demand"
              && minimalResult?.parts.isEmpty == true
              && minimalResult?.phonetics.isEmpty == true)

        // 5. means 给成字符串
        let stringMeans = """
        {"word":"吃紧","translations":["n. 供应紧张"],"parts":[{"part":"n.","means":"供应紧张；形势吃紧"}]}
        """
        check("means 是字符串时按分隔符摊平",
              parse(stringMeans)?.parts.first?.means == ["供应紧张", "形势吃紧"])

        // 5b. translations 给成字符串、字段类型完全不对
        let wrongTypes = "{\"word\":\"test\",\"translations\":\"n. 试验, adj. 试验的\",\"parts\":null,\"phonetics\":\"ˈtest\"}"
        let wrongTypesResult = parse(wrongTypes)
        check("translations 是字符串时不炸",
              wrongTypesResult?.translations.isEmpty == false
              && wrongTypesResult?.parts.isEmpty == true
              && wrongTypesResult?.phonetics.first?.value == "ˈtest")

        // 6. key 用中文近义名
        let chineseKeys = """
        {"单词":"take off","音标":[{"类型":"us","音标":"ˌteɪk ˈɔːf"}],\
        "词性":[{"词性":"phr.","释义":"起飞；脱下"}],\
        "搭配":[{"短语":"take off the mask","中文":"摘下面具"}]}
        """
        let chineseKeysResult = parse(chineseKeys)
        check("中文 key（音标/词性/搭配/单词）",
              chineseKeysResult?.word == "take off"
              && chineseKeysResult?.phonetics.first?.type == "us"
              && chineseKeysResult?.parts.first?.part == "phr."
              && chineseKeysResult?.parts.first?.means.count == 2
              && chineseKeysResult?.collocations.first?.translation == "摘下面具")
        check("parts 兜底合成简明释义",
              chineseKeysResult?.translations.first?.hasPrefix("phr.") == true)

        // 7. exchanges 给成短码对象
        let exchangeMap = "{\"word\":\"priority\",\"exchanges\":{\"pl\":\"priorities\",\"ing\":\"prioritizing\"}}"
        let exchangeResult = parse(exchangeMap)
        check("exchanges 短码对象转中文名",
              exchangeResult?.exchanges.count == 2
              && exchangeResult?.exchanges.contains { $0.name == "复数" && $0.words == ["priorities"] } == true)

        // 8. phonetics 给成 us/uk 对象
        let phoneticMap = "{\"word\":\"test\",\"translations\":[\"n. 试验\"],\"phonetics\":{\"us\":\"test\",\"uk\":\"test\"}}"
        check("phonetics 的 us/uk 对象形态", parse(phoneticMap)?.phonetics.count == 2)

        // 9. 词性用英文全称
        let longPart = "{\"word\":\"good\",\"parts\":[{\"part\":\"adjective\",\"means\":[\"好的\"]}]}"
        check("词性 adjective 归一成 adj.", parse(longPart)?.parts.first?.part == "adj.")

        // 10. 顶层被包成数组
        let wrapped = "[" + clean + "]"
        check("顶层数组取第一个对象", parse(wrapped)?.word == "pressure")

        // 11. 全角标点 + 智能引号
        let fullwidth = "{“word”:“x”，“translations”:[“n. 东西”]}"
        check("全角逗号与智能引号兜底", parse(fullwidth)?.translations.first == "n. 东西")

        // 12. 被 max_tokens 截断
        let truncated = "{\"word\":\"pressure\",\"translations\":[\"n. 压力\",\"vt. 压迫\"],\"parts\":[{\"part\":\"n.\",\"means\":[\"压力\""
        let truncatedResult = parse(truncated)
        check("补全截断的字符串与括号",
              truncatedResult?.word == "pressure" && truncatedResult?.translations.count == 2)
        let danglingKey = "{\"word\":\"x\",\"translations\":[\"a\"],\"collocations\":[{\"phrase\":\"p\","
        let danglingResult = parse(danglingKey)
        check("丢弃残缺的最后一个键值对",
              danglingResult?.word == "x" && danglingResult?.translations == ["a"])

        // 13. 字符串里的花括号不能骗过平衡扫描
        let bracesInside = "{\"word\":\"x\",\"translations\":[\"{n. 见 2}\"]} 多余尾巴 }"
        check("值里的花括号不参与配对", parse(bracesInside)?.translations.first == "{n. 见 2}")

        // 14. 彻底解析不出来 → nil
        check("纯文本返回 nil", parse("这段文字不是一个词典条目，抱歉。") == nil)
        check("空文本返回 nil", parse("   ") == nil)
        check("空壳 JSON 返回 nil",
              parse("{\"word\":\"hello\",\"translations\":[],\"phonetics\":[],\"parts\":[],\"exchanges\":[],\"collocations\":[]}") == nil)
        check("半截没救的文本返回 nil", parse("{") == nil)
        check("只有数组没有对象返回 nil", parse("[1,2,3]") == nil)

        // 15. 数值型字段自动转字符串
        check("数字字段自动转字符串", parse("{\"word\":123,\"translations\":[\"n. 数字\"]}")?.word == "123")

        // 16. fallbackWord 回填
        check("word 缺失时用原文回填",
              parse("{\"translations\":[\"n. 压力\"]}", fallbackWord: "  pressure ")?.word == "pressure")

        // 17. isEmpty 语义
        check("有内容时 isEmpty 为 false", full?.isEmpty == false)

        // 18. 词典模式判定
        for yes in ["pressure", "in demand", "吃紧", "take off", "well-known", "供不应求", "AI 人工智能", "run into"] {
            check("shouldUseDictionary(\"\(yes)\") 应为 true", shouldUseDictionary(yes))
        }
        for no in [
            "",
            "   ",
            "The company reported earnings today.",
            "我们在这里讨论一下这个问题吧",
            "https://example.com/a/very/long/path/segment/maybe/even/longer",
            "12345",
            "你好，世界",
            "今天天气不错。",
            "It is what it is!",
            "第一章\n第二章\n第三章",
        ] {
            check("shouldUseDictionary(\"\(no)\") 应为 false", !shouldUseDictionary(no))
        }
        check("shouldUseDictionary 容忍首尾空白", shouldUseDictionary("  pressure \n"))
        check("shouldUseDictionary 挡住 12 字以上的中文短语", !shouldUseDictionary("这个公司的现金流情况已经非常紧张了"))

        // 19. 提示词
        let zhPrompt = systemPrompt(targetLanguage: "zh-Hans")
        check("系统提示要求 JSON", zhPrompt.contains("JSON"))
        check("系统提示禁止围栏", zhPrompt.contains("围栏") && !zhPrompt.contains("```"))
        check("系统提示带目标语言", zhPrompt.contains("简体中文"))
        check("系统提示随语言变化", systemPrompt(targetLanguage: "ja").contains("日语"))
        check("未知语言代码原样使用", systemPrompt(targetLanguage: "xx-YY").contains("xx-YY"))
        check("auto 不写成语言名", systemPrompt(targetLanguage: "auto").contains("用户指定的语言"))
        for field in ["word", "translations", "phonetics", "parts", "exchanges", "collocations"] {
            check("系统提示声明字段 \(field)", zhPrompt.contains(field))
        }
        check("用户提示包含被查词", userPrompt(for: "  take off  ").contains("take off"))

        return failures
    }
}
