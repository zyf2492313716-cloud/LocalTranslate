import Foundation
import NaturalLanguage

/// 语言检测与双语智能切换（对齐 Bob 1.15.0 的第一语言与第二语言特性）。
enum LanguageDetector {

    /// 识别文本的大致语种代码
    ///
    /// 关键修正：以前只要出现一个汉字就判成中文，导致「导入任务 Discuss in pairs and try to
    /// define the following terms…」这种英文教材里夹了几句中文的段落被判成中文，
    /// 于是被翻成英文——方向整个反了。现在按「汉字 vs 拉丁字母」的实际占比判断主导语言。
    static func detectLanguage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "en" }

        // 日文假名（假名是日语特有，排在汉字之前检查以防日文中夹带汉字被误判）。
        // 注意排除 0x30FB「・」和 0x30FC「ー」：中文 OCR 常把间隔号认成这两个，
        // 以前只要有它们就把整段中文判成日语，于是去翻 ja——直接触发系统下载语言包弹窗。
        let kanaCount = trimmed.unicodeScalars.reduce(into: 0) { acc, scalar in
            if (0x3041...0x3096).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value) {
                acc += 1
            }
        }
        var cjkTotal = 0
        for scalar in trimmed.unicodeScalars where (0x4E00...0x9FFF).contains(scalar.value) {
            cjkTotal += 1
        }
        // 至少两个假名，且假名占汉字量的一成以上，才算日语
        if kanaCount >= 2 && (cjkTotal == 0 || kanaCount * 10 >= cjkTotal) {
            return "ja"
        }

        // 韩文谚文（韩文特有字符）
        let hasHangul = trimmed.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        if hasHangul { return "ko" }

        // 汉字与拉丁字母按实际数量比主导地位，避免「英文为主 + 少量中文」被整段判成中文
        var cjkCount = 0
        var latinCount = 0
        for scalar in trimmed.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                cjkCount += 1
            } else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                latinCount += 1
            }
        }
        // 汉字占主导（汉字数量不少于拉丁字母的三分之一）才当作中文
        if cjkCount > 0 && cjkCount * 3 >= latinCount {
            return "zh-Hans"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else {
            // 认不出时按上面的计数兜底：有汉字就当中文，否则英文
            return cjkCount > 0 ? "zh-Hans" : "en"
        }
        switch lang {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .french: return "fr"
        case .german: return "de"
        case .spanish: return "es"
        case .russian: return "ru"
        case .italian: return "it"
        case .portuguese: return "pt"
        default: return lang.rawValue
        }
    }

    /// 收敛成基础语言码（zh-Hans / zh-Hant → zh，en-US → en），用于比较「是不是同一种语言」
    static func baseCode(_ code: String) -> String {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("en") { return "en" }
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("ko") { return "ko" }
        return String(lower.prefix(2))
    }

    /// 根据当前第一语言与第二语言配置，计算实际目标语言。
    /// 规则：
    /// 当输入为第一语言（如中文）时，自动翻译为第二语言（如英文）；
    /// 输入为其他语言（如英文、日文等）时，自动翻译为第一语言（如中文）。
    static func resolveTargetLanguage(source: String, fallbackTarget: String) -> String {
        guard Config.shared.autoSwitchLanguage else { return fallbackTarget }
        let primary = Config.shared.primaryLanguage
        let secondary = Config.shared.secondaryLanguage
        let detected = detectLanguage(source)

        let isPrimaryChinese = primary.hasPrefix("zh")
        let isDetectedChinese = detected.hasPrefix("zh")

        if isPrimaryChinese && isDetectedChinese {
            return secondary
        } else if detected.hasPrefix(primary) {
            return secondary
        } else {
            return primary
        }
    }
}
