import Foundation

/// 各模块共用的数据类型。改这里要同步改调用方。

// MARK: - 历史记录

/// 一条翻译历史。存 Application Support/LocalTranslate/history.json
struct HistoryEntry: Codable, Equatable, Identifiable {
    var id: String { "\(date)-\(source.hashValue)" }
    let source: String
    let result: String
    let mode: String          // TranslateMode.rawValue
    let model: String
    let targetLanguage: String
    let date: Date
    var seconds: Double?
}

// MARK: - 多模型对比

/// 一个模型跑完的结果。error 非空表示这次失败。
struct ModelOutcome {
    var model: String
    var text: String
    var think: String
    var seconds: Double
    var error: String?

    var failed: Bool { error != nil }
}

// MARK: - 词典

struct Phonetic {
    /// "us" 或 "uk"
    var type: String
    /// 音标文本，例如 ˈpreʃɚ
    var value: String
}

struct WordPart {
    /// 词性，例如 n. / vt. / adj.
    var part: String
    /// 该词性下的各条词义
    var means: [String]
}

struct Exchange {
    /// 形式名称，例如 现在分词 / 过去式 / 比较级 / 复数
    var name: String
    var words: [String]
}

struct Collocation {
    /// 原词搭配，例如 under pressure
    var phrase: String
    /// 中文释义
    var translation: String
}

/// 词典查询结果，供界面分区渲染
struct DictionaryResult {
    var word: String
    /// 简明释义，词典区最上面那几行
    var translations: [String]
    var phonetics: [Phonetic]
    var parts: [WordPart]
    var exchanges: [Exchange]
    var collocations: [Collocation]
    /// 例句，已经拼成「原文 — 译文」一行一条
    var examples: [String] = []
    var synonyms: [String] = []
    var antonyms: [String] = []

    var isEmpty: Bool {
        translations.isEmpty && parts.isEmpty && exchanges.isEmpty && collocations.isEmpty
            && examples.isEmpty && synonyms.isEmpty && antonyms.isEmpty && phonetics.isEmpty
    }
}
