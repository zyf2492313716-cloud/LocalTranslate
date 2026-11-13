import Foundation

/// 翻译服务商。默认 openai 兼容，另外支持 DeepL 与有道智云。
///
/// 做成「可离线验」的形状：请求怎么拼、响应怎么解，都是纯函数，
/// 自测直接喂固定数据断言，不需要真 key 也不需要联网。
/// 真正发请求那一层只负责把这里拼好的东西送出去。
enum ProviderKind: String, CaseIterable {
    case openai
    case deepl
    case youdao
    case baidu
    case tencent
    case google
    case bing
    case youdaoFree
    case caiyunFree
    case volcengineFree
    case claude
    case gemini
    case microsoft
    case caiyun
    case niu
    case apple
    case plugin
    case amazon
    case deeplx
    case mymemory

    var title: String {
        switch self {
        case .openai: return "OpenAI 兼容"
        case .deepl: return "DeepL"
        case .youdao: return "有道智云"
        case .baidu: return "百度翻译"
        case .tencent: return "腾讯云翻译"
        case .google: return "谷歌翻译（免密钥）"
        case .bing: return "必应翻译（免密钥）"
        case .youdaoFree: return "有道翻译（免密钥）"
        case .caiyunFree: return "彩云小译（免密钥）"
        case .volcengineFree: return "火山翻译（免密钥）"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .microsoft: return "Microsoft 翻译"
        case .caiyun: return "彩云小译"
        case .niu: return "小牛翻译"
        case .apple: return "Apple 翻译（免配置）"
        case .amazon: return "Amazon 翻译"
        case .plugin: return "JavaScript 插件"
        case .deeplx: return "DeepLX (自建/免费)"
        case .mymemory: return "MyMemory 翻译（免密钥）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .deepl: return "https://api-free.deepl.com"
        case .youdao: return "https://openapi.youdao.com"
        case .baidu: return "https://fanyi-api.baidu.com"
        case .tencent: return "https://tmt.tencentcloudapi.com"
        case .google: return "https://translate.googleapis.com"
        case .bing: return "https://cn.bing.com"
        case .youdaoFree: return "https://aidemo.youdao.com"
        case .caiyunFree: return "https://interpreter.cyapi.cn"
        case .volcengineFree: return "https://translate.volcengine.com"
        case .claude: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .microsoft: return "https://api.cognitive.microsofttranslator.com"
        case .caiyun: return "https://api.interpreter.caiyunai.com"
        case .niu: return "https://api.niutrans.com"
        case .apple: return ""
        case .amazon: return "https://translate.us-east-1.amazonaws.com"
        case .plugin: return ""
        case .deeplx: return "http://127.0.0.1:1188"
        case .mymemory: return "https://api.mymemory.translated.net"
        }
    }

    /// 有道要 appKey + appSecret 两个值，所以密钥栏填 "appKey:appSecret"
    var keyHint: String {
        switch self {
        case .bing: return "不用填（免密钥）"
        case .youdaoFree: return "不用填（免密钥）"
        case .caiyunFree: return "不用填（免密钥）"
        case .volcengineFree: return "不用填（免密钥）"
        case .openai: return "sk-..."
        case .deepl: return "DeepL-Auth-Key"
        case .youdao: return "appKey:appSecret"
        case .baidu: return "appid:密钥"
        case .tencent: return "secretId:secretKey"
        case .google: return "不用填"
        case .claude: return "sk-ant-..."
        case .gemini: return "AIza..."
        case .microsoft: return "密钥@区域（区域可省）"
        case .caiyun: return "彩云 token"
        case .niu: return "小牛 apikey"
        case .apple: return "不用填"
        case .amazon: return "accessKey:secretKey@区域"
        case .plugin: return "在插件里自带"
        case .deeplx: return "可选 Token（自建服务通常留空）"
        case .mymemory: return "不用填（可选 Email 提高日限额）"
        }
    }

    var supportsStreaming: Bool { self == .openai }

    /// 这个协议要不要密钥。Apple 走系统离线翻译、谷歌/MyMemory 走公开接口，都不需要。
    /// 能不能处理 OpenAI 风格的对话/JSON 请求
    var supportsChat: Bool {
        switch self {
        case .apple, .google, .bing, .youdaoFree, .caiyunFree, .volcengineFree, .mymemory, .plugin, .deeplx, .deepl, .youdao, .baidu,
             .tencent, .microsoft, .caiyun, .niu, .amazon:
            return false
        case .openai, .claude, .gemini:
            return true
        }
    }

    var needsKey: Bool {
        switch self {
        case .apple, .google, .bing, .youdaoFree, .caiyunFree, .volcengineFree, .mymemory, .plugin, .deeplx: return false
        default: return true
        }
    }
}

struct ProviderRequest {
    var url: URL
    var headers: [String: String]
    var body: Data
}

/// 解析结果。失败信息要直接给人看，所以不用 Result<T, Error>。
enum ProviderOutcome {
    case success(String)
    case failure(String)
}

enum ProviderCodec {

    /// 按「URL 编码后的长度」把长文切成若干块，尽量在句末/换行处断开。
    /// 谷歌免费接口是 GET，URL 太长直接 400；CJK 每个字编码后要占 9 个字符，所以必须按编码长度算。
    static func chunkByEncodedLength(_ text: String, limit: Int) -> [String] {
        func encodedCount(_ s: String) -> Int {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)?.count ?? s.count * 9
        }
        guard encodedCount(text) > limit else { return [text] }

        var chunks: [String] = []
        var current = ""
        // 先按句末标点切，再按换行，最后硬切
        let sentenceEnders = CharacterSet(charactersIn: "。！？!?；;\n")
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            let isBreak = ch.unicodeScalars.allSatisfy { sentenceEnders.contains($0) }
            guard isBreak else { continue }
            if encodedCount(current + buffer) > limit {
                if !current.isEmpty { chunks.append(current) }
                current = ""
                // 单句就超长，只能硬切
                var piece = buffer
                while encodedCount(piece) > limit, !piece.isEmpty {
                    var cut = ""
                    for c in piece {
                        if encodedCount(cut + String(c)) > limit { break }
                        cut.append(c)
                    }
                    if cut.isEmpty { break }
                    chunks.append(cut)
                    piece.removeFirst(cut.count)
                }
                buffer = piece
            } else {
                current += buffer
                buffer = ""
            }
        }
        current += buffer
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - 语言码

    /// DeepL 用大写语言码
    static func deepLLanguage(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh-CN": return "ZH"
        case "zh-Hant", "zh-TW": return "ZH"     // 免费版不支持繁体目标，退到 ZH
        case "en": return "EN-US"
        case "ja": return "JA"
        case "ko": return "KO"
        case "fr": return "FR"
        case "de": return "DE"
        case "es": return "ES"
        case "ru": return "RU"
        default: return "EN-US"
        }
    }

    /// 有道用 zh-CHS / zh-CHT 这种
    static func youdaoLanguage(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh-CN": return "zh-CHS"
        case "zh-Hant", "zh-TW": return "zh-CHT"
        case let other where other.hasPrefix("zh"): return "zh-CHS"
        case "en": return "en"
        case "ja": return "ja"
        case "ko": return "ko"
        case "fr": return "fr"
        case "de": return "de"
        case "es": return "es"
        case "ru": return "ru"
        default: return "en"
        }
    }

    // MARK: - DeepL

    static func deepLRequest(text: String, targetLanguage: String, key: String, baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v2/translate") else { return nil }
        let payload: [String: Any] = [
            "text": [text],
            "target_lang": deepLLanguage(targetLanguage),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return ProviderRequest(url: url,
                               headers: ["Content-Type": "application/json",
                                         "Authorization": "DeepL-Auth-Key \(key)"],
                               body: body)
    }

    static func parseDeepL(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderOutcome.failure("DeepL 返回格式不认识")
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return ProviderOutcome.failure("DeepL：\(message)")
        }
        guard let list = json["translations"] as? [[String: Any]],
              let first = list.first,
              let text = first["text"] as? String else {
            return ProviderOutcome.failure("DeepL 没给译文")
        }
        return ProviderOutcome.success(text)
    }

    // MARK: - DeepLX (开源自建服务，格式为 {text, source_lang, target_lang} 返回 {code: 200, data: "..."})
    static func deeplxRequest(text: String, targetLanguage: String, key: String, baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        let endpoint = base.hasSuffix("/translate") ? base : base + "/translate"
        guard let url = URL(string: endpoint) else { return nil }

        let payload: [String: Any] = [
            "text": text,
            "source_lang": "auto",
            "target_lang": deepLLanguage(targetLanguage),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var headers = ["Content-Type": "application/json"]
        if !key.isEmpty && key != "-" {
            headers["Authorization"] = "Bearer \(key)"
        }
        return ProviderRequest(url: url, headers: headers, body: body)
    }

    static func parseDeepLX(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderOutcome.failure("DeepLX 返回格式不认识")
        }
        let code = (json["code"] as? Int) ?? 200
        guard code == 200 else {
            let msg = (json["message"] as? String) ?? "错误码 \(code)"
            return ProviderOutcome.failure("DeepLX：\(msg)")
        }
        if let dataStr = json["data"] as? String, !dataStr.isEmpty {
            return ProviderOutcome.success(dataStr)
        }
        // 部分实现兼容 DeepL 原生格式
        if let list = json["translations"] as? [[String: Any]], let first = list.first, let t = first["text"] as? String {
            return ProviderOutcome.success(t)
        }
        return ProviderOutcome.failure("DeepLX 没给译文")
    }

    // MARK: - 有道

    /// 有道 v3 签名：SHA256(appKey + truncate(q) + salt + curtime + appSecret)
    static func youdaoSign(appKey: String, query: String, salt: String, curtime: String, appSecret: String) -> String {
        let chars = Array(query)
        // 长度 >20 时取「首10 + 长度 + 末10」
        let truncated: String
        if chars.count <= 20 {
            truncated = query
        } else {
            truncated = String(chars.prefix(10)) + String(chars.count) + String(chars.suffix(10))
        }
        let raw = appKey + truncated + salt + curtime + appSecret
        return sha256(raw)
    }

    static func sha256(_ input: String) -> String {
        // 用系统 CommonCrypto 太绕，这里直接走 CryptoKit 之外的实现：
        // 交给 Foundation 的 SHA256（macOS 10.15+ 有 CryptoKit，见 ProviderDigest）
        ProviderDigest.sha256Hex(input)
    }

    static func youdaoRequest(text: String, targetLanguage: String, key: String, baseURL: String,
                              now: Date = Date(), salt: String = "12345") -> ProviderRequest? {
        // 密钥栏里是 "appKey:appSecret"
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let appKey = parts[0]
        let appSecret = parts[1]

        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api") else { return nil }

        let curtime = String(Int(now.timeIntervalSince1970))
        let sign = youdaoSign(appKey: appKey, query: text, salt: salt, curtime: curtime, appSecret: appSecret)

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: youdaoLanguage(targetLanguage)),
            URLQueryItem(name: "appKey", value: appKey),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "signType", value: "v3"),
            URLQueryItem(name: "curtime", value: curtime),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }
        return ProviderRequest(url: url,
                               headers: ["Content-Type": "application/x-www-form-urlencoded"],
                               body: body)
    }

    static func parseYoudao(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderOutcome.failure("有道返回格式不认识")
        }
        let code = (json["errorCode"] as? String) ?? "0"
        guard code == "0" else {
            return ProviderOutcome.failure("有道错误码 \(code)：\(youdaoErrorText(code))")
        }
        guard let list = json["translation"] as? [String], let first = list.first, !first.isEmpty else {
            return ProviderOutcome.failure("有道没给译文")
        }
        return ProviderOutcome.success(first)
    }

    /// 常见错误码给一句人话，别的直接报码
    static func youdaoErrorText(_ code: String) -> String {
        switch code {
        case "101": return "缺参数"
        case "102": return "不支持的语言"
        case "108": return "应用 ID 无效"
        case "110": return "无相关服务"
        case "202": return "签名校验失败，检查 appSecret"
        case "203": return "访问 IP 不在白名单"
        case "206": return "时间戳无效"
        case "207": return "重放请求"
        case "302": return "翻译失败"
        case "401": return "账户已欠费"
        case "411": return "访问频率受限"
        default: return "未知错误"
        }
    }
}
import CryptoKit

/// 摘要计算单独放一处：有道签名要 SHA256
enum ProviderDigest {
    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256Data(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hmacSHA256Hex(key: Data, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 百度 / 腾讯 / 谷歌

extension ProviderCodec {

    // MARK: 语言码（三家共用一套小写映射）
    static func simpleLanguage(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh-CN": return "zh"
        case "zh-Hant", "zh-TW": return "cht"
        case let other where other.hasPrefix("zh"): return "zh"
        default: return String(code.prefix(2)).lowercased()
        }
    }

    // MARK: 百度
    //
    // 密钥栏填 "appid:key"，签名为 MD5(appid + q + salt + key)。
    static func baiduRequest(text: String, targetLanguage: String, key: String,
                            baseURL: String, salt: String = "12345") -> ProviderRequest? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let appid = parts[0]
        let secret = parts[1]

        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/trans/vip/translate") else { return nil }

        let to = targetLanguage.hasPrefix("zh-Hant") || targetLanguage.hasPrefix("zh-TW") ? "cht" : "zh"
        let sign = md5Hex(appid + text + salt + secret)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "appid", value: appid),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }
        return ProviderRequest(url: url,
                               headers: ["Content-Type": "application/x-www-form-urlencoded"],
                               body: body)
    }

    static func md5Hex(_ input: String) -> String {
        ProviderDigest.md5Hex(input)
    }

    static func parseBaidu(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("百度返回格式不认识")
        }
        if let code = json["error_code"] as? String, code != "0" {
            let message = (json["error_msg"] as? String) ?? "未知错误"
            return .failure("百度错误 \(code)：\(message)")
        }
        guard let list = json["trans_result"] as? [[String: Any]],
              let first = list.first,
              let dst = first["dst"] as? String else {
            return .failure("百度没给译文")
        }
        return .success(list.compactMap { $0["dst"] as? String }.joined(separator: "\n"))
    }

    // MARK: 腾讯
    //
    // TC3-HMAC-SHA256。密钥栏填 "secretId:secretKey"。
    // 这个签名链是官方文档里的固定套路：日期 → 服务 → 请求串 → 签名 → 授权头。
    static func tencentRequest(text: String, targetLanguage: String, key: String,
                               baseURL: String, now: Date = Date()) -> ProviderRequest? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let secretID = parts[0]
        let secretKey = parts[1]

        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/") else { return nil }

        let payload: [String: Any] = [
            "SourceText": text,
            "Source": "auto",
            "Target": simpleLanguage(targetLanguage),
            "ProjectId": 0,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let timestamp = Int(now.timeIntervalSince1970)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let date = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        let host = url.host ?? "tmt.tencentcloudapi.com"
        let contentType = "application/json; charset=utf-8"
        let signedHeaders = "content-type;host"
        let canonicalRequest = [
            "POST", "/", "",
            "content-type:\(contentType)\nhost:\(host)\n",
            signedHeaders,
            ProviderDigest.sha256Hex(String(data: body, encoding: .utf8) ?? ""),
        ].joined(separator: "\n")

        let service = "tmt"
        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            String(timestamp),
            credentialScope,
            ProviderDigest.sha256Hex(canonicalRequest),
        ].joined(separator: "\n")

        let secretDate = ProviderDigest.hmacSHA256Hex(key: ("TC3" + secretKey).data(using: .utf8)!, message: date)
        let secretService = ProviderDigest.hmacSHA256Hex(key: secretDate.data(using: .utf8)!, message: service)
        let secretSigning = ProviderDigest.hmacSHA256Hex(key: secretService.data(using: .utf8)!, message: "tc3_request")
        let signature = ProviderDigest.hmacSHA256Hex(key: secretSigning.data(using: .utf8)!, message: stringToSign)

        let authorization = "TC3-HMAC-SHA256 Credential=\(secretID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return ProviderRequest(url: url,
                               headers: [
                                "Content-Type": contentType,
                                "Host": host,
                                "Authorization": authorization,
                                "X-TC-Action": "TextTranslate",
                                "X-TC-Version": "2018-03-21",
                                "X-TC-Timestamp": String(timestamp),
                                "X-TC-Region": "ap-guangzhou",
                               ],
                               body: body)
    }

    static func parseTencent(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("腾讯返回格式不认识")
        }
        if let response = json["Response"] as? [String: Any] {
            if let error = response["Error"] as? [String: Any] {
                let code = (error["Code"] as? String) ?? "?"
                let message = (error["Message"] as? String) ?? "未知错误"
                return .failure("腾讯错误 \(code)：\(message)")
            }
            if let target = response["TargetText"] as? String, !target.isEmpty {
                return .success(target)
            }
        }
        return .failure("腾讯没给译文")
    }

    // MARK: 谷歌
    //
    // 免费接口，不需要密钥。返回是嵌套数组，译文藏在 [0][n][0]。
    //
    // `sl` 以前写死 `auto`，结果「英文教材里夹几句中文」被谷歌判成中文段，
    // 直接把原文原样吐回来（看起来就是"没翻译"）。这里显式告诉它我们检测到的源语种。
    static func googleRequest(text: String, targetLanguage: String, baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + "/translate_a/single")
        let detected = LanguageDetector.detectLanguage(text)
        let sourceCode: String
        switch LanguageDetector.baseCode(detected) {
        case "zh": sourceCode = detected.hasPrefix("zh-Hant") ? "zh-TW" : "zh-CN"
        case "en": sourceCode = "en"
        case "ja": sourceCode = "ja"
        case "ko": sourceCode = "ko"
        default: sourceCode = "auto"
        }
        var items = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sourceCode),
            URLQueryItem(name: "tl", value: targetLanguage.hasPrefix("zh-Hant") ? "zh-TW" : simpleLanguage(targetLanguage)),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        _ = items
        return ProviderRequest(url: url, headers: [:], body: Data())
    }

    static func parseGoogle(_ data: Data) -> ProviderOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            return .failure("谷歌返回格式不认识")
        }
        var pieces: [String] = []
        for segment in segments {
            if let pair = segment as? [Any], let text = pair.first as? String {
                pieces.append(text)
            }
        }
        let joined = pieces.joined()
        guard !joined.isEmpty else { return .failure("谷歌没给译文") }
        return .success(joined)
    }
}


// MARK: - Claude / Gemini / Microsoft / 彩云 / 小牛

extension ProviderCodec {

    // MARK: Claude（Anthropic Messages）
    //
    // 和 OpenAI 的差别：x-api-key 而不是 Bearer，要 anthropic-version，
    // 返回是 content 数组而不是 choices。
    static func claudeRequest(text: String, targetLanguage: String, key: String,
                              model: String, baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/messages") else { return nil }
        let payload: [String: Any] = [
            "model": model.isEmpty ? "claude-3-5-sonnet-latest" : model,
            "max_tokens": 4096,
            "system": "Translate the user's text into \(Languages.promptName(for: targetLanguage)). Output only the translation.",
            "messages": [["role": "user", "content": text]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return ProviderRequest(url: url,
                               headers: ["Content-Type": "application/json",
                                         "x-api-key": key,
                                         "anthropic-version": "2023-06-01"],
                               body: body)
    }

    static func parseClaude(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Claude 返回格式不认识")
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return .failure("Claude：\(message)")
        }
        guard let blocks = json["content"] as? [[String: Any]] else {
            return .failure("Claude 没给内容")
        }
        let texts = blocks.compactMap { $0["text"] as? String }
        let joined = texts.joined()
        guard !joined.isEmpty else { return .failure("Claude 没给译文") }
        return .success(joined)
    }

    // MARK: Gemini（generateContent）
    //
    // key 放在 query 里，模型名放在路径里，返回 candidates[0].content.parts[0].text
    static func geminiRequest(text: String, targetLanguage: String, key: String,
                              model: String, baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        let modelName = model.isEmpty ? "gemini-2.0-flash" : model
        guard var components = URLComponents(string: base + "/v1beta/models/\(modelName):generateContent") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { return nil }

        let payload: [String: Any] = [
            "contents": [["parts": [["text": "Translate into \(Languages.promptName(for: targetLanguage)). Output only the translation:\n\n" + text]]]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return ProviderRequest(url: url, headers: ["Content-Type": "application/json"], body: body)
    }

    static func parseGemini(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Gemini 返回格式不认识")
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return .failure("Gemini：\(message)")
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return .failure("Gemini 没给内容")
        }
        let joined = parts.compactMap { $0["text"] as? String }.joined()
        guard !joined.isEmpty else { return .failure("Gemini 没给译文") }
        return .success(joined)
    }

    // MARK: Microsoft（Azure Translator）
    //
    // 密钥栏填 "密钥@区域"，比如 "abc123@eastasia"（区域可省）
    static func microsoftRequest(text: String, targetLanguage: String, key: String,
                                 baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        let to = targetLanguage.hasPrefix("zh-Hant") ? "zh-Hant" : simpleLanguage(targetLanguage)
        guard var components = URLComponents(string: base + "/translate") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: to == "zh" ? "zh-Hans" : to),
        ]
        guard let url = components.url else { return nil }

        let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
        guard let subscriptionKey = parts.first, !subscriptionKey.isEmpty else { return nil }
        var headers = ["Content-Type": "application/json",
                       "Ocp-Apim-Subscription-Key": subscriptionKey]
        if parts.count == 2, !parts[1].isEmpty {
            headers["Ocp-Apim-Subscription-Region"] = parts[1]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: [["Text": text]]) else { return nil }
        return ProviderRequest(url: url, headers: headers, body: body)
    }

    static func parseMicrosoft(_ data: Data) -> ProviderOutcome {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure("Microsoft 返回格式不认识")
        }
        guard let translations = list.first?["translations"] as? [[String: Any]],
              let text = translations.first?["text"] as? String, !text.isEmpty else {
            return .failure("Microsoft 没给译文")
        }
        return .success(text)
    }

    // MARK: 彩云小译
    //
    // 密钥就是 token，放在 x-authorization 头里。
    static func caiyunRequest(text: String, targetLanguage: String, key: String,
                              baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/translator") else { return nil }
        let transType = targetLanguage.hasPrefix("zh") ? "auto2zh" : "auto2en"
        let payload: [String: Any] = ["source": [text], "trans_type": transType, "request_id": "lt"]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return ProviderRequest(url: url,
                               headers: ["Content-Type": "application/json", "x-authorization": key],
                               body: body)
    }

    static func parseCaiyun(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("彩云返回格式不认识")
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return .failure("彩云：\(message)")
        }
        guard let target = json["target"] as? [String], let first = target.first, !first.isEmpty else {
            return .failure("彩云没给译文")
        }
        return .success(target.joined())
    }

    // MARK: 小牛翻译
    //
    // 密钥栏填 "apikey"，from/to 用 zh/en 这种简码。
    static func niuRequest(text: String, targetLanguage: String, key: String,
                           baseURL: String) -> ProviderRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/NiuTransServer/translation") else { return nil }
        let to = targetLanguage.hasPrefix("zh") ? "zh" : simpleLanguage(targetLanguage)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "src_text", value: text),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "apikey", value: key),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }
        return ProviderRequest(url: url,
                               headers: ["Content-Type": "application/x-www-form-urlencoded"],
                               body: body)
    }

    static func parseNiu(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("小牛返回格式不认识")
        }
        if let code = json["error_code"] as? String, code != "0" {
            let message = (json["error_msg"] as? String) ?? "未知错误"
            return .failure("小牛错误 \(code)：\(message)")
        }
        guard let text = json["tgt_text"] as? String, !text.isEmpty else {
            return .failure("小牛没给译文")
        }
        return .success(text)
    }
}

// MARK: - Amazon Translate（SigV4）

extension ProviderCodec {

    /// 密钥栏填 "accessKeyId:secretAccessKey@区域"，区域可省（默认 us-east-1）
    static func amazonRequest(text: String, targetLanguage: String, key: String,
                              now: Date = Date()) -> ProviderRequest? {
        var region = "us-east-1"
        var credentialPart = key
        if let at = key.lastIndex(of: "@") {
            credentialPart = String(key[key.startIndex..<at])
            let candidate = String(key[key.index(after: at)...])
            if !candidate.isEmpty { region = candidate }
        }
        let parts = credentialPart.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let accessKey = parts[0]
        let secretKey = parts[1]

        guard let url = URL(string: "https://translate.\(region).amazonaws.com/") else { return nil }
        let target = "AWSShineFrontendService_20170701.TranslateText"
        let contentType = "application/x-amz-json-1.1"
        let host = url.host ?? "translate.\(region).amazonaws.com"

        let to: String
        if targetLanguage.hasPrefix("zh-Hant") { to = "zh-TW" }
        else if targetLanguage.hasPrefix("zh") { to = "zh" }
        else { to = String(targetLanguage.prefix(2)) }

        let payload: [String: Any] = [
            "Text": text,
            "SourceLanguageCode": "auto",
            "TargetLanguageCode": to,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        // SigV4 全程用 UTC
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        stampFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = stampFormatter.string(from: now)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyyMMdd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateStamp = dayFormatter.string(from: now)

        let canonicalHeaders = [
            "content-type:\(contentType)",
            "host:\(host)",
            "x-amz-date:\(amzDate)",
            "x-amz-target:\(target)",
        ].joined(separator: "\n") + "\n"
        let signedHeaders = "content-type;host;x-amz-date;x-amz-target"
        let canonicalRequest = [
            "POST", "/", "",
            canonicalHeaders,
            signedHeaders,
            ProviderDigest.sha256Hex(String(data: body, encoding: .utf8) ?? ""),
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/translate/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            ProviderDigest.sha256Hex(canonicalRequest)].joined(separator: "\n")

        let kSecret = ("AWS4" + secretKey).data(using: .utf8)!
        let kDate = ProviderDigest.hmacSHA256Data(key: kSecret, message: dateStamp)
        let kRegion = ProviderDigest.hmacSHA256Data(key: kDate, message: region)
        let kService = ProviderDigest.hmacSHA256Data(key: kRegion, message: "translate")
        let kSigning = ProviderDigest.hmacSHA256Data(key: kService, message: "aws4_request")
        let signature = ProviderDigest.hmacSHA256Data(key: kSigning, message: stringToSign)
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return ProviderRequest(url: url,
                               headers: ["Content-Type": contentType,
                                         "X-Amz-Date": amzDate,
                                         "X-Amz-Target": target,
                                         "Authorization": authorization],
                               body: body)
    }

    static func parseAmazon(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Amazon 返回格式不认识")
        }
        if let type = json["__type"] as? String {
            let message = (json["message"] as? String) ?? (json["Message"] as? String) ?? "未知错误"
            return .failure("Amazon：\(message)（\(type)）")
        }
        guard let text = json["TranslatedText"] as? String, !text.isEmpty else {
            return .failure("Amazon 没给译文")
        }
        return .success(text)
    }

    // MARK: MyMemory (免费开放翻译 API，免密钥)

    static func mymemoryRequest(text: String, targetLanguage: String, baseURL: String, key: String = "") -> ProviderRequest? {
        var base = baseURL.isEmpty ? "https://api.mymemory.translated.net" : baseURL
        while base.hasSuffix("/") { base.removeLast() }

        let detected = LanguageDetector.detectLanguage(text)
        let fromCode: String
        switch detected {
        case "zh-Hans", "zh-Hant", "zh-CN", "zh-TW": fromCode = "zh-CN"
        case "ja": fromCode = "ja"
        case "ko": fromCode = "ko"
        default: fromCode = "en"
        }

        let toCode: String
        if targetLanguage.hasPrefix("zh-Hant") || targetLanguage == "zh-TW" {
            toCode = "zh-TW"
        } else if targetLanguage.hasPrefix("zh") {
            toCode = "zh-CN"
        } else {
            toCode = simpleLanguage(targetLanguage)
        }
        let effectiveFrom = (fromCode == toCode) ? (toCode.hasPrefix("zh") ? "en" : "zh-CN") : fromCode

        var components = URLComponents(string: base + "/get")
        var items = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(effectiveFrom)|\(toCode)")
        ]
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "de", value: key.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        return ProviderRequest(url: url, headers: [:], body: Data())
    }

    static func parseMyMemory(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("MyMemory 返回格式不认识")
        }
        if let status = json["responseStatus"] as? Int, status != 200 {
            let details = (json["responseDetails"] as? String) ?? "未知错误"
            return .failure("MyMemory \(status)：\(details)")
        }
        guard let responseData = json["responseData"] as? [String: Any],
              let translated = responseData["translatedText"] as? String, !translated.isEmpty else {
            return .failure("MyMemory 没给译文")
        }
        return .success(translated)
    }
}
