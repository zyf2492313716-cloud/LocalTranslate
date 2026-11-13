import AppKit

/// 菜单栏弹出面板。
///
/// Bob 点图标弹出的是一个面板（能直接打字翻、选语言服务、看最近几条），
/// 不是一个纯菜单列表。这里补上：左键弹面板，右键仍然是原来的菜单。
///
/// 面板里不重复实现翻译链路，只把「要翻什么、用哪个服务」交给宿主去跑，
/// 免得两套逻辑各修各的 bug。
final class StatusPanelController: NSObject, NSPopoverDelegate, NSSearchFieldDelegate {

    private var popover: NSPopover?
    private var textField: NSTextField!
    private var langPopup: NSPopUpButton!
    private var profilePopup: NSPopUpButton!
    private var recentStack: NSStackView!
    private var profiles: [ServiceProfile] = []

    /// 点「翻译」：把文本和指定的服务交出去
    var onTranslate: ((String, ServiceProfile?) -> Void)?
    /// 底部快捷入口
    var onOpenInput: (() -> Void)?
    var onOpenDictionary: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover?.isShown == true {
            close()
            return
        }
        build()
        refresh()
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover?.contentViewController?.view.window?.makeKey()
        textField.becomeFirstResponder()
    }

    func close() {
        popover?.performClose(nil)
    }

    var isShown: Bool { popover?.isShown == true }

    private func build() {
        guard popover == nil else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false

        textField = NSTextField()
        textField.placeholderString = "输入要翻译的文字，回车翻译"
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.target = self
        textField.action = #selector(commitText)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        langPopup.controlSize = .small
        langPopup.addItems(withTitles: Languages.all.map(\.name))
        langPopup.target = self
        langPopup.action = #selector(pickLanguage(_:))

        profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        profilePopup.controlSize = .small
        profilePopup.target = self
        profilePopup.action = #selector(pickProfile(_:))

        let translateButton = NSButton(title: "翻译", target: self, action: #selector(commitText))
        translateButton.bezelStyle = .rounded
        translateButton.controlSize = .small
        translateButton.keyEquivalent = "\r"

        let row1 = NSStackView(views: [textField])
        row1.orientation = .horizontal

        let row2 = NSStackView(views: [langPopup, profilePopup, NSView(), translateButton])
        row2.orientation = .horizontal
        row2.spacing = 8
        row2.alignment = .centerY
        row2.translatesAutoresizingMaskIntoConstraints = false
        row2.widthAnchor.constraint(equalToConstant: 300).isActive = true

        recentStack = NSStackView()
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        recentStack.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let quick = NSStackView()
        quick.orientation = .horizontal
        quick.spacing = 6
        for (title, action) in [("输入翻译", #selector(openInput)),
                                ("词典", #selector(openDictionary)),
                                ("设置", #selector(openSettings))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .mini
            quick.addArrangedSubview(button)
        }

        let root = NSStackView(views: [row1, row2, recentStack, quick])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
    }

    /// 每次弹出都刷新：语言、服务列表、最近记录都可能变过
    func refresh() {
        guard langPopup != nil else { return }

        let languages = Languages.all
        if let index = languages.firstIndex(where: { $0.code == Config.shared.targetLanguage }) {
            langPopup.selectItem(at: index)
        }

        profiles = ProfileStore.enabled()
        profilePopup.removeAllItems()
        if profiles.isEmpty {
            profilePopup.addItem(withTitle: "没有可用服务")
            profilePopup.isEnabled = false
        } else {
            profilePopup.isEnabled = true
            profilePopup.addItems(withTitles: profiles.map { $0.name })
            if let saved = Config.shared.panelProfileID,
               let index = profiles.firstIndex(where: { $0.id == saved }) {
                profilePopup.selectItem(at: index)
            }
        }

        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recent = HistoryStore.all().prefix(3)
        if recent.isEmpty {
            let label = NSTextField(labelWithString: "还没有翻译记录")
            label.font = NSFont.systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            recentStack.addArrangedSubview(label)
        } else {
            for entry in recent {
                let title = entry.source
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                let button = NSButton(title: String(title.prefix(28)), target: self, action: #selector(pickRecent(_:)))
                button.bezelStyle = .inline
                button.controlSize = .mini
                button.alignment = .left
                button.identifier = NSUserInterfaceItemIdentifier(entry.source)
                button.toolTip = entry.source
                recentStack.addArrangedSubview(button)
            }
        }
    }

    private var selectedProfile: ServiceProfile? {
        let index = profilePopup.indexOfSelectedItem
        guard profiles.indices.contains(index) else { return nil }
        return profiles[index]
    }

    // MARK: - 动作

    @objc private func pickLanguage(_ sender: NSPopUpButton) {
        let languages = Languages.all
        guard languages.indices.contains(sender.indexOfSelectedItem) else { return }
        Config.shared.targetLanguage = languages[sender.indexOfSelectedItem].code
    }

    @objc private func pickProfile(_ sender: NSPopUpButton) {
        if let profile = selectedProfile {
            Config.shared.panelProfileID = profile.id
        }
    }

    @objc private func commitText() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onTranslate?(text, selectedProfile)
        textField.stringValue = ""
        close()
    }

    @objc private func pickRecent(_ sender: NSButton) {
        guard let source = sender.identifier?.rawValue, !source.isEmpty else { return }
        onTranslate?(source, selectedProfile)
        close()
    }

    @objc private func openInput() { close(); onOpenInput?() }
    @objc private func openDictionary() { close(); onOpenDictionary?() }
    @objc private func openSettings() { close(); onOpenSettings?() }

    // MARK: - 自测入口

    /// 面板里的可见文字，给界面自检用
    func visibleTextSnapshot() -> [String] {
        guard let view = popover?.contentViewController?.view else { return [] }
        var bag: [String] = []
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, !f.stringValue.isEmpty { bag.append(f.stringValue) }
            if let f = v as? NSTextField, let placeholder = f.placeholderString, !placeholder.isEmpty {
                bag.append(placeholder)
            }
            if let b = v as? NSButton, !b.title.isEmpty { bag.append(b.title) }
            if let p = v as? NSPopUpButton { bag.append(contentsOf: p.itemTitles) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return bag
    }

    /// 自测：不弹真窗口也能建出面板内容
    func buildForTesting() { build(); refresh() }
}