import AppKit

/// 生词本。存 Application Support 下的 JSON，明文可读、可导出。
///
/// 只存「够回看」的字段：词、音标、几条释义、收藏时间。
/// 整份词典结构不落盘——那是模型的输出，改版就可能变，存了也是负担。
struct VocabularyEntry: Codable, Equatable {
    var word: String
    var phonetic: String
    var translations: [String]
    var addedAt: Date
}

enum VocabularyStore {

    private static let fileName = "vocabulary.json"
    private static let lock = NSLock()
    private static var memory: [VocabularyEntry]?

    /// 自测用：把文件挪到临时目录
    static var directoryOverride: URL?

    static var fileURL: URL {
        let dir = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LocalTranslate", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    static func all() -> [VocabularyEntry] {
        lock.lock(); defer { lock.unlock() }
        if let memory { return memory }
        // 解码器必须和编码器用同一种日期策略，否则解析失败会被当成空生词本
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode([VocabularyEntry].self, from: $0) } ?? []
        memory = loaded
        return loaded
    }

    static func count() -> Int { all().count }

    static func contains(_ word: String) -> Bool {
        all().contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    @discardableResult
    static func add(word: String, phonetic: String, translations: [String], at date: Date = Date()) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var list = all()
        guard !list.contains(where: { $0.word.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }
        list.insert(VocabularyEntry(word: trimmed, phonetic: phonetic,
                                    translations: translations, addedAt: date), at: 0)
        return save(list)
    }

    @discardableResult
    static func add(_ entry: DictionaryResult) -> Bool {
        add(word: entry.word,
            phonetic: entry.phonetics.map { $0.value }.first ?? "",
            translations: Array(entry.translations.prefix(3)))
    }

    @discardableResult
    static func remove(_ word: String) -> Bool {
        let list = all().filter { $0.word.caseInsensitiveCompare(word) != .orderedSame }
        return save(list)
    }

    @discardableResult
    static func clear() -> Bool { save([]) }

    private static func save(_ list: [VocabularyEntry]) -> Bool {
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

    /// 自测用：清掉内存缓存，强制从磁盘重读
    static func reload() {
        lock.lock(); memory = nil; lock.unlock()
    }

    /// 导出为 Anki 牌组格式 (TSV: 正面制表符背面)
    /// 正面: 单词 [音标]
    /// 背面: 释义列表
    static func exportAnkiDeck() -> String {
        var tsv = "#separator:tab\n#html:true\n#tags column:3\n"
        for item in all() {
            let front: String
            if !item.phonetic.isEmpty {
                front = "\(item.word) <span style=\"color:#888;\">[\(item.phonetic)]</span>"
            } else {
                front = item.word
            }
            let back = item.translations.joined(separator: "<br>")
            let cleanFront = front.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            let cleanBack = back.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            tsv += "\(cleanFront)\t\(cleanBack)\tLocalTranslate\n"
        }
        return tsv
    }

    /// 导出为 CSV
    static func exportCSV() -> String {
        var csv = "word,phonetic,translations,addedAt\n"
        let f = ISO8601DateFormatter()
        for e in all() {
            let w = e.word.replacingOccurrences(of: "\"", with: "\"\"")
            let p = e.phonetic.replacingOccurrences(of: "\"", with: "\"\"")
            let t = e.translations.joined(separator: "；").replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(w)\",\"\(p)\",\"\(t)\",\"\(f.string(from: e.addedAt))\"\n"
        }
        return csv
    }
}

/// 生词本窗口：看、查、删。
final class VocabularyWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    static let shared = VocabularyWindow()

    private var window: NSWindow?
    private var table: NSTableView!
    private var countLabel: NSTextField!
    private var entries: [VocabularyEntry] = []

    private override init() {}

    func show() {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.reload()
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "生词本"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        let speakButton = NSButton(title: "朗读", target: self, action: #selector(speakSelected))
        speakButton.bezelStyle = .rounded
        speakButton.controlSize = .small
        let lookupButton = NSButton(title: "查词", target: self, action: #selector(lookupSelected))
        lookupButton.bezelStyle = .rounded
        lookupButton.controlSize = .small
        let removeButton = NSButton(title: "删除", target: self, action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small

        let exportButton = NSButton(title: "导出…", target: self, action: #selector(exportDeck))
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .small

        let bar = NSStackView(views: [countLabel, NSView(), speakButton, lookupButton, removeButton, exportButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        window.contentView = container
        self.window = window
    }

    func reload() {
        entries = VocabularyStore.all()
        countLabel?.stringValue = "共 \(entries.count) 个词"
        table?.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let word = NSTextField(labelWithString: entry.word)
        word.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let detail = [entry.phonetic, entry.translations.joined(separator: "；")]
            .filter { !$0.isEmpty }.joined(separator: "  ")
        let sub = NSTextField(labelWithString: detail)
        sub.font = NSFont.systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [word, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    private var selectedWord: String? {
        let row = table?.selectedRow ?? -1
        return entries.indices.contains(row) ? entries[row].word : nil
    }

    @objc private func speakSelected() {
        guard let word = selectedWord else { return }
        SpeechService.shared.speak(word)
    }

    @objc private func lookupSelected() {
        guard let word = selectedWord else { return }
        DictionaryWindow.shared.show(word: word)
    }

    @objc private func removeSelected() {
        guard let word = selectedWord else { return }
        VocabularyStore.remove(word)
        reload()
    }

    @objc private func exportDeck() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vocabulary_anki.txt"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "csv" {
                let csv = VocabularyStore.exportCSV()
                try? csv.write(to: url, atomically: true, encoding: .utf8)
            } else {
                let tsv = VocabularyStore.exportAnkiDeck()
                try? tsv.write(to: url, atomically: true, encoding: .utf8)
            }
            HUD.show("生词本已导出")
        }
    }

    // MARK: - 自测入口

    func rowsForTesting() -> Int { entries.count }
    func visibleTextSnapshot() -> [String] {
        guard let content = window?.contentView else { return [] }
        var bag: [String] = [window?.title ?? ""]
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, !f.stringValue.isEmpty { bag.append(f.stringValue) }
            if let b = v as? NSButton, !b.title.isEmpty { bag.append(b.title) }
            for sub in v.subviews { walk(sub) }
        }
        walk(content)
        return bag
    }
}
