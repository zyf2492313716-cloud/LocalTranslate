import AppKit

/// 翻译历史浏览窗口。
///
/// 布局：顶部搜索框 → 中间列表 → 详情区（完整原文/译文，可选中复制）→ 底部按钮条。
/// 数据一律走 `HistoryStore.allRecords()` / `records(matching:)`，因为要靠 `Record.id`
/// （稳定主键，见 HistoryStore 头部注释）做删除；`HistoryEntry.id` 那个 hashValue 不拿来用。
final class HistoryWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {

    static let shared = HistoryWindow()

    private var window: NSWindow?
    private var rows: [HistoryStore.Record] = []
    private var detailRecord: HistoryStore.Record?

    // MARK: - 控件

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = HistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "还没有翻译记录。选中文字后按 Cmd+Shift+X 试一次。")
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailScrollView = NSScrollView()
    private let detailContainer = NSStackView()
    private let dividerWindow = NSBox()
    private var favoriteButton: NSButton!

    private var copyButton: NSButton!
    private var replayButton: NSButton!
    private var deleteButton: NSButton!

    private var statusClearWork: DispatchWorkItem?

    /// 自测用：拿到真实窗口做离屏快照
    var windowForTesting: NSWindow? { window }

    private override init() {
        super.init()
    }

    // MARK: - 显示

    /// 显示窗口；已存在就前置并刷新。只 `makeKeyAndOrderFront`，不做 `NSApp.activate`，
    /// 免得长时间抢走其他 App 的输入焦点。
    func show() {
        if Thread.isMainThread { showOnMain() } else { DispatchQueue.main.async { self.showOnMain() } }
    }

    private func showOnMain() {
        let window = ensureWindow()
        reload(keepSelection: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if window.frame.height < 420 || window.frame.width < 700 {
            window.setFrame(NSRect(x: window.frame.origin.x, y: window.frame.origin.y,
                                   width: 860, height: 600), display: true)
            window.center()
        }
    }

    /// 外部追加了一条之后的轻量刷新；窗没开就不用干活。
    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        reload(keepSelection: false)
    }

    // MARK: - 数据

    /// 存档里可能留着早先布局崩掉时的袖珍尺寸，显示后兜一次底
    private func repairSizeIfTiny(_ window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard window.frame.height < 420 || window.frame.width < 700 else { return }
            // 这里必须用 setFrame：setContentSize 会被窗口当前的布局约束吃掉，实测改不动。
            let frame = NSRect(x: window.frame.origin.x, y: window.frame.origin.y - (600 - 136),
                               width: 860, height: 600)
            window.setFrame(frame, display: true)
            window.center()
        }
    }

    private func reload(keepSelection: Bool) {
        // 一次读盘：先拿全量，再在内存里过滤，省掉搜索时每敲一键都重读文件。
        let all = HistoryStore.allRecords()
        let keyword = searchField.stringValue
        rows = HistoryStore.filterMatching(all, keyword: keyword)
        tableView.reloadData()

        let total = all.count
        countLabel.stringValue = keyword.isEmpty
            ? "共 \(total) 条"
            : "命中 \(rows.count) / \(total) 条"

        emptyLabel.isHidden = !rows.isEmpty
        statusLabel.stringValue = ""

        if rows.isEmpty {
            select(row: -1)
            return
        }
        let target = keepSelection ? min(max(tableView.selectedRows.first ?? 0, 0), rows.count - 1) : 0
        select(row: target)
    }

    private func select(row: Int) {
        guard row >= 0, row < rows.count else {
            tableView.deselectAll(nil)
            detailRecord = nil
            renderDetail(nil)
            updateButtonState()
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        detailRecord = rows[row]
        renderDetail(detailRecord)
        updateButtonState()
    }

    /// 详情区照 Bob 的结构重做：时间大标题 → 原文灰卡 → 语言对 → 译文卡（带引擎名）。
    /// 以前是一整块富文本，所有信息糊在几行里，看着像日志而不是"一条历史"。
    private func renderDetail(_ record: HistoryStore.Record?) {
        detailContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        detailRecord = record
        guard let record else { return }

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let title = NSTextField(labelWithString: formatFull(record.date))
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())

        let star = iconButton("star", help: "收藏这条", action: #selector(toggleFavoriteFromDetail))
        favoriteButton = star
        let trash = iconButton("trash", help: "删除这条", action: #selector(deleteSelected))
        header.addArrangedSubview(star)
        header.addArrangedSubview(trash)
        addFullWidth(header)

        // 原文卡
        let sourceCard = makeCard()
        let sourceText = NSTextField(wrappingLabelWithString: record.source)
        sourceText.font = NSFont.systemFont(ofSize: 13.5)
        sourceText.isSelectable = true
        sourceText.maximumNumberOfLines = 0
        sourceCard.addArrangedSubview(sourceText)
        sourceCard.addArrangedSubview(actionRow([
            ("speaker.wave.2", "朗读原文", #selector(speakSource)),
            ("doc.on.doc", "复制原文", #selector(copySource)),
        ]))
        addFullWidth(sourceCard)

        // 语言对
        let langRow = NSStackView()
        langRow.orientation = .horizontal
        langRow.alignment = .centerY
        langRow.spacing = 10
        langRow.addArrangedSubview(chip(Languages.name(for: LanguageDetector.detectLanguage(record.source))))
        let arrow = NSTextField(labelWithString: "»")
        arrow.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        arrow.textColor = .tertiaryLabelColor
        langRow.addArrangedSubview(arrow)
        langRow.addArrangedSubview(chip(Languages.name(for: record.targetLanguage)))
        langRow.addArrangedSubview(NSView())
        addFullWidth(langRow)

        // 译文卡（引擎名 + 图标）
        let resultCard = makeCard()
        let engineRow = NSStackView()
        engineRow.orientation = .horizontal
        engineRow.alignment = .centerY
        engineRow.spacing = 6
        let brand = CardTheme.serviceBadge(for: record.model, name: record.model)
        brand.translatesAutoresizingMaskIntoConstraints = false
        brand.widthAnchor.constraint(equalToConstant: 16).isActive = true
        brand.heightAnchor.constraint(equalToConstant: 16).isActive = true
        engineRow.addArrangedSubview(brand)
        let engineName = NSTextField(labelWithString: record.model.isEmpty ? "翻译结果" : record.model)
        engineName.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        engineName.textColor = .secondaryLabelColor
        engineRow.addArrangedSubview(engineName)
        engineRow.addArrangedSubview(NSView())
        resultCard.addArrangedSubview(engineRow)

        let resultText = NSTextField(wrappingLabelWithString: record.result)
        resultText.font = NSFont.systemFont(ofSize: 13.5)
        resultText.isSelectable = true
        resultText.maximumNumberOfLines = 0
        resultCard.addArrangedSubview(resultText)
        resultCard.addArrangedSubview(actionRow([
            ("speaker.wave.2", "朗读译文", #selector(speakResult)),
            ("doc.on.doc", "复制译文", #selector(copyResult)),
        ]))
        addFullWidth(resultCard)

        // 末尾塞一个弹性占位，把多余高度吃掉，别让原文卡被拉成一整屏
        let filler = NSView()
        filler.translatesAutoresizingMaskIntoConstraints = false
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        detailContainer.addArrangedSubview(filler)
        filler.heightAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true

        refreshFavoriteState()
        detailScrollView.documentView?.scroll(.zero)
        if let clip = detailScrollView.contentView.documentView {
            clip.scroll(NSPoint(x: 0, y: max(0, clip.frame.height - detailScrollView.contentView.bounds.height)))
        }
    }

    /// 详情里的每一块都横向铺满，避免 NSStackView 把内容压到最小宽度
    private func addFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: detailContainer.widthAnchor, constant: -8).isActive = true
    }

    private func makeCard() -> NSStackView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 8
        card.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        card.setContentHuggingPriority(.required, for: .vertical)
        card.setContentCompressionResistancePriority(.required, for: .vertical)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = CardTheme.sectionBackground.cgColor
        return card
    }

    private func chip(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.backgroundColor = CardTheme.sectionBackground.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
        ])
        return box
    }

    private func actionRow(_ items: [(String, String, Selector)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        for (symbol, help, action) in items {
            row.addArrangedSubview(iconButton(symbol, help: help, action: action))
        }
        row.addArrangedSubview(NSView())
        return row
    }

    private func iconButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func refreshFavoriteState() {
        guard favoriteButton != nil, let record = detailRecord else { return }
        let saved = FavoriteStore.contains(source: record.source)
        favoriteButton.image = NSImage(systemSymbolName: saved ? "star.fill" : "star",
                                       accessibilityDescription: saved ? "已收藏" : "收藏")
        favoriteButton.contentTintColor = saved ? .systemYellow : .secondaryLabelColor
    }

    @objc private func toggleFavoriteFromDetail() {
        guard let record = detailRecord else { return }
        if FavoriteStore.contains(source: record.source) {
            FavoriteStore.remove(source: record.source)
            flash("已取消收藏")
        } else {
            FavoriteStore.add(source: record.source, result: record.result, model: record.model,
                              targetLanguage: record.targetLanguage,
                              sourceLanguage: LanguageDetector.detectLanguage(record.source))
            flash("已收藏到收藏夹")
        }
        refreshFavoriteState()
    }

    @objc private func speakSource() {
        guard let record = detailRecord else { return }
        SpeechService.shared.speak(record.source)
    }

    @objc private func speakResult() {
        guard let record = detailRecord else { return }
        SpeechService.shared.speak(record.result)
    }

    @objc private func copySource() {
        guard let record = detailRecord else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.source, forType: .string)
        flash("已复制原文")
    }

    private func line(_ string: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - 动作

    private func currentRecord() -> HistoryStore.Record? {
        guard let index = tableView.selectedRows.first, index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    @objc private func copyResult() {
        guard let record = currentRecord() else {
            flash("先选中一条记录")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.result, forType: .string)
        flash("已复制译文（\(record.result.count) 字）")
    }

    @objc private func replay() {
        guard let record = currentRecord() else {
            flash("先选中一条记录")
            return
        }
        NotificationCenter.default.post(name: .localTranslateReplay, object: record.entry)
        flash("已交给翻译流程")
    }

    @objc private func deleteSelected() {
        guard let record = currentRecord() else {
            flash("先选中一条记录")
            return
        }
        // 用 Record.id 删；删前记下相邻位置，刷新后选不至于跳到顶上。
        let index = tableView.selectedRows.first ?? 0
        HistoryStore.remove(id: record.id)
        reload(keepSelection: false)
        if !rows.isEmpty { select(row: min(index, rows.count - 1)) }
        flash("已删除 1 条")
    }

    @objc private func clearAll() {
        let total = HistoryStore.allRecords().count
        guard total > 0 else {
            flash("历史已经是空的")
            return
        }
        let alert = NSAlert()
        alert.messageText = "清空全部翻译历史？"
        alert.informativeText = "共 \(total) 条记录，删除后无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                HistoryStore.clear()
                self?.reload(keepSelection: false)
                self?.flash("已清空 \(total) 条")
            }
        } else {
            HistoryStore.clear()
            reload(keepSelection: false)
            flash("已清空 \(total) 条")
        }
    }

    @objc private func revealInFinder() {
        let url = HistoryStore.fileURL
        let workspace = NSWorkspace.shared
        if FileManager.default.fileExists(atPath: url.path) {
            workspace.activateFileViewerSelecting([url])
            flash("已在 Finder 中显示 \(url.lastPathComponent)")
        } else {
            // 文件还没落盘（一次翻译都没有），退一步开目录。
            let dir = url.deletingLastPathComponent()
            workspace.open(dir)
            flash("历史文件还没生成，已打开 \(dir.path)")
        }
    }

    /// 搜索框边打字边过滤。
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        reload(keepSelection: false)
        if !rows.isEmpty { select(row: 0) }
    }

    private func updateButtonState() {
        let has = currentRecord() != nil
        copyButton?.isEnabled = has
        replayButton?.isEnabled = has
        deleteButton?.isEnabled = has
    }

    private func flash(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        statusClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusLabel.stringValue = ""
        }
        statusClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: - 建窗

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let content = NSView()

        let window = HistoryPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "翻译历史"
        window.delegate = self
        // 程序化建的窗默认关闭即释放，复用单例会被二次 show 打成野指针。
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.contentView = content
        // 不启用 setFrameAutosaveName：它会在窗口显示后的下一轮 RunLoop 把 frame 覆盖回去，
        // 存档里只要留过一次袖珍尺寸，就会永远卡成一条缝（实测反复出现）。
        // 尺寸固定、位置居中，稳定优先。
        window.setFrame(NSRect(x: 0, y: 0, width: 860, height: 600), display: false)
        window.center()

        buildUI(in: window, content: content)
        self.window = window
        return window
    }

    private func buildUI(in window: NSWindow, content: NSView) {
        // 搜索框
        searchField.placeholderString = "搜索原文或译文"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsSearchStringImmediately = true   // 边打字边过滤，不等回车
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.cell?.sendsActionOnEndEditing = false

        // 列表
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 80
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.onReturnPressed = { [weak self] in self?.copyResult() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        // 详情
        detailContainer.orientation = .vertical
        detailContainer.alignment = .leading
        detailContainer.spacing = 12
        detailContainer.edgeInsets = NSEdgeInsets(top: 10, left: 4, bottom: 16, right: 4)
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        let flipped = HistoryFlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = true
        flipped.addSubview(detailContainer)
        NSLayoutConstraint.activate([
            detailContainer.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 12),
            detailContainer.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -12),
            detailContainer.topAnchor.constraint(equalTo: flipped.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -8),
        ])
        detailScrollView.documentView = flipped
        detailScrollView.drawsBackground = false
        detailScrollView.hasVerticalScroller = true
        detailScrollView.drawsBackground = true
        detailScrollView.backgroundColor = .textBackgroundColor
        detailScrollView.borderType = .noBorder
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        dividerWindow.boxType = .separator
        dividerWindow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dividerWindow)

        // 底部条
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        copyButton = barButton("复制译文", #selector(copyResult))
        replayButton = barButton("重新翻译", #selector(replay))
        deleteButton = barButton("删除", #selector(deleteSelected))
        let clearButton = barButton("清空", #selector(clearAll))
        let finderButton = barButton("在 Finder 中显示", #selector(revealInFinder))

        let buttons = NSStackView(views: [copyButton, replayButton, deleteButton, clearButton, finderButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let vDivider = NSBox()
        vDivider.boxType = .separator
        vDivider.translatesAutoresizingMaskIntoConstraints = false

        let splitRow = NSStackView(views: [scrollView, vDivider, detailScrollView])
        splitRow.orientation = .horizontal
        splitRow.spacing = 10
        splitRow.distribution = .fill
        splitRow.translatesAutoresizingMaskIntoConstraints = false
        splitRow.setHuggingPriority(.defaultLow, for: .horizontal)
        splitRow.setHuggingPriority(.defaultLow, for: .vertical)

        content.addSubview(searchField)
        content.addSubview(splitRow)
        content.addSubview(emptyLabel)
        content.addSubview(countLabel)
        content.addSubview(statusLabel)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),

            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            splitRow.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            splitRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            splitRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            splitRow.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -10),

            scrollView.widthAnchor.constraint(equalToConstant: 320),
            vDivider.widthAnchor.constraint(equalToConstant: 1),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),

            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            countLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            countLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 150),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])

        // esc 关窗：cancelOperation 会被 NSTextField/NSSearchField 拦下，交给窗口兜底。
        window.initialFirstResponder = searchField
    }

    private func barButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.setButtonType(.momentaryPushIn)
        return button
    }

    // MARK: - 时间显示

    /// 列表用：今天 14:03 / 昨天 09:12 / 3月5日 14:03 / 2024年3月5日
    private func formatFriendly(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = stringFrom(date, "HH:mm")
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return "\(days)天前 \(time)"
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return stringFrom(date, "M月d日 HH:mm")
        }
        return stringFrom(date, "yyyy年M月d日")
    }

    /// 详情用：带完整日期，省得跨年记录看不出哪天。
    private func formatFull(_ date: Date) -> String {
        let calendar = Calendar.current
        let base = stringFrom(date, "M月d日 HH:mm:ss")
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return base }
        return stringFrom(date, "yyyy年M月d日 HH:mm:ss")
    }

    private func stringFrom(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func modeTitle(_ mode: String) -> String {
        switch mode {
        case "translate": return "翻译"
        case "polish": return "润色"
        case "summarize": return "总结"
        default: return mode.isEmpty ? "未知" : mode
        }
    }

    /// 列表里译文/原文的截断：交给 cell 的行数和 lineBreakMode 做，这里只挡超长文本，
    /// 免得给一个 5 万字的段落做排版。
    private func clip(_ string: String, _ limit: Int) -> String {
        let collapsed = string.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        statusClearWork?.cancel()
    }
}

// MARK: - 列表

extension HistoryWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("HistoryRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryRowView) ?? {
            let view = HistoryRowView()
            view.identifier = identifier
            return view
        }()

        cell.timeLabel.stringValue = formatFriendly(record.date)
        cell.sourceLabel.stringValue = clip(record.source, 160)
        cell.resultLabel.stringValue = clip(record.result, 320)

        var metaParts: [String] = [modeTitle(record.mode)]
        if !record.model.isEmpty { metaParts.append(record.model) }
        if let seconds = record.seconds { metaParts.append(String(format: "%.1fs", seconds)) }
        cell.metaLabel.stringValue = metaParts.joined(separator: "\n")

        // 选中态靠系统高亮，文字色用语义色自动跟随明暗主题。
        cell.sourceLabel.textColor = .labelColor
        cell.resultLabel.textColor = .secondaryLabelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === tableView else { return }
        let index = tableView.selectedRows.first ?? -1
        guard index >= 0, index < rows.count else {
            detailRecord = nil
            renderDetail(nil)
            updateButtonState()
            return
        }
        detailRecord = rows[index]
        renderDetail(detailRecord)
        updateButtonState()
    }
}

/// 一行历史记录的时间 / 原文 / 译文 / 右侧标注。
private final class HistoryRowView: NSTableCellView {
    let timeLabel = NSTextField(labelWithString: "")
    let sourceLabel = NSTextField(labelWithString: "")
    let resultLabel = NSTextField(labelWithString: "")
    let metaLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        timeLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.lineBreakMode = .byTruncatingTail

        sourceLabel.font = NSFont.systemFont(ofSize: 12.5)
        sourceLabel.textColor = .labelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.usesSingleLineMode = true
        sourceLabel.cell?.wraps = false
        sourceLabel.cell?.isScrollable = false

        resultLabel.font = NSFont.systemFont(ofSize: 12)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.maximumNumberOfLines = 2
        resultLabel.cell?.wraps = true
        resultLabel.cell?.truncatesLastVisibleLine = true

        metaLabel.font = NSFont.systemFont(ofSize: 10.5)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.alignment = .right
        metaLabel.maximumNumberOfLines = 3
        metaLabel.lineBreakMode = .byTruncatingTail

        let left = NSStackView(views: [timeLabel, sourceLabel, resultLabel])
        left.orientation = .vertical
        left.alignment = .width          // 三行都铺满左列宽度，靠截断而不是把行撑宽
        left.spacing = 3
        left.distribution = .fill
        left.translatesAutoresizingMaskIntoConstraints = false
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let right = NSStackView(views: [metaLabel])
        right.orientation = .vertical
        right.alignment = .trailing
        right.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .top
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            // 右列固定宽度，左列吃掉剩下的空间 → 原文/译文一定会被截断而不是溢出。
            metaLabel.widthAnchor.constraint(equalToConstant: 128),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 负责吃掉回车键（回车 = 复制选中条的译文），其余按键照常走 NSTableView。
final class HistoryTableView: NSTableView {
    var onReturnPressed: (() -> Void)?

    /// NSTableView 只暴露单选的 selectedRow，这里补一个数组视图，
    /// 让上面那些 `selectedRows.first` 的写法成立。
    var selectedRows: [Int] {
        let row = selectedRow
        return row >= 0 ? [row] : []
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onReturnPressed?()
            return
        }
        super.keyDown(with: event)
    }
}

/// esc 关窗：响应链末尾落到窗口，这里兜住 `cancelOperation`。
/// 搜索框里的 esc 由 NSSearchFieldCell 自己消化（先清关键词），不会走到这里。
private final class HistoryPanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

// MARK: - 通知

extension Notification.Name {
    /// 历史窗口里的「重新翻译」。object 是 `HistoryEntry`。
    /// 注意和 ResultPanel 的 `.localTranslateRetry` 不是一回事：retry 是重跑当前面板那次请求，
    /// replay 是把历史里挑中的那条重新送进翻译流程。
    static let localTranslateReplay = Notification.Name("LocalTranslateReplay")
}


/// 顶部对齐的容器（详情区内容从顶部开始排）
final class HistoryFlippedView: NSView {
    override var isFlipped: Bool { true }

    /// documentView 自己管尺寸：宽度跟随 clip view，高度等于内容高度。
    /// 用约束把 documentView 钉到 clipView 上会触发 AppKit 的布局循环（实测直接卡死）。
    override func layout() {
        super.layout()
        guard let clip = superview else { return }
        var size = frame.size
        if abs(size.width - clip.bounds.width) > 0.5 { size.width = clip.bounds.width }
        if let content = subviews.first {
            let height = max(content.fittingSize.height + 16, clip.bounds.height)
            if abs(size.height - height) > 0.5 { size.height = height }
        }
        if size != frame.size { frame.size = size }
    }
}
