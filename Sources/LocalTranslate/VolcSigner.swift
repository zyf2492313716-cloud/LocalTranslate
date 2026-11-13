import Foundation

/// 火山引擎 V4 签名。
///
/// 和 AWS SigV4 很像但有几处关键差异（照官方文档实现）：
/// - 算法名是 `HMAC-SHA256`，不是 `AWS4-HMAC-SHA256`
/// - 派生密钥时密钥是**十六进制字符串**，不是原始字节；也不加 `AWS4` 前缀
/// - CredentialScope 结尾是 `request`，不是 `aws4_request`
/// - 参与签名的 Header 至少要有 `host` 和 `x-date`
///
/// 文档给了标准测试向量，`--selftest volc-sign` 会逐段比对——
/// 签名对不对不靠猜，对得上文档算出来的十六进制值才算过关。
enum VolcSigner {

    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func dateStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func sha256Hex(_ string: String) -> String {
        ProviderDigest.sha256Hex(string)
    }

    /// 第一步：密钥是 Secret Key 的原文字节
    static func hmacHex(key: String, message: String) -> String {
        ProviderDigest.hmacSHA256Hex(key: Data(key.utf8), message: message)
    }

    /// 后续步骤：密钥是上一步十六进制摘要**解码后的字节**。
    /// 文档里说「作为 Hex 类型的密钥」有歧义，实测必须解码——
    /// 用字符串当密钥算出来的 kRegion 和文档给的值对不上。
    static func hmacHexDecodedKey(_ hexKey: String, message: String) -> String {
        var bytes = [UInt8]()
        var index = hexKey.startIndex
        while index < hexKey.endIndex {
            let next = hexKey.index(index, offsetBy: 2, limitedBy: hexKey.endIndex) ?? hexKey.endIndex
            if let byte = UInt8(hexKey[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return ProviderDigest.hmacSHA256Hex(key: Data(bytes), message: message)
    }

    /// 派生签名密钥，四步。返回每一步的值，方便自测逐段比对。
    static func signingKey(secretKey: String, date: String, region: String, service: String)
        -> (kDate: String, kRegion: String, kService: String, kSigning: String) {
        let kDate = hmacHex(key: secretKey, message: date)
        let kRegion = hmacHexDecodedKey(kDate, message: region)
        let kService = hmacHexDecodedKey(kRegion, message: service)
        let kSigning = hmacHexDecodedKey(kService, message: "request")
        return (kDate, kRegion, kService, kSigning)
    }

    /// 完整计算签名，返回可直接放进 Authorization 头的字符串
    static func authorization(accessKey: String, secretKey: String,
                              method: String, host: String, path: String = "/",
                              query: [(String, String)] = [],
                              body: Data = Data(),
                              region: String, service: String,
                              date: Date, extraHeaders: [String: String] = [:]) -> String {

        let stamp = amzDate(date)
        let day = dateStamp(date)

        // 规范化查询串：按参数名 ASCII 升序
        let canonicalQuery = query
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        // 参与签名的头：host 和 x-date 必须有
        var headers = extraHeaders
        headers["host"] = host
        headers["x-date"] = stamp
        // 统一转小写后再排序，方便按下标取值
        var lowered: [String: String] = [:]
        for (name, value) in headers {
            lowered[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let sortedNames = lowered.keys.sorted()
        let canonicalHeaders = sortedNames.map { "\($0):\(lowered[$0] ?? "")" }
            .joined(separator: "\n") + "\n"
        let signedHeaders = sortedNames.joined(separator: ";")

        let payloadHash = sha256Hex(String(data: body, encoding: .utf8) ?? "")
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/request"
        let stringToSign = ["HMAC-SHA256", stamp, scope, sha256Hex(canonicalRequest)].joined(separator: "\n")

        let keys = signingKey(secretKey: secretKey, date: day, region: region, service: service)
        let signature = hmacHexDecodedKey(keys.kSigning, message: stringToSign)

        return "HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }
}
