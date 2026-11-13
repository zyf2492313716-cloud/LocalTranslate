import Foundation

/// 火山引擎的两条接口。
///
/// OCR 走 V4 签名（`VolcSigner` 已用官方测试向量逐字节验过），
/// 语音合成走豆包语音那套 `Bearer;<token>` + appid/cluster，两套鉴权完全不同。
///
/// 接口常量（host / service / Action / Version）按公开接口写，
/// **没有真 key 没在真服务器上跑过**——这点在 README 里写明。
enum VolcEngines {

    // MARK: OCR
    //
    // 密钥格式：accessKey:secretKey
    struct OcrConfig {
        var accessKey: String
        var secretKey: String
        var region: String = "cn-north-1"
    }

    static func parseOcrKey(_ key: String) -> OcrConfig? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return OcrConfig(accessKey: parts[0], secretKey: parts[1])
    }

    static func ocrRequest(imageBase64: String, key: String, now: Date = Date()) -> OcrRequest? {
        guard let config = parseOcrKey(key) else { return nil }
        let host = "visual.volcengineapi.com"
        let service = "cv"
        let region = config.region
        let action = "OCRNormal"
        let version = "2020-08-26"

        guard var components = URLComponents(string: "https://\(host)/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "Action", value: action),
            URLQueryItem(name: "Version", value: version),
        ]
        guard let url = components.url else { return nil }

        let body = (try? JSONSerialization.data(withJSONObject: ["image_base64": imageBase64])) ?? Data()
        let auth = VolcSigner.authorization(
            accessKey: config.accessKey, secretKey: config.secretKey,
            method: "POST", host: host, path: "/",
            query: [("Action", action), ("Version", version)],
            body: body, region: region, service: service, date: now)

        return OcrRequest(url: url, headers: [
            "Content-Type": "application/json",
            "X-Date": VolcSigner.amzDate(now),
            "Authorization": auth,
        ], body: body)
    }

    static func parseOcr(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("火山 OCR 返回格式不认识")
        }
        if let code = json["code"] as? Int, code != 10000 {
            let message = (json["message"] as? String) ?? "未知错误"
            return .failure("火山 OCR 错误 \(code)：\(message)")
        }
        guard let payload = json["data"] as? [String: Any] else {
            return .failure("火山 OCR 没给内容")
        }
        if let lines = payload["line_texts"] as? [String], !lines.isEmpty {
            return .success(lines.joined(separator: "\n"))
        }
        if let text = payload["text"] as? String, !text.isEmpty {
            return .success(text)
        }
        return .failure("火山 OCR：这张图里没识别到文字")
    }

    // MARK: 语音合成（豆包语音）
    //
    // 密钥格式：appid:token（可选再跟 @cluster，默认 volcano_tts）
    static func parseTtsKey(_ key: String) -> (appid: String, token: String, cluster: String)? {
        var cluster = "volcano_tts"
        var body = key
        if let at = key.lastIndex(of: "@") {
            body = String(key[key.startIndex..<at])
            let candidate = String(key[key.index(after: at)...])
            if !candidate.isEmpty { cluster = candidate }
        }
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1], cluster)
    }

    static func ttsRequest(text: String, key: String, targetLanguage: String) -> TtsRequest? {
        guard let config = parseTtsKey(key),
              let url = URL(string: "https://openspeech.bytedance.com/api/v1/tts") else { return nil }

        let voice = targetLanguage.hasPrefix("zh") ? "zh_female_shuangkuaisisi_moon_bigtts"
                                                : "en_female_amanda_mars_bigtts"
        let payload: [String: Any] = [
            "app": ["appid": config.appid, "token": config.token, "cluster": config.cluster],
            "user": ["uid": "localtranslate"],
            "audio": ["voice_type": voice, "encoding": "mp3", "speed_ratio": Config.shared.speechRate],
            "request": ["reqid": UUID().uuidString, "text": text, "operation": "query"],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return TtsRequest(url: url,
                          headers: ["Content-Type": "application/json",
                                    "Authorization": "Bearer;\(config.token)"],
                          body: body)
    }

    /// 返回 base64 音频
    static func parseTts(_ data: Data) -> ProviderOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("火山 TTS 返回格式不认识")
        }
        if let code = json["code"] as? Int, code != 3000 {
            let message = (json["message"] as? String) ?? "未知错误"
            return .failure("火山 TTS 错误 \(code)：\(message)")
        }
        guard let audio = json["data"] as? String, !audio.isEmpty else {
            return .failure("火山 TTS 没给音频")
        }
        return .success(audio)
    }
}
