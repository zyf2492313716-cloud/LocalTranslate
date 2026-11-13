import Foundation

/// 逐行结构智能对齐器（对齐 Bob 1.21.0 的 format: "lines" 核心特性）。
///
/// 解决痛点：
/// 传统机器翻译（如 DeepL、Google、百度、腾讯、有道、DeepLX 等）以及逐行翻译插件，
/// 往往把多段文本压缩为紧凑的逐行输出，破坏了用户原文在歌词、字幕、段落间精心编排的空行与缩进。
///
/// 遵循 Bob 规范：
/// 1. 将译文的第 i 行对应原文第 i 个非空行；
/// 2. 原文两行之间是单换行，译文也保持单换行；原文是空行，译文也保留空行；
/// 3. 当译文行数与原文非空行数不匹配时，自动以单换行安全拼接，不报错、不强行插空行。
enum LineAligner {

    /// 将 translatedText 按 sourceText 的真实空行与排版骨架精准对齐拼回
    static func align(translatedText: String, to sourceText: String) -> String {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTrans = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSource.isEmpty, !trimmedTrans.isEmpty else { return translatedText }
        guard sourceText.contains("\n") || sourceText.contains("\r") else { return translatedText }

        // 提取译文所有非空行
        let transLines = translatedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !transLines.isEmpty else { return translatedText }

        // 规范化原文各行
        let rawSourceLines = sourceText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var sourceNonEmptyCount = 0
        for line in rawSourceLines {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                sourceNonEmptyCount += 1
            }
        }

        // 若译文行数与原文非空行数不一致，退回单换行拼接，不做猜想
        guard transLines.count == sourceNonEmptyCount else {
            return transLines.joined(separator: "\n")
        }

        // 行数一致时，按原文各行（是否为空行）精准原样插空回填
        var resultLines: [String] = []
        var transIdx = 0
        for line in rawSourceLines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                resultLines.append("")
            } else {
                resultLines.append(transLines[transIdx])
                transIdx += 1
            }
        }

        return resultLines.joined(separator: "\n")
    }
}
