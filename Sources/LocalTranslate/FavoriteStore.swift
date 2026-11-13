import AppKit

/// 收藏夹：收藏翻译结果（与收词的生词本区分开，对应 Bob 的收藏功能）。
/// 支持存盘、去重、按关键字检索、导出为 JSON 或 CSV。
struct FavoriteEntry: Codable, Equatable, Identifiable {
    var id: String
    var source: String
    var result: String
    var model: String
    var targetLanguage: String
    var sourceLanguage: String
    var date: Date
}

enum FavoriteStore {

    private static let fileName = "favorites.json"
    private static let lock = NSLock()
    private static var memory: [FavoriteEntry]?

    /// 自测用：把文件重定向到临时目录
    static var directoryOverride: URL?

    static var fileURL: URL {
        let dir = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LocalTranslate", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    static func all() -> [FavoriteEntry] {
        lock.lock(); defer { lock.unlock() }
        if let memory { return memory }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode([FavoriteEntry].self, from: $0) } ?? []
        memory = loaded
        return loaded
    }

    static func count() -> Int { all().count }

    static func contains(source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return all().contains { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }

    @discardableResult
    static func add(source: String, result: String, model: String, targetLanguage: String, sourceLanguage: String = "auto", date: Date = Date()) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty && !r.isEmpty else { return false }
        var list = all()
        // 同一段原文去重覆盖
        list.removeAll { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) == s }
        let entry = FavoriteEntry(id: UUID().uuidString, source: s, result: r, model: model, targetLanguage: targetLanguage, sourceLanguage: sourceLanguage, date: date)
        list.insert(entry, at: 0)
        return save(list)
    }

    @discardableResult
    static func remove(source: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = all()
        list.removeAll { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) == s }
        return save(list)
    }

    @discardableResult
    static func remove(id: String) -> Bool {
        var list = all()
        list.removeAll { $0.id == id }
        return save(list)
    }

    @discardableResult
    static func clear() -> Bool { save([]) }

    private static func save(_ list: [FavoriteEntry]) -> Bool {
        lock.lock()
        memory = list
        lock.unlock()
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(list) else { return false }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    static func reload() {
        lock.lock(); memory = nil; lock.unlock()
    }

    /// 导出为 JSON
    static func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(all())
    }

    /// 导出为 Anki 牌组格式 (TSV 制表符分隔)
    /// 正面: 原文
    /// 背面: 译文 (模型名与语言)
    static func exportAnkiDeck() -> String {
        var tsv = "#separator:tab\n#html:true\n#tags column:3\n"
        for item in all() {
            let front = item.source.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "<br>")
            let back = item.result.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "<br>")
            tsv += "\(front)\t\(back)\t\(item.model)\n"
        }
        return tsv
    }

    /// 导出为 CSV
    static func exportCSV() -> String {
        var csv = "id,date,source,result,model,targetLanguage\n"
        let f = ISO8601DateFormatter()
        for e in all() {
            let s = e.source.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " ")
            let r = e.result.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " ")
            csv += "\"\(e.id)\",\"\(f.string(from: e.date))\",\"\(s)\",\"\(r)\",\"\(e.model)\",\"\(e.targetLanguage)\"\n"
        }
        return csv
    }
}
