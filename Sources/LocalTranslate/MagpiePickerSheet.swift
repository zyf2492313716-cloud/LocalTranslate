import AppKit

/// 从 Magpie 的模型列表里挑几个加进来。
///
/// 做成一个 sheet：上面搜索、中间多选列表、下面「添加 N 个」。
/// Magpie 的模型可能有几十到几百个（我这边一屏就 60+），
/// 没有搜索的话光滚列表就能把人劝退。
final class MagpiePickerSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let models: [MagpieClient.Model]
    private var filtered: [MagpieClient.Model]
    private let onPick: ([MagpieClient.Model]) -> Void

    private var window: NSWindow?
    private var table: NSTableView!
    private var search: NSSearchField!
    private var addButton: NSButton!
    private var countLabel: NSTextField!

    init(models: [MagpieClient.Model], onPick: @escaping ([MagpieClient.Model]) -> Void) {
        self.models = models
        self.filtered = models
        self.onPick = onPick
        super.init()
        // 按钮在 init 里就建好：present() 只是把它摆进窗口。
        // 这样自测点的是界面上真正那个按钮，不是另造一个。
        let button = NSButton(title: "添加", target: self, action: #selector(confirm))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.isEnabled = false
        addButton = button
    }

    func present(in parent: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "从 Magpie 添加模型"
        window.isReleasedWhenClosed = false

        search = NSSearchField()
        search.placeholderString = "搜索模型名或供应商"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false

        countLabel = NSTextField(labelWithString: "共 \(models.count) 个模型")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.allowsMultipleSelection = true
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("m"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // addButton 在 init 里已建好，这里只摆位置

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let footer = NSStackView(views: [countLabel, NSView(), cancel, addButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(search)
        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        window.contentView = container
        self.window = window

        parent.beginSheet(window)
    }

    // MARK: 列表

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let model = filtered[row]

        let title = NSTextField(labelWithString: model.title)
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let sub = NSTextField(labelWithString: "\(model.provider)  ·  \(model.id)")
        sub.font = NSFont.systemFont(ofSize: 10)
        sub.textColor = .tertiaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let n = table.selectedRowIndexes.count
        addButton.isEnabled = n > 0
        addButton.title = n > 0 ? "添加 \(n) 个" : "添加"
    }

    func controlTextDidChange(_ notification: Notification) {
        let keyword = search.stringValue.trimmingCharacters(in: .whitespaces)
        if keyword.isEmpty {
            filtered = models
        } else {
            filtered = models.filter {
                $0.title.localizedCaseInsensitiveContains(keyword)
                    || $0.id.localizedCaseInsensitiveContains(keyword)
                    || $0.provider.localizedCaseInsensitiveContains(keyword)
            }
        }
        countLabel.stringValue = "共 \(filtered.count) 个模型"
        table.reloadData()
    }

    // MARK: - 自测入口
    // 靠点击验证容易受 AX 权限和窗口层级影响，这里把关键几步暴露出来直接验。

    var rowCountForTesting: Int { filtered.count }

    func titleForTesting(row: Int) -> String {
        filtered.indices.contains(row) ? filtered[row].title : ""
    }

    func filterForTesting(_ keyword: String) {
        filtered = keyword.isEmpty ? models : models.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.id.localizedCaseInsensitiveContains(keyword)
                || $0.provider.localizedCaseInsensitiveContains(keyword)
        }
    }

    /// 走真实按钮路径：先选中行，再触发 addButton 的 target/action，
    /// 而不是直接调回调。这样按钮没接上、action 没连、取选中取错都能被发现。
    @discardableResult
    func pressAddForTesting(_ rows: [Int]) -> [MagpieClient.Model] {
        pendingSelection = rows
        addButton?.isEnabled = true
        addButton?.performClick(nil)
        return lastHanded
    }

    /// 上一次交出去的条目（自测用）
    private(set) var lastHanded: [MagpieClient.Model] = []

    @discardableResult
    func confirmRowsForTesting(_ rows: [Int]) -> [MagpieClient.Model] {
        let picked = rows.compactMap { filtered.indices.contains($0) ? filtered[$0] : nil }
        guard !picked.isEmpty else { return [] }
        onPick(picked)
        return picked
    }

    // MARK: 动作

    /// 当前选中的行号。表格还没建出来时（自测）用记录下来的那份。
    private func selectedIndices() -> IndexSet {
        if let table, table.selectedRowIndexes.count > 0 { return table.selectedRowIndexes }
        return IndexSet(pendingSelection)
    }

    private var pendingSelection: [Int] = []

    @objc private func confirm() {
        let picked = selectedIndices().compactMap { filtered.indices.contains($0) ? filtered[$0] : nil }
        guard !picked.isEmpty else { return }
        lastHanded = picked
        close()
        onPick(picked)
    }

    @objc private func cancel() { close() }

    private func close() {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window?.orderOut(nil)
    }
}
