import Foundation
import CryptoKit

/// 有道翻译（免密钥）。
///
/// 两条链路，都来自社区插件 `bob-plugin-akl-youdao-free-translate` 的协议：
/// 1. 句子：POST `aidemo.youdao.com/trans`，表单 q/from/to，返回 `translation` 数组；
/// 2. 单词：POST `dict.youdao.com/jsonapi_s`，带一个 MD5 签名，
///    返回 `ec.word`（英美音标 / 词性释义 / 词形变化），正好喂给词典卡。
///
/// 免密钥、国内直连，中文质量比 MyMemory 稳。
enum YoudaoFreeTranslator {

    struct Failure: Error { var message: String }

    static let sentenceEndpoint = URL(string: "https://aidemo.youdao.com/trans")!
    static let dictionaryEndpoint = URL(string: "https://dict.youdao.com/jsonapi_s?doctype=json&jsonversion=4")!

    static func normalize(_ code: String) -> String {
        switch code {
        case "zh", "zh-Hans", "zh-Hant": return "zh-CHS"
        case "auto", "": return "auto"
        default: return code
        }
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func formBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    // MARK: - 句子翻译

    static func translate(text: String, from: String, to: String) async -> Result<String, Failure> {
        let source = normalize(from)
        let target = normalize(to)
        guard target != source || source == "auto" else { return .success(text) }

        // 接口单次上限 1000 字符，按句读切
        let chunks = chunk(text, limit: 900)
        var pieces: [String] = []
        for chunk in chunks {
            switch await translateOnce(chunk, from: source, to: target) {
            case .success(let piece): pieces.append(piece)
            case .failure(let failure):
                if pieces.isEmpty { return .failure(failure) }
            }
        }
        let joined = pieces.joined(separator: "\n")
        return joined.isEmpty ? .failure(Failure(message: "有道没有返回译文")) : .success(joined)
    }

    private static func translateOnce(_ text: String, from: String, to: String) async -> Result<String, Failure> {
        var request = URLRequest(url: sentenceEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = formBody([("q", text), ("from", from), ("to", to)])

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(Failure(message: "有道返回 \(http.statusCode)"))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(Failure(message: "有道返回的数据看不懂"))
            }
            if let list = object["translation"] as? [String], !list.isEmpty {
                return .success(list.joined(separator: "\n"))
            }
            if let code = object["errorCode"] as? String, code != "0" {
                return .failure(Failure(message: "有道接口错误 \(code)"))
            }
            return .failure(Failure(message: "有道没有返回译文"))
        } catch {
            return .failure(Failure(message: "连不上有道：\(error.localizedDescription)"))
        }
    }

    /// 按句末标点切成不超过 limit 的块
    static func chunk(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            let isBreak = "。！？!?；;\n".contains(character)
            if isBreak && current.count >= limit / 2 {
                chunks.append(current)
                current = ""
            } else if current.count >= limit {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - 单词词典

    /// 查英文单词。只对单词有意义，句子交给翻译链路。
    static func lookup(word rawWord: String) async -> DictionaryResult? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.split(separator: " ").count <= 3 else { return nil }

        // 签名：sign(MD5) = md5("web" + word + t + 固定密钥 + md5(word + "webdict"))
        let time = (word.count + "webdict".count) % 10
        let inner = md5(word + "webdict")
        let sign = md5("web" + word + String(time) + "Mk6hqtUp33DGGtoS63tTJbMUYjRrG1Lu" + inner)

        var request = URLRequest(url: dictionaryEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = formBody([
            ("q", word), ("keyfrom", "webdict"), ("sign", sign),
            ("client", "web"), ("t", String(time)),
        ])

        do {
            let (data, response) = try await NetworkSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return parse(object, fallbackWord: word)
        } catch {
            return nil
        }
    }

    /// 解析 jsonapi_s → DictionaryResult
    static func parse(_ object: [String: Any], fallbackWord: String) -> DictionaryResult? {
        guard let ec = object["ec"] as? [String: Any],
              let wordInfo = ec["word"] as? [String: Any] else { return nil }

        var phonetics: [Phonetic] = []
        if let us = wordInfo["usphone"] as? String, !us.isEmpty {
            phonetics.append(Phonetic(type: "us", value: us))
        }
        if let uk = wordInfo["ukphone"] as? String, !uk.isEmpty {
            phonetics.append(Phonetic(type: "uk", value: uk))
        }

        var parts: [WordPart] = []
        var translations: [String] = []
        if let trs = wordInfo["trs"] as? [[String: Any]] {
            for item in trs {
                let pos = (item["pos"] as? String) ?? ""
                let tran = (item["tran"] as? String) ?? ""
                guard !tran.isEmpty else { continue }
                translations.append(pos.isEmpty ? tran : "\(pos) \(tran)")
                parts.append(WordPart(part: pos, means: [tran]))
            }
        }

        var exchanges: [Exchange] = []
        if let wfs = wordInfo["wfs"] as? [[String: Any]] {
            for item in wfs {
                guard let wf = item["wf"] as? [String: Any],
                      let name = wf["name"] as? String,
                      let value = wf["value"] as? String else { continue }
                exchanges.append(Exchange(name: name, words: [value]))
            }
        }
        if let prototype = wordInfo["prototype"] as? String, !prototype.isEmpty {
            exchanges.append(Exchange(name: "原形", words: [prototype]))
        }

        let headword = (wordInfo["word"] as? String) ?? fallbackWord
        let result = DictionaryResult(word: headword, translations: Array(translations.prefix(8)),
                                      phonetics: phonetics, parts: Array(parts.prefix(12)),
                                      exchanges: Array(exchanges.prefix(8)), collocations: [])
        return result.isEmpty ? nil : result
    }
}
