import AppKit

/// 偏好窗的一节。分组方式和 Bob 一致：按用途分成几组，每组里若干节。
enum PrefsSection: Int, CaseIterable {
    // 分组和条目顺序都照 Bob 的侧边栏来：翻译 / OCR / 插件 / 通用
    case translation    // 翻译设置
    case services       // 服务
    case dictionary     // 词典（Bob 没有，我们自己加的）
    case favorites      // 收藏夹
    case history        // 历史记录
    case ocrSettings    // OCR 设置
    case ocrServices    // OCR 服务
    case plugins        // 插件列表
    case hotkeys        // 快捷键
    case appearance     // 外观与行为
    case enhance        // 功能增强
    case integration    // 集成
    case permissions    // 权限与诊断
    case transfer       // 导入导出
    case about          // 关于

    var group: String {
        switch self {
        case .translation, .services, .dictionary, .favorites, .history: return "翻译"
        case .ocrSettings, .ocrServices: return "OCR"
        case .plugins: return "插件"
        case .hotkeys, .appearance, .enhance, .integration,
             .permissions, .transfer, .about: return "通用"
        }
    }

    var title: String {
        switch self {
        case .services: return "服务"
        case .translation: return "翻译设置"
        case .favorites: return "收藏夹"
        case .ocrSettings: return "OCR 设置"
        case .ocrServices: return "OCR 服务"
        case .plugins: return "插件列表"
        case .enhance: return "功能增强"
        case .integration: return "集成"
        case .dictionary: return "词典"
        case .hotkeys: return "快捷键"
        case .appearance: return "外观与行为"
        case .permissions: return "权限与诊断"
        case .history: return "历史记录"
        case .transfer: return "导入导出"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .services: return "square.stack.3d.up"
        case .translation: return "character.bubble"
        case .favorites: return "star"
        case .ocrSettings: return "text.viewfinder"
        case .ocrServices: return "text.magnifyingglass"
        case .plugins: return "puzzlepiece.extension"
        case .enhance: return "wand.and.stars"
        case .integration: return "link"
        case .dictionary: return "character.book.closed"
        case .hotkeys: return "keyboard"
        case .appearance: return "paintpalette"
        case .permissions: return "checkmark.shield"
        case .history: return "clock.arrow.circlepath"
        case .transfer: return "square.and.arrow.up.on.square"
        case .about: return "info.circle"
        }
    }

    /// 自检时要求这一节里必须出现的文字
    var testKeys: [String] {
        switch self {
        case .services: return ["显示名", "服务商", "测试连接", "恢复免密默认"]
        case .translation: return ["目标语言", "源语言", "默认模式", "请求超时"]
        case .dictionary: return ["查词典", "词组"]
        case .hotkeys: return ["划词翻译", "静默翻译并复制", "双击 Option"]
        case .appearance: return ["主题", "正文字号", "取词", "开机自动启动"]
        case .permissions: return ["辅助功能", "签名身份", "钥匙串", "已注册的快捷键", "Apple 翻译语言包"]
        case .history: return ["保留翻译历史", "最多留", "清空全部"]
        case .favorites: return ["搜索框支持", "复制译文"]
        case .ocrSettings: return ["识别引擎", "连续识别", "自动复制", "先预览再翻译"]
        case .ocrServices: return ["可用识别引擎", "离线文本识别"]
        case .plugins: return ["已安装插件", "安装插件", "打开插件目录"]
        case .enhance: return ["选中即翻", "合并 PDF 换行", "拆分代码命名"]
        case .integration: return ["localtranslate://", "AppleScript"]
        case .transfer: return ["导出配置", "导入配置"]
        case .about: return ["LocalTranslate", "版本"]
        }
    }

    var subtitle: String {
        switch self {
        case .services: return "翻译功能的核心服务配置，下方开启的服务会被一起调用并显示成对比标签。"
        case .translation: return "目标语言、源语言、默认模式、接口超时这些影响每一次请求的设置。"
        case .dictionary: return "选中的是单词或词组时，额外问一次模型要一份结构化词典数据。"
        case .hotkeys: return "点击输入框后按下新组合键。改完要带上 ⌘ / ⌥ / ⌃ 之一，否则会抢普通打字。"
        case .appearance: return "卡片的外观、字号和取词方式。"
        case .permissions: return "辅助功能权限决定能不能读到你选中的文字，签名身份决定授权会不会在升级后还在。"
        case .history: return "翻译记录存在本地文件里，可以搜索、重跑和导出。"
        case .favorites: return "星标收藏的译文都在这里，支持搜索、复制和删除。"
        case .ocrSettings: return "识别引擎和识别行为：连续识别、自动复制、先预览再翻译。"
        case .ocrServices: return "有哪些识别引擎可用、哪些还缺密钥。"
        case .plugins: return "Bob 的 .bobplugin 插件管理：装了什么、能干什么、怎么删。"
        case .enhance: return "取词联动和文本处理里那些提高手感的小开关。"
        case .integration: return "把 LocalTranslate 接进快捷指令、Raycast、PopClip 等工具。"
        case .transfer: return "换机器时把配置导出去，密钥默认不带。"
        case .about: return "版本与自检。"
        }
    }
}

/// Bob 那套结构的偏好窗：左侧分组列表，右侧「标题 + 副标题 + 内容」，底部撤销/保存。
final class PreferencesWindow: NSObject, NSWindowDelegate {

    static let shared = PreferencesWindow()

    private var window: NSWindow?
    private var sidebar: NSTableView!
    private var detailTitle: NSTextField!
    private var detailSubtitle: NSTextField!
    private var contentHolder: NSView!
    private var contentScroll: NSScrollView!
    private var undoButton: NSButton!
    private var saveButton: NSButton!
    private var statusLabel: NSTextField!

    /// 面板里做完一次即时保存后提示一句（插件设置这类不走草稿）
    func flashSaved(_ message: String) {
        statusLabel?.stringValue = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.statusLabel?.stringValue == message { self?.statusLabel?.stringValue = "" }
        }
    }

    private var draft = PrefsDraft.load()
    private var selected: PrefsSection = .services
    /// 每个节缓存「面板对象 + 它的根视图」。
    /// 必须连面板对象一起留着：它是表格/文本框的 dataSource/delegate，
    /// 而 AppKit 对这些是弱引用。只留视图的话面板一返回就被释放，
    /// 表格拿不到数据源，表现就是「控件都在，一行都不显示」。
    private var paneCache: [PrefsSection: (pane: PrefsPane, view: NSView)] = [:]
    private var accessibilityTimer: Timer?

    private override init() {}

    // MARK: - 显示

    func show(section: PrefsSection? = nil) {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.draft = PrefsDraft.load()
            self.paneCache.removeAll()
            self.select(section ?? .services)
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 卡片上的设置图标点进来时，直接落到服务页
    func showSettings() { show(section: .services) }

    // MARK: - 建窗

    private func ensureWindow() {
        guard window == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalTranslate 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.minSize = NSSize(width: 780, height: 520)

        // 侧栏
        sidebar = NSTableView()
        sidebar.headerView = nil
        sidebar.rowHeight = 26
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.style = .sourceList
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.resizingMask = .autoresizingMask
        sidebar.addTableColumn(column)
        sidebar.dataSource = self
        sidebar.delegate = self

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.backgroundColor = .clear

        // 右栏：标题 + 副标题 + 内容
        detailTitle = NSTextField(labelWithString: "")
        detailTitle.font = NSFont.systemFont(ofSize: 22, weight: .bold)

        detailSubtitle = NSTextField(wrappingLabelWithString: "")
        detailSubtitle.font = NSFont.systemFont(ofSize: 12)
        detailSubtitle.textColor = .secondaryLabelColor
        detailSubtitle.isSelectable = false

        let openHelp = NSButton(title: "使用教程", target: self, action: #selector(openHomepage))
        openHelp.bezelStyle = .rounded
        openHelp.controlSize = .small

        let headerLeft = NSStackView(views: [detailTitle, detailSubtitle])
        headerLeft.orientation = .vertical
        headerLeft.alignment = .leading
        headerLeft.spacing = 4

        let header = NSStackView(views: [headerLeft, NSView(), openHelp])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 12

        contentHolder = NSView()
        contentHolder.translatesAutoresizingMaskIntoConstraints = false

        contentScroll = NSScrollView()
        contentScroll.documentView = flippedDoc()
        contentScroll.hasVerticalScroller = true
        contentScroll.drawsBackground = false
        contentScroll.borderType = .noBorder
        contentScroll.autoresizingMask = [.width, .height]

        let doc = contentScroll.documentView as! FlippedDoc
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentScroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: contentScroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: contentScroll.widthAnchor),
        ])
        doc.addSubview(contentHolder)
        NSLayoutConstraint.activate([
            contentHolder.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 22),
            contentHolder.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -22),
            contentHolder.topAnchor.constraint(equalTo: doc.topAnchor, constant: 12),
            contentHolder.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -22),
        ])

        let rightStack = NSStackView(views: [header, contentScroll])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 10
        rightStack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 0, right: 22)
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addSubview(sidebarScroll)
        split.addSubview(rightStack)
        split.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 176),
            sidebarScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 230),
            rightStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])

        // 底部：状态 + 撤销 + 保存
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        undoButton = NSButton(title: "撤销", target: self, action: #selector(undoChanges))
        undoButton.bezelStyle = .rounded
        undoButton.controlSize = .small

        saveButton = NSButton(title: "保存", target: self, action: #selector(saveChanges))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [statusLabel, NSView(), undoButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 22, bottom: 12, right: 22)

        let root = NSStackView(views: [split, footer])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.contentViewController = nil
        self.window = window
        refreshFooter()
    }

    private func flippedDoc() -> FlippedDoc { FlippedDoc() }

    // MARK: - 切换

    private func select(_ section: PrefsSection) {
        selected = section
        detailTitle.stringValue = section.title
        detailSubtitle.stringValue = section.subtitle
        if let row = PrefsSection.allCases.firstIndex(of: section) {
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebar.scrollRowToVisible(row)
        }
        contentHolder.subviews.forEach { $0.removeFromSuperview() }
        let entry = paneCache[section] ?? makePane(section)
        paneCache[section] = entry
        entry.view.translatesAutoresizingMaskIntoConstraints = false
        contentHolder.addSubview(entry.view)
        NSLayoutConstraint.activate([
            entry.view.leadingAnchor.constraint(equalTo: contentHolder.leadingAnchor),
            entry.view.trailingAnchor.constraint(equalTo: contentHolder.trailingAnchor),
            entry.view.topAnchor.constraint(equalTo: contentHolder.topAnchor),
            entry.view.bottomAnchor.constraint(equalTo: contentHolder.bottomAnchor),
            // 不允许面板横向超出可视区，否则右侧控件会被裁掉
            entry.view.widthAnchor.constraint(lessThanOrEqualTo: contentHolder.widthAnchor),
        ])
        contentScroll.contentView.scroll(to: NSPoint.zero)
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        refreshFooter()
    }

    private func makePane(_ section: PrefsSection) -> (pane: PrefsPane, view: NSView) {
        let pane: PrefsPane
        switch section {
        case .services: pane = ServicesPane(draft: draft, owner: self)
        case .translation: pane = TranslationPane(draft: draft, owner: self)
        case .dictionary: pane = DictionaryPane(draft: draft, owner: self)
        case .hotkeys: pane = HotkeysPane(draft: draft, owner: self)
        case .appearance: pane = AppearancePane(draft: draft, owner: self)
        case .permissions: pane = PermissionsPane(draft: draft, owner: self)
        case .history: pane = HistoryPane(draft: draft, owner: self)
        case .favorites: pane = FavoritesPane(draft: draft, owner: self)
        case .ocrSettings: pane = OcrSettingsPane(draft: draft, owner: self)
        case .ocrServices: pane = OcrServicesPane(draft: draft, owner: self)
        case .plugins: pane = PluginListPane(draft: draft, owner: self)
        case .enhance: pane = EnhancePane(draft: draft, owner: self)
        case .integration: pane = IntegrationPane(draft: draft, owner: self)
        case .transfer: pane = TransferPane(draft: draft, owner: self)
        case .about: pane = AboutPane(draft: draft, owner: self)
        }
        return (pane, pane.build())
    }

    // MARK: - 草稿同步

    /// 面板改完一项就调这里：丢掉缓存重画，并刷新撤销/保存的可用状态
    func mutate(_ block: (inout PrefsDraft) -> Void, rebuild: Bool = true) {
        block(&draft)
        if rebuild {
            paneCache[selected] = nil
            select(selected)
        }
        refreshFooter()
    }

    /// 当前这一节内容的实际布局尺寸，给自测量用。
    /// 量文档视图的高度才说明问题：光看某个子视图有没有高度会被窗口自身蒙过去。
    /// 面板里表格的行数。数据源被释放这类问题只会体现在这里，光看控件数量看不出来。
    private func tableRowsInPane() -> Int {
        guard let view = paneCache[selected]?.view else { return -1 }
        var total = 0
        func walk(_ v: NSView) {
            if let table = v as? NSTableView { total += table.numberOfRows }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return total
    }

    var contentMetricsForTesting: (docHeight: CGFloat, paneHeight: CGFloat, paneWidth: CGFloat, sizedControls: Int, tableRows: Int) {
        contentHolder.layoutSubtreeIfNeeded()
        let doc = contentScroll.documentView
        let pane = paneCache[selected]?.view
        pane?.layoutSubtreeIfNeeded()
        return (doc?.frame.height ?? 0, pane?.frame.height ?? 0, pane?.frame.width ?? 0,
                countSizedControls(pane), tableRowsInPane())
    }

    /// 把面板前两层的 frame 打出来，布局出问题时靠这个看，不用猜
    var contentLayoutDumpForTesting: String {
        guard let pane = paneCache[selected]?.view else { return "(没有面板)" }
        pane.layoutSubtreeIfNeeded()
        var lines: [String] = []
        func walk(_ view: NSView, _ depth: Int) {
            if depth > 3 { return }
            let pad = String(repeating: "  ", count: depth)
            let kind = String(describing: type(of: view))
            let f = view.frame
            lines.append(pad + kind + " " + String(Int(f.width)) + "x" + String(Int(f.height)) + "@(" + String(Int(f.minX)) + "," + String(Int(f.minY)) + ")")
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        walk(pane, 0)
        return lines.prefix(24).joined(separator: "\n")
    }

    /// 列出面板里可编辑文本框的当前值。用来确认表单真的把现有配置回填了，
    /// 而不是只显示了标签。
    var fieldValuesForTesting: [(label: String, value: String)] {
        guard let pane = paneCache[selected]?.view else { return [] }
        pane.layoutSubtreeIfNeeded()
        var out: [(String, String)] = []
        func walk(_ view: NSView, lastLabel: String) {
            var label = lastLabel
            if let text = view as? NSTextField, !text.isEditable, !text.stringValue.isEmpty {
                label = text.stringValue
            }
            if let field = view as? NSTextField, field.isEditable {
                out.append((label, field.stringValue))
            }
            for sub in view.subviews { walk(sub, lastLabel: label) }
        }
        walk(pane, lastLabel: "")
        return out
    }

    /// 真正有尺寸的控件个数。只量「视图存在」不够，控件被压成 0×0 也算没显示。
    private func countSizedControls(_ view: NSView?) -> Int {
        guard let view else { return 0 }
        var total = 0
        if view is NSButton || view is NSTextField || view is NSTableView || view is NSScrollView {
            if view.frame.width > 40, view.frame.height > 8 { total += 1 }
        }
        for sub in view.subviews { total += countSizedControls(sub) }
        return total
    }

    /// 只改值不重画（文本框输入时用，避免打字过程被重建打断）
    func touch(_ block: (inout PrefsDraft) -> Void) {
        block(&draft)
        refreshFooter()
    }

    private func refreshFooter() {
        let dirty = draft.isDirty()
        undoButton?.isEnabled = dirty
        saveButton?.isEnabled = dirty
    }

    @objc private func undoChanges() {
        draft = PrefsDraft.load()
        paneCache.removeAll()
        select(selected)
        statusLabel.stringValue = "已撤销未保存的改动"
    }

    @objc private func saveChanges() {
        let problem = draft.apply()
        paneCache.removeAll()
        select(selected)
        if let problem {
            statusLabel.stringValue = "已保存，但有提醒：\(problem)"
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "已保存"
            statusLabel.textColor = .secondaryLabelColor
        }
        NotificationCenter.default.post(name: .localTranslatePrefsSaved, object: nil)
    }

    /// 保存后让其它地方知道要重读配置
    func notifySaved() {
        NotificationCenter.default.post(name: .localTranslatePrefsSaved, object: nil)
    }

    @objc private func openHomepage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/nextai-translator/nextai-translator")!)
    }

    func windowWillClose(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    /// 权限页要盯着用户从系统设置回来的动作
    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        var last = AXIsProcessTrusted()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            let now = AXIsProcessTrusted()
            if now != last {
                last = now
                self?.paneCache[.permissions] = nil
                if self?.selected == .permissions { self?.select(.permissions) }
                NotificationCenter.default.post(name: PermissionState.didChange, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let localTranslatePrefsSaved = Notification.Name("LocalTranslatePrefsSaved")
}

final class FlippedDoc: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 侧栏数据

extension PreferencesWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { PrefsSection.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = PrefsSection.allCases[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)

        let label = NSTextField(labelWithString: section.title)
        label.font = NSFont.systemFont(ofSize: 12)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY

        // 分组标题：每组的第一个前面插一段小标题
        let wrapper = NSStackView()
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 2
        if row == 0 || PrefsSection.allCases[row - 1].group != section.group {
            let group = NSTextField(labelWithString: section.group)
            group.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            group.textColor = .tertiaryLabelColor
            wrapper.addArrangedSubview(group)
        }
        wrapper.addArrangedSubview(stack)
        wrapper.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        return wrapper
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let section = PrefsSection.allCases[row]
        let isFirstOfGroup = row == 0 || PrefsSection.allCases[row - 1].group != section.group
        return isFirstOfGroup ? 46 : 26
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < PrefsSection.allCases.count else { return }
        select(PrefsSection.allCases[row])
    }
}
