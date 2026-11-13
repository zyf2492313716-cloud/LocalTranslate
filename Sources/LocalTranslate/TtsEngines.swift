import AppKit
import AVFoundation

/// 语音合成引擎。系统合成是默认（离线、免 key），云端音色更好听。
///
/// 和 OCR 一样：请求构造与响应解析是纯函数，离线能验；
/// 真正播放交给 AVAudioPlayer。
enum TtsEngine: String, CaseIterable {
    case system
    case edge
    case google
    case microsoft
    case tencent
    case volcengine

    var title: String {
        switch self {
        case .system: return "系统语音（离线，免 key）"
        case .edge: return "Microsoft Edge（免 Key，大声朗读）"
        case .google: return "Google Cloud TTS"
        case .microsoft: return "Microsoft 语音"
        case .tencent: return "腾讯云语音"
        case .volcengine: return "火山语音（豆包）"
        }
    }

    var needsKey: Bool {
        switch self {
        case .system, .edge: return false
        default: return true
        }
    }

    var keyHint: String {
        switch self {
        case .system, .edge: return ""
        case .google: return "API Key"
        case .microsoft: return "订阅密钥@区域"
        case .tencent: return "secretId:secretKey"
        case .volcengine: return "appid:token@cluster"
        }
    }

    var keyAccount: String { "tts-" + rawValue }
}

struct TtsRequest {
    var url: URL
    var headers: [String: String]
    var body: Data
}

enum TtsCodec {

    /// 目标语言的 BCP-47 码
    static func languageCode(_ code: String) -> String {
        code.hasPrefix("zh-Hant") ? "zh-TW" : (code.hasPrefix("zh") ? "zh-CN" : String(code.prefix(2)) + "-" + String(code.prefix(2)).uppercased())
    }

    // MARK: Microsoft Edge 大声朗读 (免 Key，基于 Bing Speech 端点与官方客户端令牌)
    static func edgeRequest(text: String, targetLanguage: String) -> TtsRequest? {
        let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        guard let url = URL(string: "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?trustedclienttoken=\(token)") else { return nil }

        let lang = languageCode(targetLanguage)
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let voice = lang.hasPrefix("zh") ? "zh-CN-XiaoxiaoNeural" : "en-US-JennyNeural"
        let ssml = """
        <speak version='1.0' xml:lang='\(lang)'><voice xml:lang='\(lang)' name='\(voice)'>\(escaped)</voice></speak>
        """
        guard let body = ssml.data(using: .utf8) else { return nil }
        return TtsRequest(url: url,
                          headers: [
                            "Content-Type": "application/ssml+xml",
                            "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
                            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
                          ],
                          body: body)
    }

    static func parseEdge(_ data: Data) -> ProviderOutcome {
        guard data.count > 100 else {
            return .failure("Edge TTS 返回内容异常（\(data.count) 字节）")
        }
        return .success(data.base64EncodedString())
    }

    // MARK: Google
    static func googleRequest(text: String, targetLanguage: String, key: String,
                              baseURL: String = "https://texttospeech.googleapis.com") -> TtsRequest? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/v1/text:synthesize?key=\(key)") else { return nil }
        let payload: [String: Any] = [
            "input": ["text": text],
            "voice": ["languageCode": languageCode(targetLanguage)],
            "audioConfig": ["audioEncoding": "MP3", "speakingRate": Config.shared.speechRate],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return TtsRequest(url: url, headers: ["Content-Type": "application/json"], body: body)
    }

    /// 返回 base64 音频
    static func parseGoogle(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Google TTS 返回格式不认识")
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return .failure("Google TTS：\(message)")
        }
        guard let audio = json["audioContent"] as? String, !audio.isEmpty else {
            return .failure("Google TTS 没给音频")
        }
        return .success(audio)
    }

    // MARK: Microsoft
    //
    // 订阅密钥直接放在头里，body 是 SSML。返回的是音频字节，不是 JSON。
    static func microsoftRequest(text: String, targetLanguage: String, key: String) -> TtsRequest? {
        let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
        guard let subscriptionKey = parts.first, !subscriptionKey.isEmpty else { return nil }
        let region = parts.count == 2 ? parts[1] : "eastasia"
        let lang = languageCode(targetLanguage)
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else { return nil }

        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let voice = lang.hasPrefix("zh") ? "zh-CN-XiaoxiaoNeural" : "en-US-JennyNeural"
        let ssml = """
        <speak version='1.0' xml:lang='\(lang)'><voice xml:lang='\(lang)' name='\(voice)'>\(escaped)</voice></speak>
        """
        guard let body = ssml.data(using: .utf8) else { return nil }
        return TtsRequest(url: url,
                          headers: ["Content-Type": "application/ssml+xml",
                                    "X-Microsoft-OutputFormat": "audio-16khz-64kbitrate-mono-mp3",
                                    "Ocp-Apim-Subscription-Key": subscriptionKey],
                          body: body)
    }

    /// Microsoft 直接回音频字节，没有 JSON 可解；这里只判空
    static func parseMicrosoft(_ data: Data) -> ProviderOutcome {
        guard data.count > 512 else {
            return .failure("Microsoft TTS 返回的内容不像音频（\(data.count) 字节），检查密钥和区域")
        }
        return .success(data.base64EncodedString())
    }

    // MARK: 腾讯
    //
    // 复用 TC3 签名，Action 是 TextToVoice。
    static func tencentRequest(text: String, targetLanguage: String, key: String,
                               now: Date = Date()) -> TtsRequest? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let url = URL(string: "https://tts.tencentcloudapi.com/") else { return nil }
        let secretID = parts[0]
        let secretKey = parts[1]

        let payload: [String: Any] = [
            "Text": text,
            "SessionId": UUID().uuidString,
            "Volume": 0,
            "Speed": 0,
            "ProjectId": 0,
            "ModelType": 1,
            "VoiceType": targetLanguage.hasPrefix("zh") ? 101001 : 1051,
            "PrimaryLanguage": targetLanguage.hasPrefix("zh") ? 1 : 2,
            "SampleRate": 16000,
            "Codec": "mp3",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        let timestamp = Int(now.timeIntervalSince1970)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        let host = "tts.tencentcloudapi.com"
        let contentType = "application/json; charset=utf-8"
        let signedHeaders = "content-type;host"
        let canonicalRequest = [
            "POST", "/", "",
            "content-type:\(contentType)\nhost:\(host)\n",
            signedHeaders,
            ProviderDigest.sha256Hex(String(data: body, encoding: .utf8) ?? ""),
        ].joined(separator: "\n")
        let credentialScope = "\(date)/tts/tc3_request"
        let stringToSign = ["TC3-HMAC-SHA256", String(timestamp), credentialScope,
                            ProviderDigest.sha256Hex(canonicalRequest)].joined(separator: "\n")
        let kDate = ProviderDigest.hmacSHA256Hex(key: ("TC3" + secretKey).data(using: .utf8)!, message: date)
        let kService = ProviderDigest.hmacSHA256Hex(key: kDate.data(using: .utf8)!, message: "tts")
        let kSigning = ProviderDigest.hmacSHA256Hex(key: kService.data(using: .utf8)!, message: "tc3_request")
        let signature = ProviderDigest.hmacSHA256Hex(key: kSigning.data(using: .utf8)!, message: stringToSign)

        return TtsRequest(url: url, headers: [
            "Content-Type": contentType,
            "Host": host,
            "Authorization": "TC3-HMAC-SHA256 Credential=\(secretID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            "X-TC-Action": "TextToVoice",
            "X-TC-Version": "2019-08-23",
            "X-TC-Timestamp": String(timestamp),
            "X-TC-Region": "ap-guangzhou",
        ], body: body)
    }

    static func parseTencent(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["Response"] as? [String: Any] else {
            return .failure("腾讯 TTS 返回格式不认识")
        }
        if let error = response["Error"] as? [String: Any] {
            return .failure("腾讯 TTS：\((error["Message"] as? String) ?? "未知错误")")
        }
        guard let audio = response["Audio"] as? String, !audio.isEmpty else {
            return .failure("腾讯 TTS 没给音频")
        }
        return .success(audio)
    }
}
