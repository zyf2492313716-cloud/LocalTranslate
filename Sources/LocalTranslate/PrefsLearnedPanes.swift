import AppKit

// MARK: - OCR 设置

/// 对应 Bob 侧边栏「OCR 设置」：识别引擎 + 行为开关。
/// 这些开关以前只存在于 Config 里、没有任何界面入口，等于白写。
final class OcrSettingsPane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("识别引擎",
            note: "离线识别用系统 Vision，不联网也不花钱；其它引擎需要先填密钥。"))

        let engine = NSPopUpButton(frame: .zero, pullsDown: false)
        engine.addItems(withTitles: OcrEngine.allCases.map(\.title))
        if let index = OcrEngine.allCases.firstIndex(where: { $0.rawValue == draft.ocrEngine }) {
            engine.selectItem(at: index)
        }
        engine.target = self
        engine.action = #selector(pickEngine(_:))
        stack.addArrangedSubview(PrefsKit.row("识别引擎", engine,
            note: "改完下一次截图识别就生效。"))

        stack.addArrangedSubview(PrefsKit.sectionTitle("行为"))

        let (continuous, _) = PrefsKit.toggleRow("连续识别", isOn: draft.ocrContinuous,
            note: "开启后，新识别的内容会接在上一次结果后面，方便连续截多段。",
            target: self, action: #selector(toggleContinuous(_:)))
        stack.addArrangedSubview(continuous)

        let (autoCopy, _) = PrefsKit.toggleRow("识别完自动复制", isOn: draft.ocrAutoCopy,
            note: "识别结果直接进剪贴板，不用再按 ⌘C。",
            target: self, action: #selector(toggleAutoCopy(_:)))
        stack.addArrangedSubview(autoCopy)

        let (review, _) = PrefsKit.toggleRow("先预览再翻译", isOn: draft.ocrReviewBeforeTranslate,
            note: "关闭时是「即截即翻」：框选完直接出译文；开启会先给你一个可编辑的识别结果窗。",
            target: self, action: #selector(toggleReview(_:)))
        stack.addArrangedSubview(review)

        let (lock, _) = PrefsKit.toggleRow("锁定上次框选区域", isOn: draft.ocrLockArea,
            note: "同一个位置反复截图时，省掉每次拖框。",
            target: self, action: #selector(toggleLock(_:)))
        stack.addArrangedSubview(lock)
    }

    @objc private func pickEngine(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        let engine = OcrEngine.allCases[min(index, OcrEngine.allCases.count - 1)]
        change { $0.ocrEngine = engine.rawValue }
    }

    @objc private func toggleContinuous(_ sender: NSButton) { change { $0.ocrContinuous = sender.state == .on } }
    @objc private func toggleAutoCopy(_ sender: NSButton) { change { $0.ocrAutoCopy = sender.state == .on } }
    @objc private func toggleReview(_ sender: NSButton) { change { $0.ocrReviewBeforeTranslate = sender.state == .on } }
    @objc private func toggleLock(_ sender: NSButton) { change { $0.ocrLockArea = sender.state == .on } }
}

// MARK: - OCR 服务

/// 对应 Bob「OCR 服务」：列出可用识别引擎和它们的配置状态。
final class OcrServicesPane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("可用识别引擎",
            note: "打勾的是当前使用的那一个。只有「离线文本识别」开箱即用。"))

        for engine in OcrEngine.allCases {
            let configured = engine == .system || engine == .llm || !SecretStore.shared.apiKey(for: engine.rawValue).isEmpty
            let mark = engine.rawValue == draft.ocrEngine ? "●" : (configured ? "○" : "·")
            let color: NSColor = engine.rawValue == draft.ocrEngine ? .controlAccentColor
                : (configured ? .labelColor : .tertiaryLabelColor)
            let note: String
            switch engine {
            case .system: note = "系统 Vision，离线、免密钥，中英日韩都能认"
            case .llm: note = "用当前对话模型识图，适合复杂版面，需要模型支持图片"
            default: note = configured ? "已填密钥" : "需要密钥，去「导入导出」旁的配置文件里填，或先用离线识别"
            }
            stack.addArrangedSubview(PrefsKit.statusLine(symbol: mark, color: color,
                                                          text: "\(engine.title) —— \(note)"))
        }

        let useSystem = NSButton(title: "改用离线识别", target: self, action: #selector(useSystem))
        useSystem.bezelStyle = .rounded
        useSystem.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([useSystem], trailing: false))

        stack.addArrangedSubview(PrefsKit.sectionTitle("Bob OCR 插件",
            note: "community 里有不少 OCR 插件（如 mac-ocr-http）。插件列表页装好后，这里会显示识别能力。"))
        let plugins = PluginRuntime.installed().filter { $0 != "example.js" }
        if plugins.isEmpty {
            stack.addArrangedSubview(PrefsKit.statusLine(symbol: "info.circle", color: .secondaryLabelColor,
                                                          text: "还没装插件。菜单栏 →「安装 Bob 插件」可导入 .bobplugin。"))
        } else {
            stack.addArrangedSubview(PrefsKit.statusLine(symbol: "puzzlepiece.extension", color: .secondaryLabelColor,
                                                          text: "已安装 \(plugins.count) 个插件：\(plugins.joined(separator: "、"))"))
        }
    }

    @objc private func useSystem() { change { $0.ocrEngine = OcrEngine.system.rawValue } }
}

// MARK: - 插件列表

/// 对应 Bob「插件列表」：装了什么、能不能翻/识别/朗读、怎么删。
final class PluginListPane: PrefsPane {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [(name: String, title: String, category: String, summary: String)] = []

    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("已安装插件",
            note: "Bob 的 .bobplugin 直接丢进来就能用；翻译类插件会出现在「服务」页的服务商下拉里。"))

        table.headerView = nil
        table.rowHeight = 62
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        stack.addArrangedSubview(scroll)

        let install = NSButton(title: "安装插件…", target: self, action: #selector(installPlugin))
        install.bezelStyle = .rounded
        install.controlSize = .small
        let folder = NSButton(title: "打开插件目录", target: self, action: #selector(openFolder))
        folder.bezelStyle = .rounded
        folder.controlSize = .small
        let remove = NSButton(title: "删除选中", target: self, action: #selector(removeSelected))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([install, folder, remove], trailing: false))

        stack.addArrangedSubview(PrefsKit.statusLine(symbol: "network", color: .secondaryLabelColor,
            text: "从 bobplugin.ripperhe.com 下载 .bobplugin 后点「安装插件…」即可。"))
        reload()
    }

    private func reload() {
        rows = PluginRuntime.installed().map { name in
            let dir = PluginRuntime.directory.appendingPathComponent(name)
            let infoURL = dir.appendingPathComponent("info.json")
            if let data = try? Data(contentsOf: infoURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (name,
                        object["name"] as? String ?? name,
                        object["category"] as? String ?? "translate",
                        object["summary"] as? String ?? "")
            }
            return (name, name, "translate", "单文件 JS 插件")
        }
        table.reloadData()
    }

    @objc private func installPlugin() {
        (NSApp.delegate as? AppDelegate)?.installBobPlugin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.reload() }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: PluginRuntime.directory.path)
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        let name = rows[row].name
        try? FileManager.default.removeItem(at: PluginRuntime.directory.appendingPathComponent(name))
        reload()
    }
}

extension PluginListPane: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let title = NSTextField(labelWithString: "\(item.title)")
        title.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let badge = NSTextField(labelWithString: "\(item.category) · \(item.name)")
        badge.font = NSFont.systemFont(ofSize: 10.5)
        badge.textColor = .secondaryLabelColor
        let summary = NSTextField(labelWithString: item.summary)
        summary.font = NSFont.systemFont(ofSize: 10.5)
        summary.textColor = .tertiaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, badge, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        return stack
    }
}

// MARK: - 收藏夹（内嵌列表）

/// Bob 的收藏夹在侧边栏里点开就是列表；我们原来只能弹独立小窗。
final class FavoritesPane: PrefsPane {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let search = NSSearchField()
    private var rows: [FavoriteEntry] = []
    private let countLabel = NSTextField(labelWithString: "")

    override func configure(_ stack: NSStackView) {
        search.placeholderString = "搜索原文或译文"
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        let searchHint = NSTextField(wrappingLabelWithString: "搜索框支持按原文或译文过滤。")
        searchHint.font = NSFont.systemFont(ofSize: 11)
        searchHint.textColor = .tertiaryLabelColor
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(search)

        table.headerView = nil
        table.rowHeight = 58
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fav"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        stack.addArrangedSubview(searchHint)
        stack.addArrangedSubview(scroll)

        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(countLabel)

        let copy = NSButton(title: "复制译文", target: self, action: #selector(copySelected))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        let remove = NSButton(title: "删除", target: self, action: #selector(deleteSelected))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        let open = NSButton(title: "打开独立窗口", target: self, action: #selector(openWindow))
        open.bezelStyle = .rounded
        open.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([copy, remove, open], trailing: false))

        stack.addArrangedSubview(PrefsKit.statusLine(symbol: "star", color: .secondaryLabelColor,
            text: "翻译卡片上按 ⌘S 或点星标即可收藏到这里。"))
        reload()
    }

    private func reload() {
        let keyword = search.stringValue.lowercased()
        let all = FavoriteStore.all()
        rows = keyword.isEmpty ? all : all.filter {
            $0.source.lowercased().contains(keyword) || $0.result.lowercased().contains(keyword)
        }
        countLabel.stringValue = keyword.isEmpty ? "共 \(rows.count) 条收藏" : "命中 \(rows.count) / \(all.count) 条"
        table.reloadData()
    }

    @objc private func copySelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows[table.selectedRow].result, forType: .string)
    }

    @objc private func deleteSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        FavoriteStore.remove(id: rows[table.selectedRow].id)
        reload()
    }

    @objc private func openWindow() { FavoriteWindow.shared.show() }
}

extension FavoritesPane: NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let src = NSTextField(labelWithString: item.source)
        src.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        src.lineBreakMode = .byTruncatingTail
        let res = NSTextField(labelWithString: item.result)
        res.font = NSFont.systemFont(ofSize: 11)
        res.textColor = .secondaryLabelColor
        res.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [src, res])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        return stack
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
}

// MARK: - 功能增强

/// 对应 Bob「功能增强」：那些不属于翻译/OCR 主流程、但很香的开关。
final class EnhancePane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("取词与联动",
            note: "这些开关直接改变用起来的顺手程度。"))

        let (autoTranslate, _) = PrefsKit.toggleRow("选中即翻", isOn: draft.autoTranslateSelection,
            note: "选中文字后自动弹出翻译，不用按快捷键。",
            target: self, action: #selector(toggleAutoTranslate(_:)))
        stack.addArrangedSubview(autoTranslate)

        let (toolbar, _) = PrefsKit.toggleRow("选中后显示小工具条", isOn: draft.showSelectionToolbar,
            note: "选中文字时在光标旁显示「翻/朗/搜」三个小按钮。",
            target: self, action: #selector(toggleToolbar(_:)))
        stack.addArrangedSubview(toolbar)

        let (autoSpeak, _) = PrefsKit.toggleRow("翻译完成自动朗读", isOn: draft.autoSpeakWhenDone,
            note: "适合练听力和检查外语发音；会占用系统语音。",
            target: self, action: #selector(toggleAutoSpeak(_:)))
        stack.addArrangedSubview(autoSpeak)

        stack.addArrangedSubview(PrefsKit.sectionTitle("文本处理"))

        let (pdf, _) = PrefsKit.toggleRow("合并 PDF 换行", isOn: draft.mergePDFNewlines,
            note: "从 PDF 复制的文本每行都有硬换行，开启后会先拼成整段再翻。",
            target: self, action: #selector(togglePDF(_:)))
        stack.addArrangedSubview(pdf)

        let (code, _) = PrefsKit.toggleRow("拆分代码命名", isOn: draft.splitCodeIdentifiers,
            note: "getUserName 这类标识符会拆成 get user name 再翻。",
            target: self, action: #selector(toggleCode(_:)))
        stack.addArrangedSubview(code)

        let (merge, _) = PrefsKit.toggleRow("自动切换目标语言", isOn: draft.autoSwitchLanguage,
            note: "中文进来就译成英文，外文进来就译成中文。",
            target: self, action: #selector(toggleAutoSwitch(_:)))
        stack.addArrangedSubview(merge)
    }

    @objc private func toggleAutoTranslate(_ b: NSButton) { change { $0.autoTranslateSelection = b.state == .on } }
    @objc private func toggleToolbar(_ b: NSButton) { change { $0.showSelectionToolbar = b.state == .on } }
    @objc private func toggleAutoSpeak(_ b: NSButton) { change { $0.autoSpeakWhenDone = b.state == .on } }
    @objc private func togglePDF(_ b: NSButton) { change { $0.mergePDFNewlines = b.state == .on } }
    @objc private func toggleCode(_ b: NSButton) { change { $0.splitCodeIdentifiers = b.state == .on } }
    @objc private func toggleAutoSwitch(_ b: NSButton) { change { $0.autoSwitchLanguage = b.state == .on } }
}

// MARK: - 集成

/// 对应 Bob「集成」：把能力暴露给别的工具。
final class IntegrationPane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("URL Scheme",
            note: "任何能发链接的地方都能调起 LocalTranslate。"))

        for line in [
            "localtranslate://translate?text=hello&target=zh-Hans&copy=1",
            "localtranslate://input",
            "localtranslate://screenshot",
            "localtranslate://dictionary?word=pressure",
            "localtranslate://favorites",
            "localtranslate://history",
            "localtranslate://speak?text=hello",
            "localtranslate://settings",
        ] {
            let label = NSTextField(labelWithString: line)
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            label.isSelectable = true
            stack.addArrangedSubview(label)
        }

        stack.addArrangedSubview(PrefsKit.sectionTitle("AppleScript",
            note: "把下面这段放进「快捷指令」或脚本里即可。" ))
        let script = """
        do shell script "open 'localtranslate://translate?text=Hello&copy=1'"
        delay 1.5
        the clipboard
        """
        let scriptView = NSTextField(wrappingLabelWithString: script)
        scriptView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scriptView.isSelectable = true
        stack.addArrangedSubview(scriptView)

        let copyScript = NSButton(title: "复制脚本", target: self, action: #selector(copyScriptAction))
        copyScript.bezelStyle = .rounded
        copyScript.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([copyScript], trailing: false))

        stack.addArrangedSubview(PrefsKit.sectionTitle("其它工具",
            note: "PopClip / Raycast / Magpie 都可以用上面的 URL 接进来。"))
        stack.addArrangedSubview(PrefsKit.statusLine(symbol: "checkmark.seal", color: .secondaryLabelColor,
            text: "Magpie 本地网关：在「服务」页添加服务时选 Magpie，会自动发现本机模型。"))
    }

    @objc private func copyScriptAction() {
        let script = """
        do shell script "open 'localtranslate://translate?text=Hello&copy=1'"
        delay 1.5
        the clipboard
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
    }
}
