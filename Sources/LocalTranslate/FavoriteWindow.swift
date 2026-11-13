import AppKit

/// 收藏夹窗口：浏览收藏的译文、检索、重新翻译与导出。
final class FavoriteWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    static let shared = FavoriteWindow()

    private var window: NSWindow?
    private var table: NSTableView!
    private var countLabel: NSTextField!
    private var entries: [FavoriteEntry] = []
    private var filtered: [FavoriteEntry] = []
    private var contextItem: FavoriteEntry?
    private var searchField: NSSearchField!

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "收藏夹"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        searchField = NSSearchField()
        searchField.placeholderString = "搜索原文或译文"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.dataSource = self
        table.delegate = self
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.rowSizeStyle = .custom
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
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

        let exportButton = NSButton(title: "导出…", target: self, action: #selector(exportFavorites))
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .small

        let deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteSelected))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small

        let topBar = NSStackView(views: [searchField, NSView(), countLabel, exportButton, deleteButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(topBar)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            topBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        window.contentView = container
        self.window = window
    }

    func reload() {
        entries = FavoriteStore.all()
        applyFilter()
    }

    private func applyFilter() {
        let kw = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if kw.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter { $0.source.lowercased().contains(kw) || $0.result.lowercased().contains(kw) }
        }
        countLabel?.stringValue = "共 \(filtered.count) 条收藏"
        table?.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let item = filtered[row]

        let src = NSTextField(labelWithString: item.source)
        src.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        src.lineBreakMode = .byTruncatingTail
        src.maximumNumberOfLines = 2

        let res = NSTextField(labelWithString: item.result)
        res.font = NSFont.systemFont(ofSize: 12)
        res.textColor = .secondaryLabelColor
        res.lineBreakMode = .byTruncatingTail
        res.maximumNumberOfLines = 3

        let meta = NSTextField(labelWithString: metaLine(for: item))
        meta.font = NSFont.systemFont(ofSize: 10)
        meta.textColor = .tertiaryLabelColor
        meta.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [src, res, meta])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return stack
    }

    private func metaLine(for item: FavoriteEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        var parts: [String] = []
        if !item.model.isEmpty { parts.append(item.model) }
        parts.append("\(item.sourceLanguage) → \(item.targetLanguage)")
        parts.append(formatter.string(from: item.date))
        return parts.joined(separator: "  ·  ")
    }

    /// 右键菜单：复制译文 / 复制原文 / 朗读 / 删除
    func tableView(_ tableView: NSTableView, menuFor tableColumn: NSTableColumn?, row: Int) -> NSMenu? {
        guard filtered.indices.contains(row) else { return nil }
        let item = filtered[row]
        contextItem = item
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "复制译文", action: #selector(copyResult), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "复制原文", action: #selector(copySource), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "朗读译文", action: #selector(speakResult), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "删除这条收藏", action: #selector(deleteContextItem), keyEquivalent: ""))
        for entry in menu.items { entry.target = self }
        return menu
    }

    /// 双击一行直接复制译文（最常用的动作）
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView.clickedRow >= 0, NSApp.currentEvent?.clickCount == 2, filtered.indices.contains(tableView.clickedRow) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(filtered[tableView.clickedRow].result, forType: .string)
            HUD.show("已复制译文")
        }
        return true
    }

    /// 行高必须跟着内容走：固定行高会把原文裁成一条缝（第一版就是这样，看着像"没做出来"）
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard filtered.indices.contains(row) else { return 44 }
        let item = filtered[row]
        let width = max(200, tableView.bounds.width - 40)
        func measure(_ text: String, font: NSFont, maxLines: Int) -> CGFloat {
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font])
            let line = font.ascender - font.descender + font.leading
            return min(max(rect.height, line), line * CGFloat(maxLines))
        }
        let source = measure(item.source, font: .systemFont(ofSize: 12.5, weight: .medium), maxLines: 2)
        let result = measure(item.result, font: .systemFont(ofSize: 12), maxLines: 3)
        return source + result + 14 + 6 + 16   // 正文 + 元信息行 + 间距 + 上下内边距
    }

    @objc private func copyResult() {
        guard let item = contextItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.result, forType: .string)
        HUD.show("已复制译文")
    }

    @objc private func copySource() {
        guard let item = contextItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.source, forType: .string)
        HUD.show("已复制原文")
    }

    @objc private func speakResult() {
        guard let item = contextItem else { return }
        SpeechService.shared.speak(item.result)
    }

    @objc private func deleteContextItem() {
        guard let item = contextItem else { return }
        FavoriteStore.remove(id: item.id)
        reload()
    }

    @objc private func deleteSelected() {
        let row = table?.selectedRow ?? -1
        guard filtered.indices.contains(row) else { return }
        let item = filtered[row]
        FavoriteStore.remove(id: item.id)
        reload()
    }

    @objc private func exportFavorites() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "favorites_anki.txt"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "json" {
                if let data = FavoriteStore.exportJSON() {
                    try? data.write(to: url)
                }
            } else if ext == "csv" {
                let csv = FavoriteStore.exportCSV()
                try? csv.write(to: url, atomically: true, encoding: .utf8)
            } else {
                let anki = FavoriteStore.exportAnkiDeck()
                try? anki.write(to: url, atomically: true, encoding: .utf8)
            }
            HUD.show("收藏夹已导出")
        }
    }

    // MARK: - 自测入口

    func countForTesting() -> Int { filtered.count }
}
