import AppKit

/// 独立 OCR 文本识别工作台窗口（对齐 Bob 0.9.0+ / 1.12.0+ / 1.21.0 独立 OCR 窗口）。
///
/// 支持：
/// - 左右对照布局：左侧原图缩略预览，右侧可编辑文本结果框（支持 ⌘Z 撤销）；
/// - 连续识别拼接模式（Continuous OCR）：多次框选自动按段落追加在同一文本区；
/// - 锁定截图区域（Lock Area）：记住上次截图矩形，下次免框选直接重截同一区域（看无字幕生肉视频/游戏神器）；
/// - 切换识别引擎并按下 ⌘R 立即重认当前图片；
/// - 一键「去翻译 →」送入主翻译浮窗；
/// - 钉住按钮支持右键强制关闭菜单（对齐 Bob 1.21.0）。
final class OCRWindow: NSObject, NSWindowDelegate {

    static let shared = OCRWindow()

    var onRequestSnip: (() -> Void)?
    var onTranslateText: ((String) -> Void)?

    private var window: NSPanel?
    private var imageView: NSImageView!
    private var textView: NSTextView!
    private var enginePopup: NSPopUpButton!
    private var pinButton: NSButton!
    private var continuousButton: NSButton!
    private var lockAreaButton: NSButton!
    private var autoCopyButton: NSButton!
    private var statusLabel: NSTextField!

    private var currentCGImage: CGImage?
    private var isPinned = false
    private var recognizedCount = 0
    private var keyMonitor: Any?

    private override init() {
        super.init()
    }

    // MARK: - 公开调用入口

    func showEmpty() {
        ensureWindow()
        updateToggleStates()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func present(image: CGImage?, text: String?, error: String? = nil) {
        ensureWindow()

        if let image {
            currentCGImage = image
            imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }

        if let error {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
        } else if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if Config.shared.ocrContinuous && !textView.string.isEmpty {
                let sep = textView.string.hasSuffix("\n") ? "\n" : "\n\n"
                textView.string += sep + trimmed
                recognizedCount += 1
                statusLabel.stringValue = "已连续追加第 \(recognizedCount) 段"
            } else {
                textView.string = trimmed
                recognizedCount = 1
                statusLabel.stringValue = "识别完成（\(trimmed.count) 字）"
            }
            statusLabel.textColor = .secondaryLabelColor

            if Config.shared.ocrAutoCopy && !textView.string.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(textView.string, forType: .string)
                statusLabel.stringValue += " · 已自动复制"
            }
        }

        updateToggleStates()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func recognizeAndPresent(image: CGImage) {
        ensureWindow()
        currentCGImage = image
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        statusLabel.stringValue = "识别中…"
        statusLabel.textColor = .secondaryLabelColor
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let engine = OcrEngine(rawValue: Config.shared.ocrEngine) ?? .system
        Task {
            let outcome = await ScreenOCR.recognize(image, engine: engine)
            await MainActor.run {
                switch outcome {
                case .success(let text):
                    self.present(image: nil, text: text)
                case .failure(let message):
                    self.present(image: nil, text: nil, error: message)
                }
            }
        }
    }

    // MARK: - 建窗

    private func ensureWindow() {
        guard window == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "OCR 文本识别"
        panel.minSize = NSSize(width: 520, height: 360)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = Config.shared.alwaysOnTop ? .statusBar : .floating
        panel.center()

        // 顶部工具条
        let snipBtn = NSButton(title: "截图识别", target: self, action: #selector(triggerSnip))
        snipBtn.bezelStyle = .rounded
        snipBtn.controlSize = .small
        snipBtn.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图识别")
        snipBtn.imagePosition = .imageLeading

        let pickFileBtn = NSButton(title: "选图…", target: self, action: #selector(pickImageFile))
        pickFileBtn.bezelStyle = .rounded
        pickFileBtn.controlSize = .small

        let retryBtn = NSButton(title: "重试 ⌘R", target: self, action: #selector(retryCurrentImage))
        retryBtn.bezelStyle = .rounded
        retryBtn.controlSize = .small

        enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        enginePopup.controlSize = .small
        enginePopup.addItems(withTitles: OcrEngine.allCases.map(\.title))
        let engineIdx = OcrEngine.allCases.firstIndex { $0.rawValue == Config.shared.ocrEngine } ?? 0
        enginePopup.selectItem(at: engineIdx)
        enginePopup.target = self
        enginePopup.action = #selector(changeEngine(_:))

        pinButton = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: "固定窗口") ?? NSImage(),
                             target: self, action: #selector(togglePin))
        pinButton.bezelStyle = .rounded
        pinButton.controlSize = .small
        pinButton.toolTip = "固定窗口 ⌘P（右键可强制关闭）"

        // 右键菜单：强制关闭窗口（对齐 Bob 1.21.0）
        let pinMenu = NSMenu()
        let forceClose = NSMenuItem(title: "关闭窗口", action: #selector(forceCloseWindow), keyEquivalent: "")
        forceClose.target = self
        pinMenu.addItem(forceClose)
        pinButton.menu = pinMenu

        let topBar = NSStackView(views: [snipBtn, pickFileBtn, retryBtn, NSView(), enginePopup, pinButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // 中部左右分割区
        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // 必须给一个初始 frame 并打开竖直伸缩：只 new 一个零尺寸的 NSTextView 塞进
        // scrollView，文字是有内容的但一个像素都不画——用户看到的是右边整片空白。
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 320))
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 380, height: CGFloat.greatestFiniteMagnitude)

        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        // 只设 fillEqually 不够：NSImageView 的固有宽度（原图 760pt）会压过
        // NSScrollView 的 0 固有宽度，结果文字区被挤成 0 宽——用户看到"右边一片空白"。
        // 显式等宽约束，图片再多也只能占一半。
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let splitStack = NSStackView(views: [imageView, textScroll])
        splitStack.orientation = .horizontal
        splitStack.distribution = .fill
        splitStack.spacing = 10
        splitStack.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalTo: textScroll.widthAnchor).isActive = true

        // 底部控制栏
        continuousButton = NSButton(title: "连续拼接", target: self, action: #selector(toggleContinuous))
        continuousButton.setButtonType(.pushOnPushOff)
        continuousButton.bezelStyle = .rounded
        continuousButton.controlSize = .small
        continuousButton.toolTip = "开启后多次截图识别的内容将按顺序追加拼接"

        lockAreaButton = NSButton(title: "锁定选区", target: self, action: #selector(toggleLockArea))
        lockAreaButton.setButtonType(.pushOnPushOff)
        lockAreaButton.bezelStyle = .rounded
        lockAreaButton.controlSize = .small
        lockAreaButton.toolTip = "记住上次截图坐标区域，下次无需拉框直接重截（看生肉视频神器）"

        autoCopyButton = NSButton(title: "自动复制", target: self, action: #selector(toggleAutoCopy))
        autoCopyButton.setButtonType(.switch)
        autoCopyButton.controlSize = .small

        statusLabel = NSTextField(labelWithString: "就绪")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let clearBtn = NSButton(title: "清空", target: self, action: #selector(clearText))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small

        let copyBtn = NSButton(title: "复制", target: self, action: #selector(copyAllText))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small

        let translateBtn = NSButton(title: "去翻译 →", target: self, action: #selector(sendToTranslate))
        translateBtn.bezelStyle = .rounded
        translateBtn.controlSize = .small
        translateBtn.keyEquivalent = "\r"

        let bottomBar = NSStackView(views: [
            continuousButton, lockAreaButton, autoCopyButton,
            statusLabel, NSView(),
            clearBtn, copyBtn, translateBtn
        ])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(topBar)
        container.addSubview(splitStack)
        container.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            splitStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            splitStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            splitStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            splitStack.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        panel.contentView = container
        self.window = panel
        installKeyMonitor()
    }

    private func updateToggleStates() {
        let config = Config.shared
        continuousButton?.state = config.ocrContinuous ? .on : .off
        continuousButton?.contentTintColor = config.ocrContinuous ? .systemOrange : nil

        lockAreaButton?.state = config.ocrLockArea ? .on : .off
        lockAreaButton?.contentTintColor = config.ocrLockArea ? .systemBlue : nil

        autoCopyButton?.state = config.ocrAutoCopy ? .on : .off

        pinButton?.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: "固定")
        pinButton?.contentTintColor = isPinned ? .controlAccentColor : nil
    }

    // MARK: - 动作

    @objc private func triggerSnip() {
        onRequestSnip?()
    }

    @objc private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let img = NSImage(contentsOf: url) else { return }
            var rect = NSRect(origin: .zero, size: img.size)
            if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                self?.recognizeAndPresent(image: cg)
            }
        }
    }

    @objc private func retryCurrentImage() {
        guard let img = currentCGImage else {
            statusLabel.stringValue = "没有当前图片，请先截图或选图"
            return
        }
        recognizeAndPresent(image: img)
    }

    @objc private func changeEngine(_ sender: NSPopUpButton) {
        let all = OcrEngine.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        Config.shared.ocrEngine = all[sender.indexOfSelectedItem].rawValue
        if currentCGImage != nil {
            retryCurrentImage()
        }
    }

    @objc private func togglePin() {
        isPinned.toggle()
        updateToggleStates()
    }

    @objc private func forceCloseWindow() {
        isPinned = false
        window?.close()
    }

    @objc private func toggleContinuous() {
        Config.shared.ocrContinuous = (continuousButton.state == .on)
        updateToggleStates()
    }

    @objc private func toggleLockArea() {
        Config.shared.ocrLockArea = (lockAreaButton.state == .on)
        updateToggleStates()
    }

    @objc private func toggleAutoCopy() {
        Config.shared.ocrAutoCopy = (autoCopyButton.state == .on)
    }

    @objc private func clearText() {
        textView.string = ""
        recognizedCount = 0
        statusLabel.stringValue = "已清空"
    }

    @objc private func copyAllText() {
        let text = textView.string
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        statusLabel.stringValue = "已复制全部文本"
    }

    @objc private func sendToTranslate() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onTranslateText?(text)
    }

    // MARK: - 键盘与代理

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {
                self.window?.close()
                return nil
            }
            if flags == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "w":
                    self.window?.close()
                    return nil
                case "r":
                    self.retryCurrentImage()
                    return nil
                case "p":
                    self.togglePin()
                    return nil
                default: break
                }
            }
            return event
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isPinned {
            // 失去焦点时不强行关掉整个独立工作台，防止用户去别的窗口比对时消失，按 ⌘W / esc 关
        }
    }

    // MARK: - 自测入口

    var windowForTesting: NSWindow? { window?.isVisible == true ? window : nil }
    func textForTesting() -> String { textView?.string ?? "" }
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
