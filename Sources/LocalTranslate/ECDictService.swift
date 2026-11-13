import Foundation
import SQLite3

/// 离线简明英汉词典（ECDICT 兼容）。
///
/// Bob 的简明英汉词典基于 skywind3000/ECDICT 的 SQLite 数据库。
/// 数据库结构包含表 stardict (word, phonetic, definition, translation, exchange)。
///
/// 当本地存在 ecdict.db（放在 Application Support/LocalTranslate/ecdict.db 或由设置导入），
/// 查词将首先使用离线词典毫秒级返回，模型词典作为增强和补充；
/// 没有数据库文件时自动降级走在线模型词典。
enum ECDictService {

    /// 离线词典数据库文件位置
    static var dbURL: URL {
        if let o = dbURLOverride { return o }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalTranslate", isDirectory: true)
        return dir.appendingPathComponent("ecdict.db")
    }

    /// 自测用
    static var dbURLOverride: URL?

    /// 本地是否存在离线词典数据库
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: dbURL.path)
    }

    /// 尝试在本地 SQLite 数据库中检索词条
    static func query(word: String) -> DictionaryResult? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, isAvailable else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT word, phonetic, definition, translation, exchange FROM stardict WHERE word = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (trimmed as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let resWord = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? trimmed
            let phoneticStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let definitionStr = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let translationStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let exchangeStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""

            return formatEntry(word: resWord, phonetic: phoneticStr, definition: definitionStr,
                               translation: translationStr, exchange: exchangeStr)
        }

        return nil
    }

    /// 格式化 SQLite 行数据为统一的 DictionaryResult
    static func formatEntry(word: String, phonetic: String, definition: String,
                            translation: String, exchange: String) -> DictionaryResult {
        // 1. 音标
        var phonetics: [Phonetic] = []
        if !phonetic.isEmpty {
            phonetics.append(Phonetic(type: "", value: phonetic))
        }

        // 2. 简明释义 (换行或分号拆分)
        var transList: [String] = []
        let rawTrans = translation.isEmpty ? definition : translation
        for line in rawTrans.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { transList.append(t) }
        }

        // 3. 词形变化 (ECDICT 格式通常为 p:past/d:done/i:doing/3:3rd/r:comp/t:sup/s:plural/0:lemma)
        var exchanges: [Exchange] = []
        if !exchange.isEmpty {
            let tokens = exchange.components(separatedBy: "/")
            for token in tokens {
                let parts = token.components(separatedBy: ":")
                guard parts.count == 2 else { continue }
                let code = parts[0]
                let targetWord = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !targetWord.isEmpty else { continue }

                let label: String
                switch code {
                case "p": label = "过去式"
                case "d": label = "过去分词"
                case "i": label = "现在分词"
                case "3": label = "第三人称单数"
                case "r": label = "比较级"
                case "t": label = "最高级"
                case "s": label = "复数"
                case "0": label = "原型"
                default: label = code
                }
                exchanges.append(Exchange(name: label, words: [targetWord]))
            }
        }

        return DictionaryResult(
            word: word,
            translations: transList,
            phonetics: phonetics,
            parts: [],
            exchanges: exchanges,
            collocations: [],
            examples: [],
            synonyms: [],
            antonyms: []
        )
    }

    /// 自测用：在内存或指定临时路径创建一个测试 ECDict SQLite 库
    @discardableResult
    static func createSampleDB(at path: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE stardict (
            id INTEGER PRIMARY KEY,
            word TEXT NOT NULL UNIQUE,
            phonetic TEXT,
            definition TEXT,
            translation TEXT,
            exchange TEXT
        );
        INSERT INTO stardict (word, phonetic, definition, translation, exchange)
        VALUES ('hello', 'həˈləʊ', 'greeting', 'int. 喂，你好\\nn. 问候', 's:hellos/i:helloing');
        """
        return sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK
    }
}
