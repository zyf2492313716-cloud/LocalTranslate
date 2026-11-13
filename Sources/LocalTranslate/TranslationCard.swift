import AppKit
import AVFoundation

/// Bob 风格的翻译卡片。
///
/// 版式严格对齐 Bob 官方窗口（见《翻译窗口》文档标注图）：
///
/// ```
/// [钉住]                          [收藏][历史][截图][剪贴板][编辑][服务][设置]
/// ┌ 原文卡片 ──────────────────────────────────┐
/// │ With macOS Sonoma, work and play…          │
/// │ 🔊  ⧉   ( 识别为 英语 )                     │
/// └────────────────────────────────────────────┘
/// ┌ 语言栏 ────────────────────────────────────┐
/// │ 自动检测 ▼   ⇄   简体中文 ▼      [钉住服务] │
/// └────────────────────────────────────────────┘
/// ┌ 火山翻译 ─────────────────────────────── ▼ ┐
/// │ 译文…                                      │
/// │ 🔊  ⧉  ↵                                   │
/// └────────────────────────────────────────────┘
/// ┌ Google 翻译 ──────────────────────────── ▼ ┐
/// │ 译文…                                      │
/// └────────────────────────────────────────────┘
/// ```
///
/// 关键行为：**所有开启的服务同时显示**，每家一个独立卡片，不是一个标签页，
/// 这样某一家挂了也挡不住其它家的译文。
final class TranslationCard: NSObject {

    static let shared = TranslationCard()

    // MARK: - 对外回调

    /// 用户在卡片里改了原文，需要重新翻译（去抖后触发）
    var onReRequest: ((String) -> Void)?
    /// 点重试
    var onRetry: (() -> Void)?
    /// 打开历史
    var onOpenHistory: (() -> Void)?
    /// 打开设置
    var onOpenSettings: (() -> Void)?
    /// 某个模型跑完了（用于写历史、自动复制）
    var onCompleted: ((_ model: String, _ text: String, _ seconds: Double) -> Void)?

    // MARK: - 状态

    private(set) var isPinned = false
    private(set) var sourceText = ""
    private var mode: TranslateMode = .translate
    private var targetLanguage = "zh-Hans"

    /// 服务条目 id 的列表，顺序就是卡片顺序
    private var models: [String] = []
    /// id → 界面上显示的服务名
    private var displayNames: [String: String] = [:]
    private var activeModel = ""
    private var outcomes: [String: ModelOutcome] = [:]
    private var streams: [String: NSMutableString] = [:]
    private var thinks: [String: NSMutableString] = [:]
    private var dictionary: DictionaryResult?
    private var notice: String?

    private var panel: CardPanel?

    // MARK: - 视图

    private let body = NSStackView()
    private let toolbar = NSStackView()

    /// 原文（可编辑，支持 ⌘Z）
    let sourceView: NSTextView = {
        let tv = NSTextView()
        tv.allowsUndo = true
        return tv
    }()
    /// 主服务译文（第一家）。保留这个名字是因为外部/自测都在用它。
    let resultView = NSTextView()

    private let sourceCard = NSView()
    private let sourceScroll = NSScrollView()
    private let sourceActions = NSStackView()
    private let detectedPill = NSButton()

    private let langBar = NSView()
    private let sourceLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swapButton = NSButton()
    private let pinnedStack = NSStackView()

    private let resultsStack = FlippedStackView()
    private let resultsScroll = NSScrollView()

    private var serviceCards: [String: ServiceCardView] = [:]

    private let thinkToggleButton: NSButton = {
        let btn = NSButton(title: "▶ 思考过程", target: nil, action: nil)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        btn.contentTintColor = CardTheme.secondary
        btn.isHidden = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()
    private let thinkView = NSTextView()
    private let thinkScroll = NSScrollView()

    private let dictCard = NSView()
    private let dictContainer = NSView()

    private let hintLabel = NSTextField(labelWithString: "")
    private let hintBar = NSView()

    private var sourceHeight: NSLayoutConstraint!
    private var resultsHeight: NSLayoutConstraint!
    private var thinkHeight: NSLayoutConstraint!
    private var dictHeight: NSLayoutConstraint!

    private var pendingWidthConstraints: [NSLayoutConstraint] = []
    private var pinButton: NSButton?
    private var favoriteButton: NSButton?
    private var retranslateWork: DispatchWorkItem?
    private var hudWork: DispatchWorkItem?
    private var keyMonitor: Any?

    private override init() {
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 展示

    /// 卡片出现。取词已经由调用方读完，这里可以安全拿到焦点。
    func present(source: String, mode: TranslateMode, targetLanguage: String, profiles: [ServiceProfile]) {
        DispatchQueue.main.async {
            self.ensurePanel()
            self.sourceText = source
            self.mode = mode
            self.targetLanguage = targetLanguage
            self.models = profiles.map(\.id)
            self.displayNames = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
            self.activeModel = self.models.first ?? ""
            self.outcomes = [:]
            self.streams = [:]
            self.thinks = [:]
            self.dictionary = nil
            self.notice = nil

            // 选区经常带最后的换行，直接塞进文本框会多出一条空行 + 光标
            self.sourceView.string = source.trimmingCharacters(in: .whitespacesAndNewlines)
            self.thinkView.string = ""
            self.hintLabel.stringValue = Self.shortcutHint
            self.dictCard.isHidden = true
            self.thinkToggleButton.isHidden = true
            self.thinkScroll.isHidden = true
            self.rebuildAllServiceCards()
            self.refreshLanguageBar(target: targetLanguage, mode: mode)
            self.refreshDetectedPill(source: source)
            self.rebuildPinnedServices()

            self.isPinned = Config.shared.pinByDefault
            self.refreshPinIcon()
            self.panel?.level = Config.shared.alwaysOnTop ? .statusBar : .floating
            self.refreshFavoriteState()
            self.positionAndSize()
            self.panel?.orderFrontRegardless()
            self.panel?.makeKeyAndOrderFront(nil)
            self.panel?.makeFirstResponder(self.panel)
            // 必须在别的 App（Word / 浏览器）里也能拿到 key，否则 esc、⌘C 全都收不到，
            // 用户感觉就是"按了快捷键没反应"。激活之前先把自家其它窗口压到最底层，
            // 免得设置窗跟着一起翻到前面挡住用户正在看的文档。
            for w in NSApp.windows where w.isVisible && w !== self.panel
                && w.level.rawValue < NSWindow.Level.screenSaver.rawValue
                && w.className != "NSStatusBarWindow" {
                w.orderBack(nil)
            }
            NSApp.activate(ignoringOtherApps: true)

            // 同一轮里如果 close() 和 present() 都排上了，orderOut 可能后落地，
            // 结果就是"调用了但看不见"。这里补一次确认，不靠调用方注意顺序。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.panel != nil, self.panel?.isVisible == false else { return }
                self.positionAndSize()
                self.panel?.orderFrontRegardless()
            }
        }
    }

    /// 某个模型开始流式输出
    func beginStream(model: String) {
        DispatchQueue.main.async {
            self.streams[model] = NSMutableString()
            self.thinks[model] = NSMutableString()
            self.serviceCards[model]?.setStatus(color: CardTheme.accent, meta: "翻译中…")
            if model == self.models.first {
                self.renderResult(model: model, markdown: "")
            } else {
                self.serviceCards[model]?.setText(NSAttributedString(string: ""), width: self.contentWidth)
            }
            self.relayout()
        }
    }

    func appendDelta(model: String, piece: String) {
        DispatchQueue.main.async {
            self.streams[model, default: NSMutableString()].append(piece)
            let current = (self.streams[model]! as String)
            self.renderResult(model: model, markdown: current)
        }
    }

    func appendThink(model: String, piece: String) {
        DispatchQueue.main.async {
            self.thinks[model, default: NSMutableString()].append(piece)
            guard model == self.models.first, Config.shared.showThink else { return }
            self.thinkToggleButton.isHidden = false
            let collapsed = Config.shared.thinkCollapsed
            self.thinkToggleButton.title = collapsed ? "▶ 思考过程（点击展开）" : "▼ 思考过程（点击收起）"
            self.thinkScroll.isHidden = collapsed
            self.thinkView.string = self.thinks[model]! as String
            if !collapsed {
                self.thinkHeight.constant = min(max(
                    CardTheme.measure(NSAttributedString(string: self.thinkView.string, attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                    ]), width: self.contentWidth) + 12, 34), 120)
            }
            self.relayout()
        }
    }

    func complete(model: String, text: String, seconds: Double) {
        DispatchQueue.main.async {
            self.outcomes[model] = ModelOutcome(model: model, text: text, think: (self.thinks[model] ?? NSMutableString()) as String, seconds: seconds, error: nil)
            self.streams[model] = NSMutableString(string: text)
            let meta = self.attribution(model: model, seconds: seconds)
            self.serviceCards[model]?.setStatus(color: .systemGreen, meta: meta)
            self.renderResult(model: model, markdown: text)
            self.onCompleted?(model, text, seconds)
        }
    }

    func fail(model: String, message: String) {
        DispatchQueue.main.async {
            self.outcomes[model] = ModelOutcome(model: model, text: "", think: "", seconds: 0, error: message)
            self.serviceCards[model]?.setStatus(color: .systemRed, meta: "失败")
            self.serviceCards[model]?.setText(Self.errorText(message), width: self.contentWidth)
            self.relayout()
        }
    }

    /// 实时更新某个服务卡标题右侧的状态（长文分块进度用）
    func updateStatus(model: String, text: String) {
        DispatchQueue.main.async {
            self.serviceCards[model]?.setStatus(color: CardTheme.accent, meta: text)
        }
    }

    /// 把某个服务的卡片整条撤掉（例如 Apple 缺语言包时，不该留一张红色报错卡吓人）
    func removeService(model: String) {
        DispatchQueue.main.async {
            guard let view = self.serviceCards[model] else { return }
            view.removeFromSuperview()
            self.serviceCards.removeValue(forKey: model)
            self.models.removeAll { $0 == model }
            if self.models.isEmpty {
                self.flashHUD("这个语言方向暂时没有可用引擎")
            }
            self.relayout()
        }
    }

    /// 词典区块。Bob 里词典也是一个独立的卡片，跟着翻译结果一起排下来。
    func showDictionary(_ result: DictionaryResult?) {
        DispatchQueue.main.async {
            guard let result, !result.isEmpty else {
                self.dictCard.isHidden = true
                self.dictionary = nil
                self.relayout()
                return
            }
            self.dictionary = result
            for subview in self.dictContainer.subviews { subview.removeFromSuperview() }
            let block = DictionaryView.make(result)
            block.translatesAutoresizingMaskIntoConstraints = false
            self.dictContainer.addSubview(block)
            NSLayoutConstraint.activate([
                block.leadingAnchor.constraint(equalTo: self.dictContainer.leadingAnchor),
                block.trailingAnchor.constraint(equalTo: self.dictContainer.trailingAnchor),
                block.topAnchor.constraint(equalTo: self.dictContainer.topAnchor),
                block.bottomAnchor.constraint(equalTo: self.dictContainer.bottomAnchor),
            ])
            self.dictCard.isHidden = false
            self.dictHeight.constant = Self.measureDictionary(block)
            self.relayout()
        }
    }

    /// 左下角一闪而过的确认文字，比如"已复制"
    func flashHUD(_ message: String) {
        DispatchQueue.main.async {
            self.hintLabel.stringValue = message
            self.hudWork?.cancel()
            self.hudWork = DispatchWorkItem { [weak self] in
                guard let self, self.hintLabel.stringValue == message else { return }
                self.hintLabel.stringValue = Self.shortcutHint
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: self.hudWork!)
        }
    }

    func close() {
        DispatchQueue.main.async {
            self.retranslateWork?.cancel()
            self.panel?.orderOut(nil)
        }
    }

    /// 失焦时的收窗策略：钉住不收；App 在后台被抽走 key 也不收（那不是用户主动切走）。
    /// 抽出来是为了能被自测直接调用，行为只有一份实现。
    func handleResignKey() {
        guard !isPinned else { return }
        guard NSApp.isActive else { return }
        close()
    }

    func togglePin() {
        isPinned.toggle()
        // 固定之后必须浮在别的窗口上面，否则"钉住"只是不关闭、却被 Word/浏览器挡住，
        // 用户看到的就是"钉了个寂寞"。
        panel?.level = isPinned ? .floating : .normal
        panel?.hidesOnDeactivate = false
        refreshPinIcon()
        flashHUD(isPinned ? "已固定：浮在最上层，再按 ⌘P 取消" : "已取消固定")
    }

    private func refreshPinIcon() {
        guard let button = pinButton else { return }
        button.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: "固定")
        button.image?.isTemplate = true
        button.contentTintColor = isPinned ? CardTheme.accent : nil
    }

    // MARK: - 渲染

    private func renderResult(model: String, markdown: String) {
        let attributed = Self.formatAttributed(markdown, size: CGFloat(Config.shared.fontSize))
        if let outcome = outcomes[model], let error = outcome.error {
            serviceCards[model]?.setText(Self.errorText(error), width: contentWidth)
        } else if let card = serviceCards[model] {
            card.setText(attributed, width: contentWidth)
        }
        relayout()
    }

    private static func formatAttributed(_ markdown: String, size: CGFloat) -> NSAttributedString {
        if Config.shared.renderMarkdown {
            return MarkdownLite.attributed(markdown, fontSize: size,
                                           color: CardTheme.text, secondaryColor: CardTheme.secondary)
        }
        return NSAttributedString(string: markdown, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: CardTheme.text,
        ])
    }

    private static func errorText(_ message: String) -> NSAttributedString {
        NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.systemRed,
        ])
    }

    private func attribution(model: String, seconds: Double) -> String {
        let base = String(format: "%.2fs", seconds)
        if let notice { return base + "  ⚠ \(notice)" }
        return base
    }

    /// 结果可用但有提醒（例如被截断）。放在服务标题右侧，不混进译文里
    func setNotice(_ text: String) {
        notice = text
    }

    private var contentWidth: CGFloat {
        max(120, (panel?.frame.width ?? CardTheme.minCardWidth) - CardTheme.hPadOuter * 2 - 24)
    }

    // MARK: - 尺寸

    /// 按当前内容算出该多高，再摆一次窗口。
    private func relayout() {
        guard let panel else { return }
        sourceHeight.constant = min(max(
            CardTheme.measure(NSAttributedString(string: sourceView.string, attributes: [
                .font: CardTheme.sourceFont(withSize: Config.shared.fontSize),
            ]), width: contentWidth) + 8, 22), 132)
        body.layoutSubtreeIfNeeded()

        // 结果区高度：直接量真实排完的高度，别自己估——估小了会把最后一条切掉
        resultsStack.layoutSubtreeIfNeeded()
        let needed = resultsStack.fittingSize.height
        let screenH = panel.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        let maxResults = max(180, screenH - 270)
        resultsHeight.constant = min(max(needed, 40), maxResults)

        body.layoutSubtreeIfNeeded()
        let fitting = body.fittingSize
        let screenHeight = panel.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        let maxAllowedHeight = max(320, screenHeight - 20)
        let height = min(ceil(fitting.height) + 6, maxAllowedHeight)
        let oldFrame = panel.frame
        var frame = oldFrame
        frame.size.width = min(max(preferredWidth(), CardTheme.minCardWidth), CardTheme.maxCardWidth)
        frame.size.height = max(height, 160)
        // 顶边钉住，长高只往下长。
        frame.origin.y = oldFrame.origin.y + (oldFrame.height - frame.height)
        frame.origin.x = oldFrame.origin.x
        panel.setFrame(frame, display: true, animate: false)
    }

    private func preferredWidth() -> CGFloat {
        if sourceText.isEmpty { return CardTheme.minCardWidth }
        // 单行短词窄一点，长段落宽一点，和 Bob 的观感一致
        let estimate = CardTheme.measure(NSAttributedString(string: sourceText, attributes: [
            .font: CardTheme.sourceFont(withSize: Config.shared.fontSize),
        ]), width: CardTheme.maxCardWidth) > 44 ? CardTheme.maxCardWidth * 0.92 : CardTheme.minCardWidth
        return min(max(estimate, CardTheme.minCardWidth), CardTheme.maxCardWidth)
    }

    private func positionAndSize() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        var screen = NSScreen.main
        for candidate in NSScreen.screens where candidate.frame.contains(mouse) {
            screen = candidate
            break
        }
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let margin: CGFloat = Config.shared.noScreenMargin ? 0 : 12

        var origin: NSPoint
        switch Config.shared.windowLocationMode {
        case "center":
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        case "last":
            origin = parsePoint(Config.shared.lastWindowOrigin)
                ?? NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 24)
        default:
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 24)
            if origin.y + size.height > visible.maxY {
                origin.y = mouse.y - size.height - 24
            }
        }

        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        panel.setFrameOrigin(origin)
    }

    private func parsePoint(_ str: String) -> NSPoint? {
        let parts = str.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
    }

    private static func measureDictionary(_ block: NSView) -> CGFloat {
        block.layoutSubtreeIfNeeded()
        return ceil(block.fittingSize.height)
    }

    // MARK: - 建窗

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = CardPanel(
            contentRect: NSRect(x: 0, y: 0, width: CardTheme.minCardWidth, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = Config.shared.alwaysOnTop ? .statusBar : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.worksWhenModal = true

        let container = CardContainerView()
        panel.contentView = container

        buildToolbar()
        buildSourceCard()
        buildLanguageBar()
        buildResultsArea()
        buildThinkArea()
        buildDictionaryCard()
        buildHintBar()

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = CardTheme.vGap
        body.edgeInsets = NSEdgeInsets(top: 10, left: CardTheme.hPadOuter,
                                       bottom: 8, right: CardTheme.hPadOuter)
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [toolbar, sourceCard, langBar, resultsScroll, thinkToggleButton, thinkScroll, dictCard, hintBar] {
            body.addArrangedSubview(view)
        }
        thinkToggleButton.target = self
        thinkToggleButton.action = #selector(toggleThinkCollapsed)

        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 26),
            hintBar.heightAnchor.constraint(equalToConstant: 16),
        ])
        let inner = -CardTheme.hPadOuter * 2
        toolbar.widthAnchor.constraint(equalTo: body.widthAnchor, constant: inner).isActive = true
        sourceCard.widthAnchor.constraint(equalTo: body.widthAnchor, constant: inner).isActive = true
        langBar.widthAnchor.constraint(equalTo: body.widthAnchor, constant: inner).isActive = true
        resultsScroll.widthAnchor.constraint(equalTo: body.widthAnchor, constant: inner).isActive = true
        thinkScroll.widthAnchor.constraint(equalTo: body.widthAnchor, constant: inner).isActive = true
        dictCard.widthAnchor.constraint(equalTo: body.widthAnchor, constant: inner).isActive = true
        hintBar.widthAnchor.constraint(equalTo: body.widthAnchor, constant: inner).isActive = true
        NSLayoutConstraint.activate(pendingWidthConstraints)
        pendingWidthConstraints = []

        panel.delegate = panelHost
        self.panel = panel
        installKeyMonitor()
    }

    /// 用来接失焦关闭的代理对象
    private lazy var panelHost = CardPanelHost(card: self)

    // MARK: - 工具条（对齐 Bob：左钉住，右侧一排图标）

    private func buildToolbar() {
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let pin = CardTheme.iconButton("pin", help: "固定窗口 ⌘P（右键可强制关闭）", action: #selector(togglePinAction), target: self)
        let pinMenu = NSMenu()
        let forceCloseItem = NSMenuItem(title: "强制关闭窗口", action: #selector(forceCloseCard), keyEquivalent: "")
        forceCloseItem.target = self
        pinMenu.addItem(forceCloseItem)
        pin.menu = pinMenu
        pinButton = pin

        let favorite = CardTheme.iconButton("star", help: "收藏 ⌘S（右键打开收藏夹）", action: #selector(toggleFavoriteAction), target: self)
        favoriteButton = favorite
        let favMenu = NSMenu()
        let favItem = NSMenuItem(title: "打开收藏夹…", action: #selector(openFavoritesFromMenu), keyEquivalent: "")
        favItem.target = self
        favMenu.addItem(favItem)
        favorite.menu = favMenu

        // 收藏夹单独一个入口：星标只管"收/取消"，不然用户根本找不到收藏夹在哪
        let favoritesList = CardTheme.iconButton("tray.full", help: "收藏夹", action: #selector(openFavoritesFromMenu), target: self)
        let history = CardTheme.iconButton("clock.arrow.circlepath", help: "翻译历史", action: #selector(openHistory), target: self)
        let shot = CardTheme.iconButton("camera.viewfinder", help: "截图翻译", action: #selector(screenshotFromCard), target: self)
        let clip = CardTheme.iconButton("doc.on.clipboard", help: "剪贴板翻译", action: #selector(clipboardFromCard), target: self)
        let edit = CardTheme.iconButton("square.and.pencil", help: "编辑原文 ⌘E", action: #selector(focusSourceEditor), target: self)
        let codeCase = CardTheme.iconButton("curlybraces", help: "代码变量命名 (驼峰/蛇形/宏)", action: #selector(showCodeCaseMenu(_:)), target: self)
        let replace = CardTheme.iconButton("arrow.uturn.left.circle", help: "替换原文 ⌘⇧R", action: #selector(replaceSelectionAndClose), target: self)

        let settings = CardTheme.iconButton("gearshape", help: "设置（右键直达分栏）", action: #selector(openSettings), target: self)
        let settingsMenu = NSMenu()
        settingsMenu.addItem(NSMenuItem(title: "收藏夹…", action: #selector(openFavoritesFromMenu), keyEquivalent: ""))
        settingsMenu.addItem(NSMenuItem(title: "翻译历史…", action: #selector(openHistory), keyEquivalent: ""))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(NSMenuItem(title: "服务与模型设置…", action: #selector(openServicesPaneFromMenu), keyEquivalent: ""))
        settingsMenu.addItem(NSMenuItem(title: "快捷键设置…", action: #selector(openHotkeysPaneFromMenu), keyEquivalent: ""))
        settingsMenu.addItem(NSMenuItem(title: "权限与诊断…", action: #selector(openPermissionsPaneFromMenu), keyEquivalent: ""))
        for item in settingsMenu.items { item.target = self }
        settings.menu = settingsMenu

        let close = CardTheme.iconButton("xmark", help: "关闭 esc", action: #selector(closeCard), target: self)

        toolbar.addArrangedSubview(pin)
        toolbar.addArrangedSubview(NSView())
        for button in [favorite, favoritesList, history, shot, clip, edit, codeCase, replace, settings, close] {
            toolbar.addArrangedSubview(button)
        }
    }

    // MARK: - 原文卡片

    private func buildSourceCard() {
        sourceCard.wantsLayer = true
        sourceCard.layer?.cornerRadius = CardTheme.innerRadius
        sourceCard.layer?.backgroundColor = CardTheme.sectionBackground.cgColor
        sourceCard.translatesAutoresizingMaskIntoConstraints = false

        configure(sourceScroll, into: sourceView, editable: true)
        sourceView.font = CardTheme.sourceFont(withSize: Config.shared.fontSize)
        sourceView.textColor = CardTheme.text
        sourceView.insertionPointColor = CardTheme.accent
        sourceView.textContainerInset = NSSize(width: 2, height: 2)
        sourceView.delegate = self

        sourceHeight = sourceScroll.heightAnchor.constraint(equalToConstant: 24)
        sourceHeight.isActive = true

        let speak = CardTheme.iconButton("speaker.wave.2", help: "朗读原文", action: #selector(speakSource), target: self)
        let copy = CardTheme.iconButton("doc.on.doc", help: "复制原文", action: #selector(copySourceText), target: self)

        detectedPill.bezelStyle = .inline
        detectedPill.isBordered = false
        detectedPill.font = NSFont.systemFont(ofSize: 11)
        detectedPill.contentTintColor = CardTheme.accent
        detectedPill.target = self
        detectedPill.action = #selector(cycleSourceLanguage)
        detectedPill.toolTip = "自动检测到的原文语言，点击可手动切换"

        sourceActions.orientation = .horizontal
        sourceActions.spacing = 8
        sourceActions.alignment = .centerY
        sourceActions.translatesAutoresizingMaskIntoConstraints = false
        for view in [speak, copy, detectedPill, NSView()] {
            sourceActions.addArrangedSubview(view)
        }

        let stack = NSStackView(views: [sourceScroll, sourceActions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sourceCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sourceCard.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sourceCard.trailingAnchor),
            stack.topAnchor.constraint(equalTo: sourceCard.topAnchor),
            stack.bottomAnchor.constraint(equalTo: sourceCard.bottomAnchor),
            sourceScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            sourceActions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    // MARK: - 语言栏

    private func buildLanguageBar() {
        langBar.wantsLayer = true
        langBar.layer?.cornerRadius = CardTheme.innerRadius
        langBar.layer?.backgroundColor = CardTheme.sectionBackground.cgColor
        langBar.translatesAutoresizingMaskIntoConstraints = false

        sourceLangPopup.controlSize = .small
        sourceLangPopup.isBordered = false
        sourceLangPopup.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sourceLangPopup.addItem(withTitle: "自动检测")
        for lang in Languages.all { sourceLangPopup.addItem(withTitle: lang.name) }
        sourceLangPopup.target = self
        sourceLangPopup.action = #selector(sourceLanguageChanged(_:))

        swapButton.bezelStyle = .inline
        swapButton.isBordered = false
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                   accessibilityDescription: "互换源语言与目标语言")
        swapButton.image?.isTemplate = true
        swapButton.contentTintColor = CardTheme.secondary
        swapButton.target = self
        swapButton.action = #selector(swapLanguages)
        swapButton.toolTip = "互换源语言和目标语言"

        targetLangPopup.controlSize = .small
        targetLangPopup.isBordered = false
        targetLangPopup.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        for lang in Languages.all { targetLangPopup.addItem(withTitle: lang.name) }
        targetLangPopup.target = self
        targetLangPopup.action = #selector(targetLanguageChanged(_:))

        pinnedStack.orientation = .horizontal
        pinnedStack.spacing = 4
        pinnedStack.alignment = .centerY

        let row = NSStackView(views: [sourceLangPopup, swapButton, targetLangPopup, NSView(), pinnedStack])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        langBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: langBar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: langBar.trailingAnchor),
            row.topAnchor.constraint(equalTo: langBar.topAnchor),
            row.bottomAnchor.constraint(equalTo: langBar.bottomAnchor),
            langBar.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: - 结果区

    private func buildResultsArea() {
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 8
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        resultsScroll.documentView = resultsStack
        resultsScroll.hasVerticalScroller = true
        resultsScroll.autohidesScrollers = true
        resultsScroll.drawsBackground = false
        resultsScroll.borderType = .noBorder
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsHeight = resultsScroll.heightAnchor.constraint(equalToConstant: 80)
        resultsHeight.isActive = true
        NSLayoutConstraint.activate([
            resultsStack.leadingAnchor.constraint(equalTo: resultsScroll.contentView.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: resultsScroll.contentView.trailingAnchor),
            resultsStack.topAnchor.constraint(equalTo: resultsScroll.contentView.topAnchor),
            resultsStack.widthAnchor.constraint(equalTo: resultsScroll.contentView.widthAnchor),
        ])
    }

    private func rebuildAllServiceCards() {
        for view in resultsStack.arrangedSubviews { view.removeFromSuperview() }
        serviceCards.removeAll()
        for (index, id) in models.enumerated() {
            let view = ServiceCardView(modelID: id,
                                       name: displayNames[id] ?? id,
                                       textView: index == 0 ? resultView : NSTextView())
            view.setStatus(color: CardTheme.accent, meta: models.count > 1 ? "翻译中…" : "")
            view.onSpeak = { [weak self] in _ = self?.speak(self?.serviceCards[id]?.textView.string ?? "", language: nil) }
            view.onCopy = { [weak self] in self?.copyTextOfService(id) }
            view.onReplace = { [weak self] in self?.replaceSelectionAndClose() }
            view.onToggleCollapse = { [weak self] in self?.relayout() }
            view.translatesAutoresizingMaskIntoConstraints = false
            resultsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
            serviceCards[id] = view
        }
    }

    private func rebuildPinnedServices() {
        for view in pinnedStack.arrangedSubviews { view.removeFromSuperview() }
        let pinned = Config.shared.pinnedProfileIDs
        for id in models where pinned.contains(id) {
            let btn = NSButton(title: "", target: self, action: #selector(pinnedServiceTapped(_:)))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            btn.image?.isTemplate = true
            btn.contentTintColor = CardTheme.secondary
            btn.identifier = NSUserInterfaceItemIdentifier(id)
            btn.toolTip = displayNames[id] ?? id
            pinnedStack.addArrangedSubview(btn)
        }
    }

    private func refreshLanguageBar(target: String, mode: TranslateMode) {
        let langs = Languages.all
        if let idx = langs.firstIndex(where: { $0.code == target }) {
            targetLangPopup.selectItem(at: idx)
        }
    }

    private func refreshDetectedPill(source: String) {
        let detected = LanguageDetector.detectLanguage(source)
        detectedPill.title = "识别为 \(Languages.name(for: detected))"
    }

    // MARK: - 思考块

    private func buildThinkArea() {
        configure(thinkScroll, into: thinkView, editable: false)
        thinkView.font = NSFont.systemFont(ofSize: 11)
        thinkView.textColor = CardTheme.secondary
        thinkScroll.isHidden = true
        thinkScroll.wantsLayer = true
        thinkScroll.layer?.cornerRadius = CardTheme.innerRadius
        thinkScroll.layer?.backgroundColor = CardTheme.sectionBackground.cgColor
        thinkHeight = thinkScroll.heightAnchor.constraint(equalToConstant: 60)
        thinkHeight.isActive = true
    }

    // MARK: - 词典卡片

    private func buildDictionaryCard() {
        dictCard.wantsLayer = true
        dictCard.layer?.cornerRadius = CardTheme.innerRadius
        dictCard.layer?.backgroundColor = CardTheme.sectionBackground.cgColor
        dictCard.translatesAutoresizingMaskIntoConstraints = false
        dictCard.isHidden = true

        dictContainer.translatesAutoresizingMaskIntoConstraints = false
        dictCard.addSubview(dictContainer)
        dictHeight = dictContainer.heightAnchor.constraint(equalToConstant: 0)
        dictHeight.isActive = true
        NSLayoutConstraint.activate([
            dictContainer.leadingAnchor.constraint(equalTo: dictCard.leadingAnchor, constant: 12),
            dictContainer.trailingAnchor.constraint(equalTo: dictCard.trailingAnchor, constant: -12),
            dictContainer.topAnchor.constraint(equalTo: dictCard.topAnchor, constant: 10),
            dictContainer.bottomAnchor.constraint(equalTo: dictCard.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - 底部提示

    static let shortcutHint = "⌘C 复制结果   ⌘E 编辑文本   ⌘P 固定窗口   esc 关闭"

    private func buildHintBar() {
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = CardTheme.tertiary
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintBar.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: hintBar.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: hintBar.trailingAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: hintBar.centerYAnchor),
        ])
        hintLabel.stringValue = Self.shortcutHint
    }

    private func configure(_ scroll: NSScrollView, into textView: NSTextView, editable: Bool) {
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = editable
    }

    // MARK: - 动作

    @objc private func speakSource() { speak(sourceText, language: nil) }
    @objc func speakResult() { speak(resultView.string, language: nil) }
    @objc private func copySourceText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sourceView.string, forType: .string)
        flashHUD("已复制原文")
    }
    @objc private func copyPrimaryText() { copyResultToPasteboard() }

    private func copyTextOfService(_ id: String) {
        guard let text = serviceCards[id]?.textView.string, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if Config.shared.copyHint { flashHUD("已复制 \(displayNames[id] ?? "")") }
    }

    @objc private func togglePinAction() { togglePin() }
    @objc private func forceCloseCard() { isPinned = false; close() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func openFavoritesFromMenu() { FavoriteWindow.shared.show() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openServicesPaneFromMenu() { PreferencesWindow.shared.show(section: .services) }
    @objc private func openHotkeysPaneFromMenu() { PreferencesWindow.shared.show(section: .hotkeys) }
    @objc private func openPermissionsPaneFromMenu() { PreferencesWindow.shared.show(section: .permissions) }
    @objc private func retry() { onRetry?() }
    @objc private func closeCard() { close() }
    @objc private func toggleFavoriteAction() { toggleFavorite() }

    /// 星标要能看出"这句已经收藏过了"，否则用户点完没有任何反馈
    func refreshFavoriteState() {
        let source = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = !source.isEmpty && FavoriteStore.contains(source: source)
        favoriteButton?.image = NSImage(systemSymbolName: saved ? "star.fill" : "star",
                                        accessibilityDescription: saved ? "已收藏" : "收藏")
        favoriteButton?.contentTintColor = saved ? .systemYellow : .secondaryLabelColor
        favoriteButton?.toolTip = saved ? "已收藏（⌘S 取消，右键打开收藏夹）" : "收藏 ⌘S（右键打开收藏夹）"
    }

    @objc private func screenshotFromCard() {
        close()
        (NSApp.delegate as? AppDelegate)?.screenshotTranslate()
    }

    @objc private func clipboardFromCard() {
        close()
        (NSApp.delegate as? AppDelegate)?.clipboardTranslate()
    }

    @objc private func pinnedServiceTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        togglePinService(id: id)
    }

    @objc private func swapLanguages() {
        let detected = LanguageDetector.detectLanguage(sourceView.string)
        let currentTarget = targetLanguage
        let newTarget = LanguageDetector.baseCode(detected) == LanguageDetector.baseCode(currentTarget)
            ? (currentTarget.hasPrefix("zh") ? "en" : "zh-Hans")
            : detected
        targetLanguage = newTarget
        Config.shared.targetLanguage = newTarget
        refreshLanguageBar(target: newTarget, mode: mode)
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onReRequest?(text) }
    }

    @objc private func sourceLanguageChanged(_ sender: NSPopUpButton) {
        // 索引 0 = 自动检测
        if sender.indexOfSelectedItem == 0 {
            Config.shared.sourceLanguage = "auto"
        } else {
            let langs = Languages.all
            let idx = sender.indexOfSelectedItem - 1
            if langs.indices.contains(idx) { Config.shared.sourceLanguage = langs[idx].code }
        }
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onReRequest?(text) }
    }

    @objc private func targetLanguageChanged(_ sender: NSPopUpButton) {
        let langs = Languages.all
        let idx = sender.indexOfSelectedItem
        guard langs.indices.contains(idx) else { return }
        targetLanguage = langs[idx].code
        Config.shared.targetLanguage = targetLanguage
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onReRequest?(text) }
    }

    @objc private func cycleSourceLanguage() {
        sourceLangPopup.selectItem(at: 0)
        _ = sourceLangPopup.indexOfSelectedItem
        sourceLangPopup.performClick(nil)
    }

    @objc func toggleThinkCollapsed() {
        let newCollapsed = !Config.shared.thinkCollapsed
        Config.shared.thinkCollapsed = newCollapsed
        thinkToggleButton.title = newCollapsed ? "▶ 思考过程（点击展开）" : "▼ 思考过程（点击收起）"
        thinkScroll.isHidden = newCollapsed
        if !newCollapsed {
            thinkHeight.constant = min(max(
                CardTheme.measure(NSAttributedString(string: thinkView.string, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                ]), width: contentWidth) + 12, 34), 120)
        }
        relayout()
    }

    @objc private func toggleThinkCollapsedAction() { toggleThinkCollapsed() }

    /// 钉住/取消钉住某个服务（右键 tab 或面板里点一下都会调）
    func togglePinService(id: String) {
        var list = Config.shared.pinnedProfileIDs
        if let idx = list.firstIndex(of: id) {
            list.remove(at: idx)
        } else {
            list.append(id)
        }
        Config.shared.pinnedProfileIDs = list
        rebuildPinnedServices()
    }

    // MARK: - 自测出口

    /// 卡片当前的窗口尺寸，供界面自检用
    var windowFrameForTesting: NSRect { panel?.frame ?? .zero }

    /// 同步跑一段主队列，把已经排上的渲染任务落地后取译文视图的字号。
    func waitForRenderedResultFont(_ transform: (Double) -> Double) -> Double {
        let sem = DispatchSemaphore(value: 0)
        var size: Double = 0
        DispatchQueue.main.async {
            size = Double(self.resultView.font?.pointSize ?? 0)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        return transform(size)
    }

    /// 卡片窗口本体。无边框窗的 title 是空的，靠标题找窗找不到。
    var windowForTesting: NSWindow? {
        guard let panel, panel.isVisible else { return nil }
        return panel
    }

    func visibleTextSnapshot() -> [String] {
        var pieces: [String] = []
        if let content = panel?.contentView { collectText(content, into: &pieces) }
        return pieces
    }

    private func collectText(_ view: NSView, into pieces: inout [String]) {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            pieces.append(field.stringValue)
        }
        if let button = view as? NSButton, let title = button.title as String?, !title.isEmpty {
            pieces.append(title)
        }
        if let popup = view as? NSPopUpButton, let title = popup.titleOfSelectedItem, !title.isEmpty {
            pieces.append(title)
        }
        if let text = view as? NSTextView, let string = text.string as String?, !string.isEmpty {
            pieces.append(string)
        }
        for sub in view.subviews { collectText(sub, into: &pieces) }
    }

    func copyResultToPasteboard() {
        let text = resultView.string
        Debug.log("⌘C 复制：resultView=\(text.count) 字，首个结果=\(outcomes[models.first ?? ""]?.text.count ?? 0) 字")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if Config.shared.copyHint { flashHUD("已复制") }
    }

    @objc func focusSourceEditor() {
        panel?.makeFirstResponder(sourceView)
        let length = (sourceView.string as NSString).length
        sourceView.setSelectedRange(NSRange(location: length, length: 0))
    }

    func toggleFavorite() {
        let text = resultView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let source = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        // 星标 = 收藏这句译文，统一进收藏夹。
        // 以前按词数分流：≤4 个词的句子会被塞进「生词本」，用户在收藏夹里什么都看不到，
        // 只会觉得"收藏功能没做出来"。生词本改成只在词典卡里手动添加。
        if FavoriteStore.contains(source: source) {
            FavoriteStore.remove(source: source)
            flashHUD("已取消收藏")
        } else {
            FavoriteStore.add(source: source, result: text,
                              model: displayNames[activeModel] ?? activeModel,
                              targetLanguage: targetLanguage,
                              sourceLanguage: Config.shared.sourceLanguage)
            flashHUD("已收藏到收藏夹（⌘S 取消）")
        }
        refreshFavoriteState()
    }

    func zoomFont(delta: Double) {
        let current = Config.shared.fontSize
        let newSize = max(11, min(24, current + delta))
        guard newSize != current else { return }
        Config.shared.fontSize = newSize
        sourceView.font = CardTheme.sourceFont(withSize: newSize)
        for (id, card) in serviceCards {
            card.textView.font = CardTheme.resultFont(withSize: newSize)
            let md = (streams[id] ?? NSMutableString()) as String
            if !md.isEmpty {
                card.setText(Self.formatAttributed(md, size: CGFloat(newSize)), width: contentWidth)
            }
        }
        flashHUD("字号 \(Int(newSize)) pt")
    }

    @objc func replaceSelectionAndClose() {
        let text = resultView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            flashHUD("没有可替换的译文")
            return
        }
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            _ = SilentReplace.writeBackText(text)
            HUD.show("已替换原文")
        }
    }

    @objc func showCodeCaseMenu(_ sender: NSButton) {
        let text = resultView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            flashHUD("没有可转换的译文")
            return
        }
        let menu = NSMenu()
        for style in CodeCaseFormatter.Style.allCases {
            let formatted = CodeCaseFormatter.format(text, style: style)
            let item = NSMenuItem(title: "\(style.label): \(formatted)",
                                  action: #selector(copyFormattedCodeCase(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = formatted
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyFormattedCodeCase(_ sender: NSMenuItem) {
        guard let formatted = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(formatted, forType: .string)
        flashHUD("已复制: \(formatted)")
    }

    @objc private func shareResult(_ sender: NSButton) {
        let text = resultView.string
        guard !text.isEmpty else { return }
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @discardableResult
    private func speak(_ text: String, language: String?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        SpeechService.shared.speak(trimmed)
        return true
    }

    // MARK: - 键盘

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {   // esc
                self.close()
                return nil
            }
            // 只比较「有意义的修饰键」：锁大写、fn、数字键盘都会往 flags 里塞位，
            // 直接用 == .command 会被它们坑掉，表现就是 ⌘C / ⌘P 时灵时不灵。
            let meaningful: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            if flags.intersection(meaningful) == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": self.copyResultToPasteboard(); return nil
                case "e": self.focusSourceEditor(); return nil
                case "p": self.togglePin(); return nil
                case "w": self.close(); return nil
                case "r":
                    let text = self.sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { self.onReRequest?(text) }
                    return nil
                case "s": self.toggleFavorite(); return nil
                case "=", "+": self.zoomFont(delta: 1); return nil
                case "-": self.zoomFont(delta: -1); return nil
                case "z":
                    if self.panel?.firstResponder === self.sourceView {
                        self.sourceView.undoManager?.undo()
                        return nil
                    }
                default: break
                }
            }
            if flags == [.command, .shift] {
                let char = event.charactersIgnoringModifiers?.lowercased()
                if char == "r" {
                    self.replaceSelectionAndClose()
                    return nil
                }
                if char == "c" {
                    let text = self.resultView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let lower = CodeCaseFormatter.format(text, style: .lowerCamel)
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(lower, forType: .string)
                        self.flashHUD("已复制小驼峰: \(lower)")
                        return nil
                    }
                }
                if char == "z" {
                    if self.panel?.firstResponder === self.sourceView {
                        self.sourceView.undoManager?.redo()
                        return nil
                    }
                }
                if event.keyCode == 36 {  // ⌘⇧↵ 立刻重译
                    let text = self.sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { self.onReRequest?(text) }
                    return nil
                }
            }
            return event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

// MARK: - 单个服务的结果卡片（Bob 里的一个灰底卡片）

final class ServiceCardView: NSView {

    let modelID: String
    let textView: NSTextView

    private let dot = NSTextField(labelWithString: "●")
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let chevron = NSButton()
    private let textScroll = NSScrollView()
    private let actionsRow = NSStackView()
    private let contentStack = NSStackView()

    private(set) var isCollapsed = false
    private var lastText = NSAttributedString(string: "")
    private var lastWidth: CGFloat = 0

    var onSpeak: (() -> Void)?
    var onCopy: (() -> Void)?
    var onReplace: (() -> Void)?
    var onToggleCollapse: (() -> Void)?

    /// 展开时需要多高
    var requiredHeight: CGFloat {
        if isCollapsed { return 40 }
        return 40 + storedHeight.constant + 6
    }

    init(modelID: String, name: String, textView: NSTextView) {
        self.modelID = modelID
        self.textView = textView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = CardTheme.innerRadius
        layer?.backgroundColor = CardTheme.sectionBackground.cgColor

        dot.font = NSFont.systemFont(ofSize: 9)
        dot.textColor = CardTheme.accent
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.isHidden = true

        nameLabel.stringValue = name
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = CardTheme.text
        nameLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = NSFont.systemFont(ofSize: 10)
        metaLabel.textColor = CardTheme.tertiary
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)

        chevron.bezelStyle = .inline
        chevron.isBordered = false
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "折叠")
        chevron.image?.isTemplate = true
        chevron.contentTintColor = CardTheme.secondary
        chevron.target = self
        chevron.action = #selector(toggleCollapse)
        chevron.toolTip = "折叠 / 展开这条结果"

        let badge = CardTheme.serviceBadge(for: modelID, name: name)
        let header = NSStackView(views: [badge, nameLabel, metaLabel, NSView(), chevron])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = false
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.font = CardTheme.resultFont(withSize: Config.shared.fontSize)
        textView.textColor = CardTheme.text

        let speakBtn = CardTheme.iconButton("speaker.wave.2", help: "朗读", action: #selector(speakTapped), target: self)
        let copyBtn = CardTheme.iconButton("doc.on.doc", help: "复制", action: #selector(copyTapped), target: self)
        let replaceBtn = CardTheme.iconButton("arrow.uturn.left", help: "替换原文", action: #selector(replaceTapped), target: self)
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8
        actionsRow.alignment = .centerY
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [speakBtn, copyBtn, replaceBtn, NSView()] { actionsRow.addArrangedSubview(view) }

        let realHeight = textScroll.heightAnchor.constraint(equalToConstant: 20)
        realHeight.isActive = true
        self.storedHeight = realHeight

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(textScroll)
        contentStack.addArrangedSubview(actionsRow)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            textScroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            actionsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持 nib") }

    private var storedHeight: NSLayoutConstraint!

    func setStatus(color: NSColor, meta: String) {
        dot.textColor = color
        metaLabel.stringValue = meta
    }

    func setText(_ text: NSAttributedString, width: CGFloat) {
        lastText = text
        lastWidth = width
        textView.textStorage?.setAttributedString(text)
        let measured = CardTheme.measure(text, width: max(80, width - 24))
        storedHeight.constant = min(max(measured, text.string.isEmpty ? 0 : 16), 320)
        textScroll.isHidden = text.string.isEmpty
    }

    override func layout() {
        super.layout()
        // 宽度变化后重新量一次高度，避免换行算错
        let usable = bounds.width - 24
        if usable > 40, abs(usable - lastWidth) > 2, !lastText.string.isEmpty {
            lastWidth = usable
            let measured = CardTheme.measure(lastText, width: usable - 24)
            storedHeight.constant = min(max(measured, 16), 320)
        }
    }

    @objc private func toggleCollapse() {
        isCollapsed.toggle()
        textScroll.isHidden = isCollapsed || lastText.string.isEmpty
        actionsRow.isHidden = isCollapsed
        storedHeight.constant = isCollapsed ? 0 : min(max(CardTheme.measure(lastText, width: max(80, bounds.width - 48)), 16), 320)
        chevron.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: nil)
        onToggleCollapse?()
    }

    @objc private func speakTapped() { onSpeak?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func replaceTapped() { onReplace?() }
}

// MARK: - 无边框卡片窗

/// 顶部对齐的竖排栈：NSScrollView 的 documentView 用普通 NSView 会把内容贴到底部
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 画圆角背景 + 细边框
final class CardContainerView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: CardTheme.cornerRadius, yRadius: CardTheme.cornerRadius)
        CardTheme.cardBackground.setFill()
        path.fill()
        CardTheme.cardBorder.setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }
}

final class CardPanelHost: NSObject, NSWindowDelegate {
    static let synthesizer = AVSpeechSynthesizer()

    private weak var card: TranslationCard?

    init(card: TranslationCard) {
        self.card = card
    }

    func windowDidResignKey(_ notification: Notification) {
        card?.handleResignKey()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow else { return }
        Config.shared.lastWindowOrigin = "\(panel.frame.origin.x),\(panel.frame.origin.y)"
    }
}

// MARK: - 原文编辑

extension TranslationCard: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if flags.contains(.shift) || flags.contains(.command) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // 回车直接翻译
            let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                retranslateWork?.cancel()
                onReRequest?(text)
            }
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === sourceView else { return }
        sourceText = textView.string
        refreshDetectedPill(source: textView.string)
        // 停手 0.7 秒再发请求，边打字边发会烧 token
        retranslateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let text = self.sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self.onReRequest?(text) }
        }
        retranslateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}
