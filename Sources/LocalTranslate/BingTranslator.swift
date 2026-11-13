import Foundation

/// 必应翻译（免密钥）。
///
/// 走的是网页翻译器那套流程：先取一次页面拿到 `IG` / `IID` / `params_AbusePreventionHelper`
/// 里的 key 和 token，再 POST 到 ttranslatev3。令牌有寿命，这里缓存 5 分钟，
/// 过期或 400 时自动重取一次——比每次都抓页面快很多，也不容易被风控。
enum BingTranslator {

    struct TokenError: Error {
        var message: String
    }

    struct Token {
        var ig: String
        var iid: String
        var key: String
        var token: String
        var fetchedAt: Date
    }

    private static let lock = NSLock()
    private static var cached: Token?
    private static let pageURL = URL(string: "https://cn.bing.com/translator")!
    private static let maxAge: TimeInterval = 300

    /// 目标语言：必应只认 zh-Hans / zh-Hant，不认裸 zh
    static func normalize(_ code: String) -> String {
        switch code {
        case "zh": return "zh-Hans"
        case "auto", "": return "auto"
        default: return code
        }
    }

    static func isSupported(_ code: String) -> Bool {
        !code.isEmpty
    }

    private static func freshToken() -> Token? {
        lock.lock()
        let current = cached
        lock.unlock()
        guard let current, Date().timeIntervalSince(current.fetchedAt) < maxAge else { return nil }
        return current
    }

    private static func fetchToken() async -> Result<Token, TokenError> {
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.init(message: "必应页面返回 \(http.statusCode)"))
            }
            guard let html = String(data: data, encoding: .utf8) else {
                return .failure(.init(message: "必应页面编码无法识别"))
            }
            guard let ig = firstMatch(in: html, pattern: #"IG:"([A-Za-z0-9]+)""#),
                  let iid = firstMatch(in: html, pattern: #"data-iid="(.+?)""#),
                  let key = firstMatch(in: html, pattern: #"var params_AbusePreventionHelper\s*=\s*\[([0-9]+),\s*"([^"]+)""#, group: 1),
                  let token = firstMatch(in: html, pattern: #"var params_AbusePreventionHelper\s*=\s*\[([0-9]+),\s*"([^"]+)""#, group: 2) else {
                return .failure(.init(message: "必应页面结构变了，拿不到翻译令牌"))
            }
            let fresh = Token(ig: ig, iid: iid, key: key, token: token, fetchedAt: Date())
            lock.lock(); cached = fresh; lock.unlock()
            return .success(fresh)
        } catch {
            return .failure(.init(message: "连不上必应：\(error.localizedDescription)"))
        }
    }

    private static func firstMatch(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > group,
              let found = Range(match.range(at: group), in: text) else { return nil }
        return String(text[found])
    }

    private static func request(_ url: URL, token: Token, text: String,
                                from: String, to: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        request.setValue("https://cn.bing.com/translator", forHTTPHeaderField: "Referer")

        func encode(_ value: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        let pairs = [
            "text": text,
            "fromLang": from,
            "to": to,
            "token": token.token,
            "key": token.key,
        ]
        request.httpBody = Data(pairs.map { "\($0.key)=\(encode($0.value))" }.joined(separator: "&").utf8)
        return request
    }

    static func translate(text: String, from: String, to: String) async -> ProviderOutcome {
        let target = normalize(to)
        let source = normalize(from)

        var tokenResult = await fetchToken()
        if case .failure = tokenResult, let stale = cached {
            // 抓不到新的就用旧的再试一次
            tokenResult = .success(stale)
        }
        guard case .success(let token) = tokenResult else {
            if case .failure(let problem) = tokenResult { return .failure(problem.message) }
            return .failure("必应令牌获取失败")
        }

        let hosts = ["cn.bing.com", "www.bing.com"]
        var lastError = "必应没有返回译文"
        for host in hosts {
            guard let url = URL(string: "https://\(host)/ttranslatev3?isVertical=1&IG=\(token.ig)&IID=\(token.iid)") else { continue }
            do {
                let (data, response) = try await NetworkSession.shared.data(
                    for: request(url, token: token, text: text, from: source, to: target))
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 400 || http.statusCode == 401 {
                    // 令牌过期，重取一次再打
                    guard case .success(let renewed) = await fetchToken() else {
                        lastError = "必应令牌过期且重新获取失败"
                        continue
                    }
                    let (retryData, retryResponse) = try await NetworkSession.shared.data(
                        for: request(url, token: renewed, text: text, from: source, to: target))
                    if let http2 = retryResponse as? HTTPURLResponse, (200..<300).contains(http2.statusCode) {
                        if let parsed = parse(retryData) { return .success(parsed) }
                    }
                    lastError = "必应拒绝了请求（\(http.statusCode)）"
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    lastError = "必应返回 \(http.statusCode)"
                    continue
                }
                guard let parsed = parse(data) else {
                    lastError = "必应返回的数据看不懂"
                    continue
                }
                return .success(parsed)
            } catch {
                lastError = "连不上必应：\(error.localizedDescription)"
            }
        }
        return .failure(lastError)
    }

    /// 结构：[{ "translations": [{ "text": "..." }] }]
    static func parse(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let array = object as? [[String: Any]],
           let first = array.first,
           let translations = first["translations"] as? [[String: Any]],
           let text = translations.first?["text"] as? String,
           !text.isEmpty {
            return text
        }
        // 出错时是 {"statusCode":207,"errorMessage":"..."}
        return nil
    }
}
