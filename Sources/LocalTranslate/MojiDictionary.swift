import Foundation

/// MOJi 辞書（免密钥）——日语查词。
///
/// 两条接口：
/// 1. `api.mojidict.com/parse/functions/search-all` 搜词拿 targetId；
/// 2. `ui-union-apis-word` 拿详情（假名、罗马音、词性释义、例句）。
///
/// 定位：日语单词走这里，因为英文源（ECDict / 有道 / 剑桥）都不覆盖日语。
enum MojiDictionary {

    private static let appID = "E62VyFVLMiW7kvbtVq3p"
    private static let searchURL = URL(string: "https://api.mojidict.com/parse/functions/search-all")!
    private static let detailURL = URL(string: "https://api.mojidict.com/parse/functions/ui-union-apis-word")!

    private static func request(_ url: URL, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MOJiDict/20241212 CFNetwork/1568.300.101 Darwin/24.2.0", forHTTPHeaderField: "User-Agent")
        request.setValue(appID, forHTTPHeaderField: "X-Parse-Application-Id")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func post(_ url: URL, body: [String: Any]) async -> [String: Any]? {
        do {
            let (data, response) = try await NetworkSession.shared.data(for: request(url, body: body))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            Debug.log("MOJi 请求失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 只处理日语词：含假名，或整串是汉字且不像中文短语
    static func shouldHandle(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 20, !word.contains(" ") else { return false }
        let hasKana = word.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) }
        if hasKana { return true }
        // 纯汉字：只在短词时尝试（中文长句不进这里）
        return word.count <= 6 && word.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func lookup(word rawWord: String) async -> DictionaryResult? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldHandle(word) else { return nil }

        guard let search = await post(searchURL, body: [
            "inputMethod": 0, "g_ver": "v8.9.0", "g_os": "iOS",
            "text": word, "highlight": true, "types": ["102", "103", "106", "431"],
        ]) else { return nil }

        guard let result = search["result"] as? [String: Any],
              let inner = result["result"] as? [String: Any],
              let wordSection = inner["word"] as? [String: Any],
              let matches = wordSection["searchResult"] as? [[String: Any]],
              let first = matches.first,
              let targetId = first["targetId"] as? String else { return nil }

        guard let detail = await post(detailURL, body: [
            "skipAccessories": false, "objectId": targetId, "g_os": "iOS", "isVerb3": true,
        ]) else { return nil }

        guard let detailResult = detail["result"] as? [String: Any],
              let items = detailResult["result"] as? [[String: Any]],
              let item = items.first,
              let wordInfo = item["word"] as? [String: Any] else { return nil }

        return parse(wordInfo: wordInfo, item: item, fallback: word)
    }

    /// 把 MOJi 的字段拼成我们的 DictionaryResult
    static func parse(wordInfo: [String: Any], item: [String: Any], fallback: String) -> DictionaryResult? {
        let spell = (wordInfo["spell"] as? String) ?? fallback
        let pron = (wordInfo["pron"] as? String) ?? ""
        let romaji = (wordInfo["romaji"] as? String) ?? ""
        let accent = (wordInfo["accent"] as? String) ?? ""
        let excerpt = (wordInfo["excerpt"] as? String) ?? ""

        var phonetics: [Phonetic] = []
        if !pron.isEmpty { phonetics.append(Phonetic(type: "假名", value: pron)) }
        if !romaji.isEmpty { phonetics.append(Phonetic(type: "罗马音", value: romaji)) }
        if !accent.isEmpty { phonetics.append(Phonetic(type: "音调", value: accent)) }

        // excerpt 形如 "[名·自他动·サ变] 用功学习，用功读书；学习知识…"
        var parts: [WordPart] = []
        var translations: [String] = []
        var body = excerpt
        var pos = ""
        if let close = excerpt.firstIndex(of: "]"), excerpt.hasPrefix("[") {
            pos = String(excerpt[excerpt.index(after: excerpt.startIndex)..<close])
            body = String(excerpt[excerpt.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        let means = body.split(whereSeparator: { "；;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !means.isEmpty {
            parts.append(WordPart(part: pos, means: Array(means.prefix(6))))
            translations = means.prefix(6).map { pos.isEmpty ? $0 : "\(pos) \($0)" }
        }

        // 完整释义（subdetails.title）作为补充
        if let subs = item["subdetails"] as? [[String: Any]], !subs.isEmpty {
            var titles: [String] = []
            for sub in subs.prefix(3) {
                guard let title = sub["title"] as? String, !title.isEmpty else { continue }
                titles.append(title)
            }
            if parts.isEmpty, !titles.isEmpty {
                parts.append(WordPart(part: pos, means: Array(titles.prefix(3))))
                translations = Array(titles.prefix(3))
            }
        }

        // 例句：title 是日文，trans 是中文
        var examples: [String] = []
        if let exs = item["examples"] as? [[String: Any]] {
            for ex in exs.prefix(4) {
                let jp = (ex["title"] as? String) ?? (ex["notationTitle"] as? String) ?? ""
                let zh = (ex["trans"] as? String) ?? ""
                guard !jp.isEmpty else { continue }
                examples.append(zh.isEmpty ? jp : "\(jp) — \(zh)")
            }
        }

        var tags: [String] = []
        if let tagString = wordInfo["tags"] as? String, !tagString.isEmpty {
            tags = tagString.split(separator: "#").map(String.init)
        }

        guard !translations.isEmpty || !parts.isEmpty else { return nil }
        let result = DictionaryResult(word: spell, translations: Array(translations.prefix(8)),
                                      phonetics: phonetics, parts: Array(parts.prefix(8)),
                                      exchanges: [], collocations: [],
                                      examples: examples, synonyms: [], antonyms: [])
        _ = tags
        return result.isEmpty ? nil : result
    }
}
