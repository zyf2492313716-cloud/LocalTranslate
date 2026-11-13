import Foundation

/// 彩云小译（免密钥）。
///
/// 协议来自社区插件 `bob-plugin-akl-caiyunxiaoyi-free-translate`：
/// POST `interpreter.cyapi.cn/v1/translator`，JSON body，靠一个固定的 x-authorization 头。
/// 彩云的中文语感比必应更自然，作为第二梯队引擎。
enum CaiyunTranslator {

    struct Failure: Error { var message: String }

    static let endpoint = URL(string: "https://interpreter.cyapi.cn/v1/translator")!

    /// 彩云的语言码：中文一律 zh
    static func normalize(_ code: String) -> String {
        switch code {
        case "zh", "zh-Hans", "zh-Hant": return "zh"
        case "auto", "": return "auto"
        default: return code
        }
    }

    static func translate(text: String, from: String, to: String) async -> Result<String, Failure> {
        let source = normalize(from)
        let target = normalize(to)
        if target == source { return .success(text) }

        // 单次别塞太长的文本，按 2000 字切
        let chunks = YoudaoFreeTranslator.chunk(text, limit: 2000)
        var pieces: [String] = []
        for chunk in chunks {
            switch await translateOnce(chunk, source: source, target: target) {
            case .success(let piece): pieces.append(piece)
            case .failure(let failure):
                if pieces.isEmpty { return .failure(failure) }
            }
        }
        let joined = pieces.joined(separator: "\n")
        return joined.isEmpty ? .failure(Failure(message: "彩云没有返回译文")) : .success(joined)
    }

    private static func translateOnce(_ text: String, source: String, target: String) async -> Result<String, Failure> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("token ssdj273ksdiwi923bsd9", forHTTPHeaderField: "x-authorization")
        request.setValue("caiyunInterpreter/5 CFNetwork/1404.0.5 Darwin/22.3.0",
                         forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "source": text,
            "detect": true,
            "os_type": "ios",
            "device_id": "F1F902F7-1780-4C88-848D-71F35D88A602",
            "trans_type": "\(source)2\(target)",
            "media": "text",
            "request_id": Int.random(in: 100_000_000...999_999_999),
            "user_id": "",
            "dict": true,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(Failure(message: "彩云返回 \(http.statusCode)"))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(Failure(message: "彩云返回的数据看不懂"))
            }
            if let target = object["target"] as? String, !target.isEmpty {
                return .success(target)
            }
            let code = (object["rc"] as? Int) ?? -1
            return .failure(Failure(message: "彩云接口返回异常（rc=\(code)）"))
        } catch {
            return .failure(Failure(message: "连不上彩云：\(error.localizedDescription)"))
        }
    }
}

/// 火山翻译（免密钥）。
///
/// 协议来自社区插件 `bob-plugin-akl-volcengine-free-translate`：
/// POST `translate.volcengine.com/crx/translate/v1/`。
/// 注意结尾的斜杠——不带的话服务端会 307 跳转，某些客户端会把 POST 变成 GET 导致空响应。
enum VolcengineTranslator {

    struct Failure: Error { var message: String }

    static let endpoint = URL(string: "https://translate.volcengine.com/crx/translate/v1/")!

    static func normalize(_ code: String) -> String {
        switch code {
        case "zh", "zh-Hans", "zh-Hant": return "zh"
        case "auto", "": return "auto"
        default: return code
        }
    }

    static func translate(text: String, from: String, to: String) async -> Result<String, Failure> {
        let source = normalize(from)
        let target = normalize(to)
        if target == source { return .success(text) }

        let chunks = YoudaoFreeTranslator.chunk(text, limit: 4000)
        var pieces: [String] = []
        for chunk in chunks {
            switch await translateOnce(chunk, source: source, target: target) {
            case .success(let piece): pieces.append(piece)
            case .failure(let failure):
                if pieces.isEmpty { return .failure(failure) }
            }
        }
        let joined = pieces.joined(separator: "\n")
        return joined.isEmpty ? .failure(Failure(message: "火山没有返回译文")) : .success(joined)
    }

    private static func translateOnce(_ text: String, source: String, target: String) async -> Result<String, Failure> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 不要加 Origin/Referer：火山这条接口带上它们会直接 500，去掉就正常
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "source_language": source,
            "target_language": target,
            "text": text,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(Failure(message: "火山返回 \(http.statusCode)"))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(Failure(message: "火山返回的数据看不懂"))
            }
            if let translation = object["translation"] as? String, !translation.isEmpty {
                return .success(translation)
            }
            return .failure(Failure(message: "火山没有返回译文"))
        } catch {
            return .failure(Failure(message: "连不上火山：\(error.localizedDescription)"))
        }
    }
}
