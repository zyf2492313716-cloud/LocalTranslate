import AppKit

/// 词典独立窗口：查一个词，看完整词条。
///
/// 卡片里那版是简版（音标 + 几条词义 + 变形 + 搭配），窗口这版把例句、
/// 同义词、反义词都展开，查完可以直接留在旁边对照着写东西。
private final class DictionaryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DictionaryWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate {

    static let shared = DictionaryWindow()

    private var window: NSWindow?
    private var searchField: NSSearchField!
    private var textView: NSTextView!
    private var statusLabel: NSTextField!
    private var queryTask: Task<Void, Never>?
    private var starButton: NSButton!
    private var currentEntry: DictionaryResult?

    private override init() {}

    func show(word: String? = nil) {
        DispatchQueue.main.async {
            self.ensureWindow()
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.orderFrontRegardless()
            if let word, !word.isEmpty {
                self.searchField.stringValue = word
                self.lookup(word)
            } else {
                self.window?.makeFirstResponder(self.searchField)
            }
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        // 词典窗要在搜索框里打字，同样必须是普通可激活窗口
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "词典"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.minSize = NSSize(width: 460, height: 360)

        searchField = NSSearchField()
        searchField.placeholderString = "输入英文或中文，回车查询"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let speakButton = NSButton(title: "发音", target: self, action: #selector(speakWord))
        speakButton.bezelStyle = .rounded
        speakButton.controlSize = .small

        starButton = NSButton(title: "收藏", target: self, action: #selector(toggleStar))
        starButton.bezelStyle = .rounded
        starButton.controlSize = .small
        starButton.isEnabled = false

        let vocabButton = NSButton(title: "生词本", target: self, action: #selector(openVocabulary))
        vocabButton.bezelStyle = .rounded
        vocabButton.controlSize = .small

        let searchButton = NSButton(title: "查询", target: self, action: #selector(search))
        searchButton.bezelStyle = .rounded
        searchButton.controlSize = .small
        searchButton.keyEquivalent = "\r"

        statusLabel = NSTextField(labelWithString: "查一个词，看音标、词形、例句和同义反义")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor

        let bar = NSStackView(views: [searchField, searchButton, speakButton, starButton, vocabButton, NSView(), statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextView()
        text.isEditable = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        textView = text

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(bar)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        window.contentView = container
        self.window = window
    }

    @objc private func search() {
        lookup(searchField.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        lookup(searchField.stringValue)
    }

    func lookup(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        queryTask?.cancel()
        statusLabel.stringValue = "查询中…"
        renderPlain("正在查询 \(word)…")

        queryTask = Task { [weak self] in
            let result = await DictionaryService.lookup(word: word)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let entry):
                    self.currentEntry = entry
                    self.render(entry)
                    self.updateStar()
                    self.statusLabel.stringValue = "\(entry.word) · \(entry.parts.count) 个词性"
                case .failure(let message):
                    self.renderPlain("查不到：\(message)")
                    self.statusLabel.stringValue = "查询失败"
                }
            }
        }
    }

    /// 收藏按钮跟着当前词条走
    private func updateStar() {
        guard let entry = currentEntry else { starButton?.isEnabled = false; return }
        starButton?.isEnabled = true
        starButton?.title = VocabularyStore.contains(entry.word) ? "已收藏" : "收藏"
    }

    @objc private func speakWord() {
        guard let entry = currentEntry else { return }
        SpeechService.shared.speak(entry.word)
    }

    @objc private func toggleStar() {
        guard let entry = currentEntry else { return }
        if VocabularyStore.contains(entry.word) {
            VocabularyStore.remove(entry.word)
        } else {
            VocabularyStore.add(entry)
            if Config.shared.copyHint { HUD.show("已加入生词本") }
        }
        updateStar()
    }

    @objc private func openVocabulary() {
        VocabularyWindow.shared.show()
    }

    private func renderPlain(_ text: String) {
        textView.string = text
        textView.font = NSFont.systemFont(ofSize: 13)
    }

    /// 把词条排成一份可读文档：词头、音标、释义、词性词义、词形、例句、同义反义、搭配
    func render(_ entry: DictionaryResult) {
        let out = NSMutableAttributedString()
        let size = CGFloat(Config.shared.fontSize)

        func append(_ text: String, font: NSFont, color: NSColor, spacingBefore: CGFloat = 0) {
            if spacingBefore > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: spacingBefore)])) }
            out.append(NSAttributedString(string: text + "\n",
                                          attributes: [.font: font, .foregroundColor: color]))
        }

        append(entry.word, font: .systemFont(ofSize: size + 10, weight: .semibold), color: .labelColor)
        let phonetic = entry.phonetics.compactMap { $0.value.isEmpty ? nil : ($0.type.isEmpty ? $0.value : $0.type + " " + $0.value) }.joined(separator: "  ")
        if !phonetic.isEmpty {
            append(phonetic, font: .systemFont(ofSize: size - 1), color: .secondaryLabelColor)
        }
        if !entry.translations.isEmpty {
            append(entry.translations.joined(separator: "；"), font: .systemFont(ofSize: size + 1), color: .labelColor, spacingBefore: 6)
        }

        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            append(title, font: .systemFont(ofSize: size - 1, weight: .semibold), color: .secondaryLabelColor, spacingBefore: 8)
            for line in lines {
                append("· " + line, font: .systemFont(ofSize: size), color: .labelColor, spacingBefore: 2)
            }
        }

        section("词性与词义", entry.parts.map { "\($0.part)  \($0.means.joined(separator: "；"))" })
        section("词形变化", entry.exchanges.map { "\($0.name)：\($0.words.joined(separator: " / "))" })
        section("例句", entry.examples)
        if !entry.synonyms.isEmpty { section("同义词", [entry.synonyms.joined(separator: "、")]) }
        if !entry.antonyms.isEmpty { section("反义词", [entry.antonyms.joined(separator: "、")]) }
        section("搭配", entry.collocations.map { "\($0.phrase)  \($0.translation)" })

        textView.textStorage?.setAttributedString(out)
    }

    func windowWillClose(_ notification: Notification) {
        queryTask?.cancel()
        queryTask = nil
    }

    // MARK: - 自测入口

    /// 给自测塞词条用
    func showEntryForTesting(_ entry: DictionaryResult) {
        ensureWindow()
        currentEntry = entry
        render(entry)
        updateStar()
    }

    var starTitleForTesting: String { starButton?.title ?? "" }


    var windowForTesting: NSWindow? { window?.isVisible == true ? window : nil }

    func visibleTextSnapshot() -> [String] {
        guard let content = window?.contentView else { return [] }
        var bag: [String] = [window?.title ?? ""]
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, !f.stringValue.isEmpty { bag.append(f.stringValue) }
            if let b = v as? NSButton, !b.title.isEmpty { bag.append(b.title) }
            if let t = v as? NSTextView, !t.string.isEmpty { bag.append(t.string) }
            for sub in v.subviews { walk(sub) }
        }
        walk(content)
        return bag
    }
}