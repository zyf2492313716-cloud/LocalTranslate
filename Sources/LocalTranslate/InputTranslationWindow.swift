import AppKit

/// 输入翻译：自己打一段字翻，不依赖选区。
///
/// Bob 里这是个独立窗口，存在的意义是补「手上没有可选的文字」这一档——
/// 想翻一句话但不想先打到某个文档里、再选中、再按快捷键。
///
/// 输入框里回车是换行，⌘⏎ 才发请求：一段话经常要改，边打边发会白白烧 token。
private final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class InputTranslationWindow: NSObject, NSWindowDelegate {

    static let shared = InputTranslationWindow()

    private var window: NSWindow?
    private var sourceView: NSTextView!
    private var resultView: NSTextView!
    private var langPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var translateButton: NSButton!
    private var placeholder: NSTextField!
    private var currentTask: Task<Void, Never>?

    private override init() {}

    /// 打开窗口。能带一段预置文本（比如从剪贴板或历史里带过来）。
    func show(prefill: String? = nil) {
        DispatchQueue.main.async {
            self.ensureWindow()
            if let prefill, !prefill.isEmpty {
                self.sourceView.string = prefill
                self.placeholder.isHidden = true
            }
            // 先激活再 makeKey：顺序反了的话窗口会停在"非 key"状态，
            // 标题栏按钮是灰的、打字也没反应（菜单栏应用尤其容易这样）。
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.orderFrontRegardless()
            if let window = self.window {
                window.makeFirstResponder(self.sourceView)
                // 激活是异步的：刚 makeKey 时设的第一响应者会被窗口重建 key view 循环冲掉，
                // 表现就是"打开输入窗直接打字没反应、⌘A 也选不中"。等一拍再确认一次。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, let window = self.window else { return }
                    if window.firstResponder !== self.sourceView {
                        window.makeFirstResponder(self.sourceView)
                    }
                }
            }
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        // 这是个要打字的窗口，必须是能被激活的普通窗口——
        // 用 nonactivatingPanel 的话 App 不成为前台，⌘V / 直接敲字全都落到别的 App 去了。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "输入翻译"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.minSize = NSSize(width: 520, height: 400)

        // 原文：可编辑，带占位提示
        let sourceScroll = makeTextView(&sourceView, editable: true, height: 160)
        placeholder = NSTextField(labelWithString: "在这里输入要翻译的文字，⏎ 翻译（⇧⏎ 换行）")
        placeholder.font = NSFont.systemFont(ofSize: 12)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        sourceScroll.addSubview(placeholder)

        langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        langPopup.controlSize = .small
        let languages = Languages.all
        langPopup.addItems(withTitles: languages.map(\.name))
        let current = languages.firstIndex { $0.code == Config.shared.targetLanguage } ?? 0
        langPopup.selectItem(at: current)
        langPopup.target = self
        langPopup.action = #selector(pickLanguage(_:))

        translateButton = NSButton(title: "翻译", target: self, action: #selector(translate))
        translateButton.bezelStyle = .rounded
        // 默认回车即翻译（对齐 Bob），⏎ 的默认 keyEquivalent 就够了；
        // ⇧⏎ / ⌘⏎ 在 textView(_:doCommandBy:) 里放行给"插入换行"。
        translateButton.keyEquivalent = "\r"
        // 不带修饰键：窗口里任何位置按回车都能翻（Bob 同款），
        // 输入框内的回车由 textView 代理先接住，不会双发。
        translateButton.keyEquivalentModifierMask = []
        translateButton.controlSize = .small

        let clearButton = NSButton(title: "清空", target: self, action: #selector(clearAll))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small

        let status = NSTextField(labelWithString: "⏎ 翻译 · ⇧⏎ 换行 · esc 关闭")
        status.font = NSFont.systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        statusLabel = status
        statusLabel.stringValue = "⏎ 翻译 · ⇧⏎ 换行 · esc 关闭"

        let bar = NSStackView(views: [NSTextField(labelWithString: "译为"), langPopup, translateButton, clearButton, NSView(), status])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY

        let resultScroll = makeTextView(&resultView, editable: false, height: 200)

        let root = NSStackView(views: [sourceScroll, bar, resultScroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sourceScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            resultScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            placeholder.leadingAnchor.constraint(equalTo: sourceScroll.leadingAnchor, constant: 10),
            placeholder.topAnchor.constraint(equalTo: sourceScroll.topAnchor, constant: 8),
        ])
        window.contentView = container
        self.window = window
    }

    private func makeTextView(_ target: UnsafeMutablePointer<NSTextView?>,
                              editable: Bool,
                              height: CGFloat) -> NSScrollView {
        let view = NSTextView()
        view.isEditable = editable
        view.allowsUndo = editable
        view.isRichText = false
        view.font = NSFont.systemFont(ofSize: CGFloat(Config.shared.fontSize))
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        if editable {
            view.delegate = self
        }
        target.pointee = view

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return scroll
    }

    // MARK: - 动作

    @objc private func pickLanguage(_ sender: NSPopUpButton) {
        let languages = Languages.all
        guard languages.indices.contains(sender.indexOfSelectedItem) else { return }
        Config.shared.targetLanguage = languages[sender.indexOfSelectedItem].code
    }

    @objc private func clearAll() {
        currentTask?.cancel()
        sourceView.string = ""
        resultView.string = ""
        placeholder.isHidden = false
        statusLabel.stringValue = "⏎ 翻译 · ⇧⏎ 换行 · esc 关闭"
    }

    @objc func translate() {
        let text = TextPreprocessor.process(sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else {
            statusLabel.stringValue = "先输入要翻译的文字"
            return
        }
        guard let profile = ProfileStore.firstUsable() else {
            resultView.string = "还没有可用的服务，去设置里加一个（或从 Magpie 接入）。"
            return
        }

        currentTask?.cancel()
        resultView.string = ""
        translateButton.isEnabled = false
        statusLabel.stringValue = "翻译中… \(profile.name)"
        let started = Date()

        var buffer = ""
        let callbacks = TranslationCallbacks(
            onThink: { _ in },
            onDelta: { [weak self] chunk in
                DispatchQueue.main.async {
                    buffer += chunk
                    self?.renderResult(buffer, markdown: false)
                }
            },
            onDone: { [weak self] full, _ in
                DispatchQueue.main.async {
                    self?.renderResult(full, markdown: Config.shared.renderMarkdown)
                    let seconds = Date().timeIntervalSince(started)
                    self?.statusLabel.stringValue = String(format: "%@ · %.2fs", profile.name, seconds)
                    self?.translateButton.isEnabled = true
                }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    self?.resultView.string = message
                    self?.statusLabel.stringValue = "失败了"
                    self?.translateButton.isEnabled = true
                }
            }
        )

        currentTask = Task { [weak self] in
            await Translator.translate(text: text,
                                       targetLanguage: Config.shared.targetLanguage,
                                       mode: .translate,
                                       customPrompt: Config.shared.systemPrompt,
                                       profile: profile,
                                       callbacks: callbacks)
            _ = self
        }
    }

    /// 结果区渲染。流式过程中先按纯文本显示，收尾时再套 Markdown，
    /// 免得半截标记被解析成一堆奇怪的格式。
    private func renderResult(_ text: String, markdown: Bool) {
        let size = CGFloat(Config.shared.fontSize)
        if markdown {
            resultView.textStorage?.setAttributedString(
                MarkdownLite.attributed(text, fontSize: size,
                                        color: .labelColor, secondaryColor: .secondaryLabelColor))
        } else {
            resultView.string = text
            resultView.font = NSFont.systemFont(ofSize: size)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window else { return }
        if !(window.firstResponder is NSTextView) {
            window.makeFirstResponder(sourceView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - 自测入口

    var windowForTesting: NSWindow? { window?.isVisible == true ? window : nil }

    /// 不经过键盘，直接把文本放进输入框并触发翻译
    func typeAndTranslateForTesting(_ text: String) {
        // 同步把文字放进去再翻译。show() 是异步的，靠它塞文字会在文字落地前就发请求。
        ensureWindow()
        sourceView.string = text
        placeholder.isHidden = !text.isEmpty
        translate()
    }

    /// 自测用：不等按钮，直接走真正的翻译入口
    func translateForTesting() { translate() }

    /// 窗口内部状态，给自测断言用
    func stateForTesting() -> (status: String, result: String, placeholderHidden: Bool, buttonEnabled: Bool) {
        (statusLabel?.stringValue ?? "",
         resultView?.string ?? "",
         placeholder?.isHidden ?? false,
         translateButton?.isEnabled ?? false)
    }

    /// 收集窗口里的可见文字，给界面自检用
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

extension InputTranslationWindow: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === sourceView else { return }
        placeholder.isHidden = !view.string.isEmpty
    }

    /// ⇧⏎ / ⌘⏎ 插入换行；单独 ⏎ 交给按钮的 keyEquivalent 去触发翻译
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if flags.contains(.shift) || flags.contains(.command) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        translate()
        return true
    }
}