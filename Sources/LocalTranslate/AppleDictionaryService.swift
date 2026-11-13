import Foundation
import CoreServices

/// 苹果系统原生词典服务（基于 macOS 内置 Oxford 牛津词典、现代汉语规范词典等）。
///
/// 使用 CoreServices 的 `DCSCopyTextDefinition` 系统接口：
/// - 0 延迟，离线秒出
/// - 无需 API Key，完全免配置
/// - 涵盖英美音标、词性分类、权威释义与带译文的例句（▸ 标记）
/// - 在未收录或长句时自动返回 nil，便于平滑回退到 ECDict 或在线 AI 模型
enum AppleDictionaryService {

    /// 查询单词，若系统词典收录则解析并返回结构化 `DictionaryResult`
    static func query(word: String) -> DictionaryResult? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // DCSCopyTextDefinition 要求传递 CFRange
        let cfStr = trimmed as CFString
        let length = CFStringGetLength(cfStr)
        guard length > 0 else { return nil }

        guard let defRef = DCSCopyTextDefinition(nil, cfStr, CFRangeMake(0, length)) else {
            return nil
        }

        let raw = defRef.takeRetainedValue() as String
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return parse(word: trimmed, raw: raw)
    }

    /// 解析系统词典返回的纯文本格式
    static func parse(word: String, raw: String) -> DictionaryResult {
        var phonetics: [Phonetic] = []
        var cleanBody = raw

        // 1. 提取音标部分（例如 "pressure | BrE ˈprɛʃə, AmE ˈprɛʃər | A. noun ..."）
        let pipeParts = raw.components(separatedBy: " | ")
        if pipeParts.count >= 3 {
            let phonPart = pipeParts[1]
            for p in phonPart.components(separatedBy: ", ") {
                let trimmedP = p.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedP.isEmpty {
                    // 分离 "BrE" / "AmE" 与音标值
                    let subTokens = trimmedP.split(separator: " ")
                    if subTokens.count >= 2 {
                        let type = String(subTokens[0])
                        let val = subTokens.dropFirst().joined(separator: " ")
                        phonetics.append(Phonetic(type: type, value: val))
                    } else {
                        phonetics.append(Phonetic(type: "", value: trimmedP))
                    }
                }
            }
            cleanBody = pipeParts.dropFirst(2).joined(separator: " | ")
        } else if let spaceIdx = cleanBody.firstIndex(of: " ") {
            // 中文词典形态："测试 cèshì ①动 测量试验..."
            let head = cleanBody[..<spaceIdx]
            if head == word {
                let rest = cleanBody[cleanBody.index(after: spaceIdx)...]
                let tokens = rest.split(separator: " ", maxSplits: 1)
                if let pinyin = tokens.first, !pinyin.isEmpty {
                    phonetics.append(Phonetic(type: "拼音", value: String(pinyin)))
                    cleanBody = tokens.count > 1 ? String(tokens[1]) : ""
                }
            }
        }

        // 2. 提取例句（Oxford 词典通常使用 ▸ 引导短语和例句）
        var examples: [String] = []
        var defText = cleanBody
        if cleanBody.contains("▸") {
            let segs = cleanBody.components(separatedBy: "▸")
            defText = segs[0].trimmingCharacters(in: .whitespacesAndNewlines)
            for s in segs.dropFirst() {
                let ex = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ex.isEmpty {
                    examples.append(ex)
                }
            }
        }

        // 3. 整理释义与词性分类
        var translations: [String] = []
        if !defText.isEmpty {
            // 按换行或分号拆分
            let lines = defText.components(separatedBy: "\n")
            for l in lines {
                let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { translations.append(t) }
            }
        }

        if translations.isEmpty && !defText.isEmpty {
            translations = [defText]
        }

        return DictionaryResult(
            word: word,
            translations: Array(translations.prefix(8)),
            phonetics: phonetics,
            parts: [],
            exchanges: [],
            collocations: [],
            examples: Array(examples.prefix(12)),
            synonyms: [],
            antonyms: []
        )
    }
}
