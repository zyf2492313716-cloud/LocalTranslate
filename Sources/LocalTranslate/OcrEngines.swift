import AppKit

/// 截图取字用的 OCR 引擎。
///
/// 系统 Vision 是默认（离线、免 key、够用）。云端引擎在两种情况下有用：
/// 手写体/复杂排版认不出，或者想要更好的中文断行。
///
/// 请求构造与响应解析都做成纯函数，离线就能验，不需要真 key。
enum OcrEngine: String, CaseIterable {
    case system
    case llm
    case google
    case youdao
    case tencent
    case baidu
    case volcengine

    var title: String {
        switch self {
        case .system: return "系统 Vision（离线，免 key）"
        case .llm: return "大模型 OCR (LLM Vision)"
        case .google: return "Google Cloud Vision"
        case .youdao: return "有道 OCR"
        case .tencent: return "腾讯 OCR"
        case .baidu: return "百度 OCR"
        case .volcengine: return "火山 OCR"
        }
    }

    var needsKey: Bool { self != .system && self != .llm }

    var keyHint: String {
        switch self {
        case .system, .llm: return ""
        case .google: return "API Key"
        case .youdao: return "appKey:appSecret"
        case .tencent: return "secretId:secretKey"
        case .baidu: return "apiKey:secretKey"
        case .volcengine: return "accessKey:secretKey"
        }
    }

    /// 密钥在钥匙串里的账户名
    var keyAccount: String { "ocr-" + rawValue }
}

struct OcrRequest {
    var url: URL
    var headers: [String: String]
    var body: Data
}

enum OcrCodec {

    static func base64(_ image: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: 大模型多模态 OCR (OpenAI 兼容 image_url 视觉协议)
    static func llmRequest(image: CGImage, profile: ServiceProfile, key: String) -> OcrRequest? {
        guard let b64 = base64(image),
              let url = URL(string: profile.chatEndpoint) else { return nil }

        let payload: [String: Any] = [
            "model": profile.model.isEmpty ? "gpt-4o-mini" : profile.model,
            "messages": [
                [
                    "role": "system",
                    "content": "你是一个高精度的文字识别(OCR)助手。请严格识别并提取图片中的所有文字，原样保留排版、标点与换行。直接输出识别出的文字正文，不要包含任何打招呼、前言、解释或代码围栏。"
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "请提取这张图片中的所有文字。"],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
                    ]
                ]
            ],
            "stream": false
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var headers = ["Content-Type": "application/json"]
        if !key.isEmpty && key != "-" {
            headers["Authorization"] = "Bearer \(key)"
        }
        return OcrRequest(url: url, headers: headers, body: body)
    }

    static func parseLLM(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("大模型 OCR 返回格式不认识")
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            return .failure("大模型 OCR：\(msg)")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return .failure("大模型 OCR 没给内容")
        }
        let cleaned = TranslationDiagnostics.sanitize(content).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? .failure("大模型 OCR：这张图里没识别到文字") : .success(cleaned)
    }

    // MARK: Google Cloud Vision
    //
    // 一次请求一张图，返回 responses[0].fullTextAnnotation.text。
    static func googleRequest(image: CGImage, key: String) -> OcrRequest? {
        guard let b64 = base64(image),
              let url = URL(string: "https://vision.googleapis.com/v1/images:annotate?key=\(key)") else { return nil }
        let payload: [String: Any] = [
            "requests": [[
                "image": ["content": b64],
                "features": [["type": "TEXT_DETECTION"]],
            ]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return OcrRequest(url: url, headers: ["Content-Type": "application/json"], body: body)
    }

    static func parseGoogle(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Google OCR 返回格式不认识")
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return .failure("Google OCR：\(message)")
        }
        guard let responses = json["responses"] as? [[String: Any]] else {
            return .failure("Google OCR 没给内容")
        }
        guard let first = responses.first else { return .failure("Google OCR 没给内容") }
        if let annotation = first["fullTextAnnotation"] as? [String: Any],
           let text = annotation["text"] as? String, !text.isEmpty {
            return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // 没有整段时退回逐行拼接
        if let annotations = first["textAnnotations"] as? [[String: Any]] {
            let lines = annotations.compactMap { $0["description"] as? String }
            let joined = lines.dropFirst().joined(separator: "\n")
            if !joined.isEmpty { return .success(joined) }
        }
        return .failure("Google OCR：这张图里没识别到文字")
    }

    // MARK: 有道 OCR
    //
    // 和它有道翻译同一套 v3 签名，字段名换成 img（base64）。
    static func youdaoRequest(image: CGImage, key: String, now: Date = Date(),
                              salt: String = "12345") -> OcrRequest? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let b64 = base64(image),
              let url = URL(string: "https://openapi.youdao.com/ocrapi") else { return nil }
        let appKey = parts[0]
        let appSecret = parts[1]
        let curtime = String(Int(now.timeIntervalSince1970))
        let sign = ProviderCodec.youdaoSign(appKey: appKey, query: b64, salt: salt,
                                           curtime: curtime, appSecret: appSecret)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "img", value: b64),
            URLQueryItem(name: "langType", value: "auto"),
            URLQueryItem(name: "detectType", value: "10012"),
            URLQueryItem(name: "imageType", value: "1"),
            URLQueryItem(name: "appKey", value: appKey),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "signType", value: "v3"),
            URLQueryItem(name: "curtime", value: curtime),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }
        return OcrRequest(url: url,
                          headers: ["Content-Type": "application/x-www-form-urlencoded"],
                          body: body)
    }

    static func parseYoudao(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("有道 OCR 返回格式不认识")
        }
        if let code = json["errorCode"] as? String, code != "0" {
            return .failure("有道 OCR 错误 \(code)")
        }
        guard let result = json["Result"] as? [String: Any],
              let regions = result["regions"] as? [[String: Any]] else {
            return .failure("有道 OCR 没给内容")
        }
        var lines: [String] = []
        for region in regions {
            guard let regionLines = region["lines"] as? [[String: Any]] else { continue }
            for line in regionLines {
                lines.append(line["text"] as? String ?? "")
            }
        }
        let joined = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? .failure("有道 OCR：这张图里没识别到文字") : .success(joined)
    }

    // MARK: 百度 OCR
    //
    // 两步：先用 apiKey:secretKey 换 access_token（有效期约 30 天），再拿 token 识别。
    // token 缓存在内存里，过期前不重复换——不然每张截图都要多一次网络往返。

    static func baiduTokenRequest(key: String) -> URLRequest? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        guard var components = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: parts[0]),
            URLQueryItem(name: "client_secret", value: parts[1]),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        return request
    }

    /// 返回 access_token
    static func parseBaiduToken(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("百度 token 返回格式不认识")
        }
        if let error = json["error"] as? String {
            let description = (json["error_description"] as? String) ?? error
            return .failure("百度 token 失败：\(description)")
        }
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            return .failure("百度没给 access_token")
        }
        return .success(token)
    }

    static func baiduOcrRequest(image: CGImage, token: String) -> OcrRequest? {
        guard let b64 = base64(image),
              let url = URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic?access_token=\(token)") else {
            return nil
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "image", value: b64),
            URLQueryItem(name: "detect_language", value: "true"),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }
        return OcrRequest(url: url,
                          headers: ["Content-Type": "application/x-www-form-urlencoded"],
                          body: body)
    }

    static func parseBaidu(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("百度 OCR 返回格式不认识")
        }
        if let code = json["error_code"] as? Int {
            let message = (json["error_msg"] as? String) ?? "未知错误"
            return .failure("百度 OCR 错误 \(code)：\(message)")
        }
        guard let results = json["words_result"] as? [[String: Any]] else {
            return .failure("百度 OCR 没给内容")
        }
        let lines = results.compactMap { $0["words"] as? String }.filter { !$0.isEmpty }
        return lines.isEmpty ? .failure("百度 OCR：这张图里没识别到文字") : .success(lines.joined(separator: "\n"))
    }

    // MARK: 腾讯 OCR
    //
    // 复用文本翻译那套 TC3 签名，只是 Action 换成 GeneralBasicOCR。
    static func tencentRequest(image: CGImage, key: String, now: Date = Date()) -> OcrRequest? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let b64 = base64(image),
              let url = URL(string: "https://ocr.tencentcloudapi.com/") else { return nil }
        let secretID = parts[0]
        let secretKey = parts[1]
        guard let body = try? JSONSerialization.data(withJSONObject: ["ImageBase64": b64]) else { return nil }

        let timestamp = Int(now.timeIntervalSince1970)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        let host = "ocr.tencentcloudapi.com"
        let contentType = "application/json; charset=utf-8"
        let signedHeaders = "content-type;host"
        let canonicalRequest = [
            "POST", "/", "",
            "content-type:\(contentType)\nhost:\(host)\n",
            signedHeaders,
            ProviderDigest.sha256Hex(String(data: body, encoding: .utf8) ?? ""),
        ].joined(separator: "\n")
        let credentialScope = "\(date)/ocr/tc3_request"
        let stringToSign = ["TC3-HMAC-SHA256", String(timestamp), credentialScope,
                            ProviderDigest.sha256Hex(canonicalRequest)].joined(separator: "\n")
        let kDate = ProviderDigest.hmacSHA256Hex(key: ("TC3" + secretKey).data(using: .utf8)!, message: date)
        let kService = ProviderDigest.hmacSHA256Hex(key: kDate.data(using: .utf8)!, message: "ocr")
        let kSigning = ProviderDigest.hmacSHA256Hex(key: kService.data(using: .utf8)!, message: "tc3_request")
        let signature = ProviderDigest.hmacSHA256Hex(key: kSigning.data(using: .utf8)!, message: stringToSign)

        return OcrRequest(url: url, headers: [
            "Content-Type": contentType,
            "Host": host,
            "Authorization": "TC3-HMAC-SHA256 Credential=\(secretID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            "X-TC-Action": "GeneralBasicOCR",
            "X-TC-Version": "2018-11-19",
            "X-TC-Timestamp": String(timestamp),
            "X-TC-Region": "ap-guangzhou",
        ], body: body)
    }

    static func parseTencent(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["Response"] as? [String: Any] else {
            return .failure("腾讯 OCR 返回格式不认识")
        }
        if let error = response["Error"] as? [String: Any] {
            return .failure("腾讯 OCR：\((error["Message"] as? String) ?? "未知错误")")
        }
        guard let results = response["TextDetections"] as? [[String: Any]] else {
            return .failure("腾讯 OCR 没给内容")
        }
        let lines = results.compactMap { $0["DetectedText"] as? String }.filter { !$0.isEmpty }
        return lines.isEmpty ? .failure("腾讯 OCR：这张图里没识别到文字") : .success(lines.joined(separator: "\n"))
    }
}
