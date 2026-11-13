import Foundation

/// 剑桥词典（免密钥）。
///
/// 直接抓 `dictionary.cambridge.org` 的英汉页，抽出音标、词性和中文释义。
/// 用正则而不是完整的 HTML 解析器：这一页的结构很稳定，正则够用且没有额外依赖。
///
/// 定位是**兜底**：ECDict（离线）和苹果词典都查不到时才走这里，所以失败就返回 nil，
/// 不能因为它把整条词典链路拖慢或报错。
enum CambridgeDictionary {

    private static let host = "https://dictionary.cambridge.org/zhs/%E8%AF%8D%E5%85%B8/%E8%8B%B1%E8%AF%AD-%E6%B1%89%E8%AF%AD-%E7%AE%80%E4%BD%93/"

    static func lookup(word rawWord: String) async -> DictionaryResult? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty,
              word.split(separator: " ").count <= 3,
              word.count <= 32,
              word.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-' ")).contains($0) })
        else { return nil }

        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: host + encoded) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }
            return parse(html: html, word: word)
        } catch {
            Debug.log("剑桥词典查询失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 从页面里抽音标、词性、释义
    static func parse(html: String, word: String) -> DictionaryResult? {
        let ipa = matches(pattern: #"class="ipa dipa[^"]*">([^<]+)<"#, in: html)
        var phonetics: [Phonetic] = []
        if ipa.count >= 1 { phonetics.append(Phonetic(type: "uk", value: ipa[0])) }
        if ipa.count >= 2 { phonetics.append(Phonetic(type: "us", value: ipa[1])) }

        // 词性：<span class="pos dpos" ...>noun</span>
        let posList = matches(pattern: #"class="pos dpos"[^>]*>([^<]+)<"#, in: html)
        // 中文释义：<span class="trans dtrans dtrans-se ...">压力</span>
        // 只要「短释义」，排除 hdb（那是例句译文，长且带句号）
        let zhList = matches(pattern: #"class="trans dtrans dtrans-se(?! hdb)[^"]*"[^>]*>([^<]+)<"#, in: html)

        // 词性和释义数量不一定对齐，按常见的「一段词性 + 若干释义」拼装
        var parts: [WordPart] = []
        var cursor = 0
        for pos in posList.prefix(6) {
            var means: [String] = []
            while cursor < zhList.count, means.count < 4 {
                let candidate = zhList[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                cursor += 1
                // 例句译文通常很长且带句号，这里只收短语级释义
                if candidate.count >= 2, candidate.count <= 30, !candidate.hasSuffix("。") {
                    means.append(candidate)
                }
                if means.count >= 2 { break }
            }
            if !means.isEmpty {
                parts.append(WordPart(part: pos.trimmingCharacters(in: .whitespaces), means: means))
            }
        }

        // 词性没抽到时，退化成纯释义
        var translations: [String] = []
        if parts.isEmpty {
            translations = zhList.prefix(6).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 40 }
        } else {
            translations = parts.flatMap { part in
                part.means.map { part.part.isEmpty ? $0 : "\(part.part) \($0)" }
            }
        }

        guard !translations.isEmpty || !phonetics.isEmpty else { return nil }
        let result = DictionaryResult(word: word, translations: Array(translations.prefix(8)),
                                      phonetics: phonetics, parts: Array(parts.prefix(8)),
                                      exchanges: [], collocations: [])
        return result.isEmpty ? nil : result
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let found = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[found])
        }
    }
}
