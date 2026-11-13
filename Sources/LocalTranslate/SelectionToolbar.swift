import AppKit

/// 划词工具栏：选中文字后浮出一排小图标。
///
/// 和「选中即翻」的区别：它只是**显示工具**，点了才动作，
/// 所以误触发的代价小得多——选错了不理它就行，不会白花钱。
///
/// 用 nonactivating 面板：浮出来但不抢焦点，用户还能继续在原处打字。
final class SelectionToolbar: NSObject {

    static let shared = SelectionToolbar()

    var onTranslate: ((String) -> Void)?

    private var panel: NSPanel?
    private var currentText = ""
    private var hideTimer: Timer?

    private override init() {}

    var isVisible: Bool { panel?.isVisible == true }

    /// 在指定位置显示工具栏
    func show(text: String, near point: NSPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { hide(); return }
        currentText = trimmed

        let panel = ensurePanel()
        panel.setFrameOrigin(position(for: point, size: panel.frame.size))
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        // 5 秒没人理就自己收起来，免得一直挂在屏幕上
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.hide()
        }
        Debug.log("划词工具栏：\(trimmed.count) 字")
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }

    /// 把工具栏放在鼠标下方，超出屏幕就往回收
    func position(for point: NSPoint, size: NSSize) -> NSPoint {
        var x = point.x - size.width / 2
        var y = point.y - size.height - 8
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let frame = screen?.frame {
            x = max(frame.minX + 4, min(x, frame.maxX - size.width - 4))
            // 下方放不下就翻到鼠标上面
            if y < frame.minY + 4 { y = point.y + 8 }
            y = max(frame.minY + 4, min(y, frame.maxY - size.height - 4))
        }
        return NSPoint(x: x, y: y)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let buttons: [(String, Selector)] = [
            ("character.bubble", #selector(translateAction)),
            ("doc.on.doc", #selector(copyAction)),
            ("speaker.wave.2", #selector(speakAction)),
            ("magnifyingglass", #selector(searchAction)),
        ]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        for (symbol, action) in buttons {
            let button = NSButton(title: "", target: self, action: action)
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.contentTintColor = .labelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.toolTip = symbol
            stack.addArrangedSubview(button)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        self.panel = panel
        return panel
    }

    // MARK: - 动作

    @objc private func translateAction() {
        let text = currentText
        hide()
        onTranslate?(text)
    }

    @objc private func copyAction() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentText, forType: .string)
        if Config.shared.copyHint { HUD.show("已复制") }
        hide()
    }

    @objc private func speakAction() {
        SpeechService.shared.speak(currentText)
        hide()
    }

    @objc private func searchAction() {
        let query = currentText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://www.bing.com/search?q=" + query) {
            NSWorkspace.shared.open(url)
        }
        hide()
    }

    // MARK: - 自测入口

    /// 工具栏上几个按钮、各自能不能用
    func buttonCountForTesting() -> Int {
        let panel = ensurePanel()
        var count = 0
        func walk(_ v: NSView) {
            if v is NSButton { count += 1 }
            for sub in v.subviews { walk(sub) }
        }
        if let content = panel.contentView { walk(content) }
        return count
    }

    var textForTesting: String { currentText }

    func copyForTesting() { copyAction() }
}