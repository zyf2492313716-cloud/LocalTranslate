import Foundation

/// 划词与翻译源文本预处理引擎（对齐 Bob 的核心文本清洗逻辑）。
///
/// 解决两大最痛的使用痛点：
/// 1. PDF / 论文硬换行：PDF 复制经常把一句话切成三四行硬换行，甚至连字符折行 (trans-\nport)。
///    预处理将连字符复原、非段落末尾的硬换行转为空格（中文两端则不加空格），保留真正的双换行段落。
/// 2. 代码标识符拆词：程序员选中的变量名/方法名（如 getUserProfile、parse_json_data），
///    在翻译前自动拆为以空格分隔的自然英语单词，大幅提升大模型与传统翻译接口的理解准确度。
enum TextPreprocessor {

    /// 统一入口。根据用户偏好配置进行清洗。
    static func process(_ text: String) -> String {
        var result = text

        let config = Config.shared
        if config.mergePDFNewlines {
            result = fixHyphenationAndMergeLines(result)
        }

        if config.splitCodeIdentifiers {
            result = splitCodeIdentifierIfNeeded(result)
        }

        return result
    }

    // MARK: - 1. 连字符复原与换行合并

    /// 修复断行连字符与合并单行硬换行
    static func fixHyphenationAndMergeLines(_ text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else { return text }

        // 统一换行符为 \n
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 1) 连字符折行修复：例如 "inter-\n national" -> "international"
        // 匹配：字母 + 连字符 + 单个换行 + 字母
        if let regex = try? NSRegularExpression(pattern: #"([a-zA-Z]+)-\n\s*([a-zA-Z]+)"#, options: []) {
            let range = NSRange(location: 0, length: normalized.utf16.count)
            normalized = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: "$1$2")
        }

        // 2) 保留双换行及以上的真段落标记，用占位符保护
        let paragraphPlaceholder = "___LT_PARA_BREAK___"
        if let paraRegex = try? NSRegularExpression(pattern: #"\n\s*\n+"#, options: []) {
            let range = NSRange(location: 0, length: normalized.utf16.count)
            normalized = paraRegex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: paragraphPlaceholder)
        }

        // 3) 单换行合并：
        // 遍历每行，如果换行两侧均为中文字符，直接拼接（不加空格）；
        // 如果两侧包含拉丁/数字，则用单个空格连接。
        let lines = normalized.components(separatedBy: "\n")
        var merged = ""
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if index == 0 || merged.isEmpty {
                merged = line
            } else {
                let prevLastChar = merged.last
                let nextFirstChar = line.first

                let prevIsCJK = prevLastChar.map { isCJK($0) } ?? false
                let nextIsCJK = nextFirstChar.map { isCJK($0) } ?? false

                if prevIsCJK && nextIsCJK {
                    // 中文之间换行合并：直接相连，不插空格
                    merged.append(line)
                } else {
                    // 英文/西文之间换行合并：补充空格
                    merged.append(" " + line)
                }
            }
        }

        // 还原段落双换行
        let finalResult = merged.replacingOccurrences(of: paragraphPlaceholder, with: "\n\n")
        return finalResult
    }

    private static func isCJK(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            // CJK 统一表意文字及扩展区
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x20000...0x2A6DF).contains(scalar.value) {
                return true
            }
        }
        return false
    }

    // MARK: - 2. 代码标识符驼峰与下划线拆分

    /// 判断输入文本是否是一个典型的编程标识符（单个 Token，没有空格，含下划线或大小写跃迁）
    static func isCodeIdentifier(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 排除包含空格、标点符号（除了 _ 和 -）以及超长段落
        guard !trimmed.isEmpty && trimmed.count <= 64 else { return false }
        guard !trimmed.contains(where: { $0.isWhitespace || $0 == "\n" || $0 == "." || $0 == "," || $0 == "(" || $0 == ")" }) else {
            return false
        }

        // 下划线命名：如 user_profile_data
        if trimmed.contains("_") {
            let parts = trimmed.split(separator: "_")
            return parts.count >= 2 && parts.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber } }
        }

        // 连字符代码名：如 get-user-info
        if trimmed.contains("-") && trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            return true
        }

        // 驼峰命名：含小写接大写的跃迁，或连续大写后接小写（如 XMLParser -> XML Parser, getUser -> get User）
        let chars = Array(trimmed)
        for i in 0..<(chars.count - 1) {
            if chars[i].isLowercase && chars[i + 1].isUppercase {
                return true
            }
            if i > 0 && chars[i - 1].isUppercase && chars[i].isUppercase && chars[i + 1].isLowercase {
                return true
            }
        }

        return false
    }

    /// 拆分代码标识符为自然语言单词
    static func splitCodeIdentifierIfNeeded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCodeIdentifier(trimmed) else { return text }

        // 1. 处理下划线与中划线
        var temp = trimmed.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // 2. 处理大写连续字串（如 XMLParser -> XML Parser）
        if let regex1 = try? NSRegularExpression(pattern: #"([A-Z]+)([A-Z][a-z])"#, options: []) {
            let range = NSRange(location: 0, length: temp.utf16.count)
            temp = regex1.stringByReplacingMatches(in: temp, options: [], range: range, withTemplate: "$1 $2")
        }

        // 3. 处理小写接大写（如 getUser -> get User）
        if let regex2 = try? NSRegularExpression(pattern: #"([a-z0-9])([A-Z])"#, options: []) {
            let range = NSRange(location: 0, length: temp.utf16.count)
            temp = regex2.stringByReplacingMatches(in: temp, options: [], range: range, withTemplate: "$1 $2")
        }

        // 压缩多余空格
        let parts = temp.split(separator: " ").map(String.init)
        return parts.joined(separator: " ")
    }
}
