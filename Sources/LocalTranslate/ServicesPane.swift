import AppKit

/// 所有面板的共同基类：拿到草稿和窗口，负责自己那一块的重画。
class PrefsPane: NSObject {
    unowned let owner: PreferencesWindow
    var draft: PrefsDraft

    init(draft: PrefsDraft, owner: PreferencesWindow) {
        self.owner = owner
        self.draft = draft
        super.init()
    }

    // 图标开关的处理放在基类：快捷键页和外观页都可能用到，
    // 放具体面板里另一页就会「找不到方法」。
    @objc func toggleMenuBarIcon(_ sender: NSButton) {
        change { $0.showMenuBarIcon = (sender.state == .on) }
        applyIconsNow()
    }

    @objc func toggleDockIcon(_ sender: NSButton) {
        change { $0.showDockIcon = (sender.state == .on) }
        applyIconsNow()
    }

    /// 立刻生效，不等保存：这两个开关就是要马上看到效果
    private func applyIconsNow() {
        let icons = AppIcons.resolve(menuBar: draft.showMenuBarIcon, dock: draft.showDockIcon)
        _ = AppIcons.apply(menuBar: icons.menuBar, dock: icons.dock, statusItem: nil)
        // 两个都关时 resolve 会保留 Dock；这一条写在开关的说明里，不另弹提示
    }


    func build() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        configure(stack)
        return stack
    }

    func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("还没做这一页"))
    }

    /// 改动走 owner，统一刷新撤销/保存状态
    func change(_ block: @escaping (inout PrefsDraft) -> Void, rebuild: Bool = true) {
        owner.mutate(block, rebuild: rebuild)
    }

    func touch(_ block: @escaping (inout PrefsDraft) -> Void) {
        owner.touch(block)
    }
}

// MARK: - 服务

/// 服务列表：一模型一条目，带开关；选中哪条右边显示它的配置。
final class ServicesPane: PrefsPane, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {

    /// 插件配置控件 → (插件目录名, 选项 id, 菜单可选值)
    private var pluginOptionContext: [ObjectIdentifier: (String, String, [String])] = [:]

    private var table: NSTableView!
    private var detail: NSView!
    private var detailContent: NSStackView!
    private var keyFields: [String: NSTextField] = [:]
    private var statusText: NSTextField!
    private var selectedRow = 0
    private var magpieStatus = NSTextField(labelWithString: "")
    private var magpieURLField = NSTextField()
    private var magpieKeyField: NSTextField?
    private var magpieModels: [MagpieClient.Model] = []
    private var addFromMagpieButton: NSButton?

    override func configure(_ stack: NSStackView) {
        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("service"))
        column.width = 250
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self

        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .bezelBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.widthAnchor.constraint(equalToConstant: 244).isActive = true
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        // 用下拉选预设，按「免费免配置 / 免费额度 / 需密钥」分组，清晰明了
        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.controlSize = .small
        add.addItem(withTitle: "＋ 添加服务")
        let addMenu = NSMenu()
        addMenu.autoenablesItems = false
        addMenu.addItem(NSMenuItem(title: "＋ 添加服务", action: nil, keyEquivalent: ""))

        func appendGroup(_ title: String, _ presets: [ServiceProfile.Preset]) {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            addMenu.addItem(header)
            for p in presets {
                let item = NSMenuItem(title: p.menuTitle, action: #selector(pickPresetItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.rawValue
                addMenu.addItem(item)
            }
        }

        appendGroup("── 免费 · 免配置（开箱即用）──", [.apple, .google, .mymemory, .deeplx, .ollama, .lmstudio])
        addMenu.addItem(.separator())
        appendGroup("── 免费额度（需免费注册 Key）──", [.zhipu, .siliconflow, .groq, .gemini, .deepl, .tencent, .baidu, .niu])
        addMenu.addItem(.separator())
        appendGroup("── 云端 / 付费大模型（需 API Key）──", [.deepseek, .openai, .claude, .moonshot, .qwen, .doubao, .ernie, .hunyuan, .grok, .openrouter, .azureLike, .ai302, .aihubmix, .gitee, .sophnet, .minimax, .microsoft, .youdao, .caiyun, .amazon, .custom])
        add.menu = addMenu

        let remove = NSButton(title: "－", target: self, action: #selector(removeService))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.toolTip = "删除选中服务"

        let resetDefaults = NSButton(title: "恢复免密默认", target: self, action: #selector(resetToFreeDefaults))
        resetDefaults.bezelStyle = .rounded
        resetDefaults.controlSize = .small
        resetDefaults.toolTip = "重置为仅包含 Apple 翻译与谷歌免密钥翻译的开箱默认配置"

        let listButtons = NSStackView(views: [add, remove, resetDefaults, NSView()])
        listButtons.orientation = .horizontal
        listButtons.spacing = 4

        let left = NSStackView(views: [listScroll, listButtons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8

        detail = FlippedDoc()
        detail.translatesAutoresizingMaskIntoConstraints = false

        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        // 详情列吃剩余宽度，不给固定下限：写死 380 会把整块顶到 722pt，
        // 比可用宽度还宽，窄窗口下直接被裁掉
        detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        // documentView 必须贴住裁剪视图并跟着宽度走，否则它一直是 0x0，
        // 表现为「右边详情区一片空白」——光看有没有控件是查不出来的。
        let content = NSStackView()
        content.orientation = .vertical
        // 整列同宽：不然每行只按自己内容撑宽，"显示名"这种短值会缩成一条缝
        content.alignment = .width
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        detailContent = content
        detail.addSubview(content)
        NSLayoutConstraint.activate([
            detailContent.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            detailContent.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            detailContent.topAnchor.constraint(equalTo: detail.topAnchor),
            detailContent.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            detailContent.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detail.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
        ])

        let columns = NSStackView(views: [left, detailScroll])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 18
        columns.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(buildMagpieCard())
        stack.addArrangedSubview(columns)
        stack.addArrangedSubview(spacer())

        statusText = NSTextField(labelWithString: "")
        statusText.font = NSFont.systemFont(ofSize: 11)
        statusText.textColor = .secondaryLabelColor

        buildDetail()
    }

    /// 顶部这块：Magpie 网关地址、连接状态、从它的模型列表里挑。
    /// 做成卡片放在服务页最上面，是因为它本质上是"批量添加服务"的入口。
    private func buildMagpieCard() -> NSView {
        let title = NSTextField(labelWithString: "从 Magpie 接入")
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        magpieStatus.font = NSFont.systemFont(ofSize: 11)
        magpieStatus.textColor = .secondaryLabelColor
        magpieStatus.stringValue = "点「检测」看看 Magpie 在不在"

        magpieURLField.stringValue = draft.magpieBaseURL
        magpieURLField.placeholderString = "http://127.0.0.1:3425"
        magpieURLField.font = NSFont.systemFont(ofSize: 11)
        magpieURLField.controlSize = .small
        magpieURLField.target = self
        magpieURLField.action = #selector(commitMagpieURL(_:))
        magpieURLField.translatesAutoresizingMaskIntoConstraints = false
        magpieURLField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let check = NSButton(title: "检测", target: self, action: #selector(checkMagpie))
        check.bezelStyle = .rounded
        check.controlSize = .small

        let add = NSButton(title: "从 Magpie 添加模型…", target: self, action: #selector(openMagpiePicker))
        add.bezelStyle = .rounded
        add.controlSize = .small
        addFromMagpieButton = add

        let keyField = PrefsKit.textControl(Config.shared.magpieGatewayKey, placeholder: "gateway-key（可选）") as! NSTextField
        keyField.font = NSFont.systemFont(ofSize: 11)
        keyField.controlSize = .small
        keyField.target = self
        keyField.action = #selector(commitMagpieKey(_:))
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        magpieKeyField = keyField

        let row1 = NSStackView(views: [magpieURLField, check, add, NSView()])
        row1.orientation = .horizontal
        row1.spacing = 8
        row1.alignment = .centerY

        let row2 = NSStackView(views: [keyField, magpieStatus, NSView()])
        row2.orientation = .horizontal
        row2.spacing = 8
        row2.alignment = .centerY

        let inner = NSStackView(views: [title, row1, row2])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 7

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -12),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return box
    }

    @objc private func commitMagpieURL(_ sender: NSTextField) {
        change({ $0.magpieBaseURL = sender.stringValue }, rebuild: false)
    }

    @objc private func commitMagpieKey(_ sender: NSTextField) {
        SecretStore.shared.setAPIKey(sender.stringValue, account: "magpie-gateway")
    }

    @objc private func checkMagpie() {
        magpieStatus.stringValue = "检测中…"
        magpieStatus.textColor = .secondaryLabelColor
        addFromMagpieButton?.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = MagpieClient.probe()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.magpieModels = snapshot.models
                self.magpieStatus.stringValue = snapshot.detail
                self.magpieStatus.textColor = snapshot.reachable ? .systemGreen : .systemOrange
                self.addFromMagpieButton?.isEnabled = snapshot.reachable && !snapshot.models.isEmpty
            }
        }
    }

    @objc private func openMagpiePicker() {
        let start = { [weak self] (models: [MagpieClient.Model]) in
            guard let self, let window = self.table.window else { return }
            let sheet = MagpiePickerSheet(models: models) { picked in
                self.change { model in
                    for item in picked { model.profiles.append(MagpieClient.profile(for: item)) }
                }
            }
            self.pickerSheet = sheet   // 必须留住，否则 sheet 的 dataSource 会被释放
            sheet.present(in: window)
        }

        if !magpieModels.isEmpty {
            start(magpieModels)
            return
        }
        magpieStatus.stringValue = "正在拉取模型列表…"
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = MagpieClient.probe()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.magpieModels = snapshot.models
                self.magpieStatus.stringValue = snapshot.detail
                self.magpieStatus.textColor = snapshot.reachable ? .systemGreen : .systemOrange
                if snapshot.reachable {
                    start(snapshot.models)
                } else {
                    self.addFromMagpieButton?.isEnabled = false
                }
            }
        }
    }

    private var pickerSheet: MagpiePickerSheet?

    private func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    // MARK: 列表

    func numberOfRows(in tableView: NSTableView) -> Int { draft.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard draft.profiles.indices.contains(row) else { return nil }
        let profile = draft.profiles[row]
        let needsKey = profile.providerKind.needsKey
        let keySet = !SecretStore.shared.apiKey(for: profile.keyAccount).isEmpty

        let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleService(_:)))
        toggle.state = profile.enabled ? .on : .off
        toggle.tag = row
        toggle.allowsMixedState = false

        let name = NSTextField(labelWithString: profile.name.isEmpty ? "未命名" : profile.name)
        name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail

        let source = MagpieClient.isMagpieProfile(profile) ? "Magpie" : nil
        let effectiveZeroKey = !needsKey || profile.isLoopback
        let badgeText: String
        let badgeColor: NSColor
        if let source, keySet {
            badgeText = "\(source) · 已配密钥"
            badgeColor = .secondaryLabelColor
        } else if let source {
            badgeText = "\(source) · 免密钥"
            badgeColor = .systemGreen
        } else if effectiveZeroKey {
            badgeText = profile.isLoopback ? "本地 · 免密钥" : "免费 · 免密钥"
            badgeColor = .systemGreen
        } else {
            badgeText = keySet ? "已配密钥" : "需填密钥"
            badgeColor = keySet ? .secondaryLabelColor : .systemOrange
        }
        let badge = NSTextField(labelWithString: badgeText)
        badge.font = NSFont.systemFont(ofSize: 10)
        badge.textColor = badgeColor

        let sub = NSStackView(views: [badge, NSView()])
        sub.orientation = .horizontal

        let middle = NSStackView(views: [name, sub])
        middle.orientation = .vertical
        middle.alignment = .leading
        middle.spacing = 1

        let row = NSStackView(views: [toggle, middle])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedRow = table.selectedRow
        buildDetail()
    }

    @objc private func toggleService(_ sender: NSButton) {
        let row = sender.tag
        guard draft.profiles.indices.contains(row) else { return }
        change({ $0.profiles[row].enabled = (sender.state == .on) }, rebuild: false)
        // 只刷这一行，别把整页重建导致选中丢掉
        table.reloadData()
    }

    @objc private func pickPresetItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = ServiceProfile.Preset(rawValue: raw) else { return }
        change { $0.profiles.append(preset.makeProfile()) }
    }

    @objc private func resetToFreeDefaults() {
        change { model in
            model.profiles = ProfileStore.defaultProfiles()
        }
        selectedRow = 0
        table.reloadData()
        buildDetail()
    }

    @objc private func removeService() {
        let row = max(0, table.selectedRow)
        guard draft.profiles.indices.contains(row) else { return }
        change { model in
            model.profiles.remove(at: row)
            if model.profiles.isEmpty { model.profiles = ProfileStore.defaultProfiles() }
        }
    }

    // MARK: 详情

    private func buildDetail() {
        detailContent.arrangedSubviews.forEach { $0.removeFromSuperview() }
        extraPromptView = nil
        userTemplateView = nil

        guard draft.profiles.indices.contains(selectedRow) else {
            detailContent.addArrangedSubview(PrefsKit.sectionTitle("左侧选一个服务"))
            return
        }
        let profile = draft.profiles[selectedRow]
        let kind = profile.providerKind

        detailContent.addArrangedSubview(PrefsKit.sectionTitle(profile.name.isEmpty ? "新服务" : profile.name,
                                                       note: "开着的会一起调用，卡片底部出现切换标签。"))

        let nameField = PrefsKit.textControl(profile.name, placeholder: kind.title) as! NSTextField
        nameField.target = self
        nameField.action = #selector(commitName(_:))
        detailContent.addArrangedSubview(PrefsKit.row("显示名", nameField, note: "只影响界面显示"))

        let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        providerPopup.controlSize = .small
        providerPopup.addItems(withTitles: ProviderKind.allCases.map(\.title))
        providerPopup.selectItem(at: ProviderKind.allCases.firstIndex(of: kind) ?? 0)
        providerPopup.target = self
        providerPopup.action = #selector(commitProvider(_:))
        detailContent.addArrangedSubview(PrefsKit.row("服务商", providerPopup,
            note: "切换服务商会自动填入对应的默认协议与接口地址。"))

        // 1) Apple 系统原生翻译（完全免配置，隐藏无用的 URL / 模型 / Key 栏）
        if kind == .apple {
            let infoLabel = NSTextField(wrappingLabelWithString: "Apple 系统原生离线翻译引擎：免费、免配置、零网络开销，直接利用系统本地语言包执行翻译。若首次翻译某语种提示未下载语言包，请到系统设置下载。")
            infoLabel.font = NSFont.systemFont(ofSize: 11)
            infoLabel.textColor = .secondaryLabelColor
            detailContent.addArrangedSubview(infoLabel)

            let openSysBtn = NSButton(title: "打开系统翻译语言设置…", target: self, action: #selector(openSystemTranslateSettings))
            openSysBtn.bezelStyle = .rounded
            openSysBtn.controlSize = .small

            let test = NSButton(title: "测试连接", target: self, action: #selector(testConnection(_:)))
            test.bezelStyle = .rounded
            test.controlSize = .small
            detailContent.addArrangedSubview(NSStackView(views: [test, openSysBtn, statusText]).withSpacing(8))
            return
        }

        // 2) JavaScript 插件
        if kind == .plugin {
            let plugins = PluginRuntime.installed()
            let filePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            filePopup.controlSize = .small
            if plugins.isEmpty {
                filePopup.addItem(withTitle: "（插件目录为空）")
            } else {
                filePopup.addItems(withTitles: plugins)
                if let cur = profile.pluginFile, let idx = plugins.firstIndex(of: cur) {
                    filePopup.selectItem(at: idx)
                }
            }
            filePopup.target = self
            filePopup.action = #selector(commitPluginFile(_:))
            detailContent.addArrangedSubview(PrefsKit.row("插件文件", filePopup,
                note: "在菜单栏点击「安装 Bob 插件 (.bobplugin)…」即可直接导入社区插件。"))

            // 插件自己的 $option 声明（API Key、音色、地区……）
            if let pluginFile = profile.pluginFile, !pluginFile.isEmpty {
                let declarations = PluginOptions.declarations(plugin: pluginFile)
                if !declarations.isEmpty {
                    detailContent.addArrangedSubview(PrefsKit.sectionTitle("插件设置",
                        note: "这些是插件声明的配置项，填好保存后翻译时以 \(pluginFile) 的 $option 传进去。"))
                    for declaration in declarations {
                        detailContent.addArrangedSubview(makePluginOptionRow(declaration, plugin: pluginFile))
                    }
                }
            }
        }

        // 3) 需要网络地址的协议
        if kind != .plugin {
            let urlPlaceholder = kind.defaultBaseURL.isEmpty ? "https://api.openai.com/v1" : kind.defaultBaseURL
            let urlField = PrefsKit.textControl(profile.baseURL, placeholder: urlPlaceholder) as! NSTextField
            urlField.target = self
            urlField.action = #selector(commitBaseURL(_:))
            urlField.delegate = self
            let urlNote = kind == .openai ? "不含 /chat/completions 也行，程序会自己补。" : "服务接口基础地址，通常保持默认即可。"
            detailContent.addArrangedSubview(PrefsKit.row("Base URL", urlField, note: urlNote))
        }

        // 4) 大模型类才需要模型名（传统翻译引擎 Google/MyMemory/DeepL/百度/腾讯/有道 不需要模型名）
        if kind == .openai || kind == .claude || kind == .gemini {
            let modelPlaceholder = kind == .claude ? "claude-3-5-sonnet-latest" : (kind == .gemini ? "gemini-2.0-flash" : "gpt-4o-mini")
            let modelField = PrefsKit.textControl(profile.model, placeholder: modelPlaceholder) as! NSTextField
            modelField.target = self
            modelField.action = #selector(commitModel(_:))
            detailContent.addArrangedSubview(PrefsKit.row("模型名", modelField))
        }

        // 5) 需要或可选密钥的服务才显示 API Key 输入框
        if kind.needsKey || kind == .deeplx {
            let keyField = PrefsKit.textControl(SecretStore.shared.apiKey(for: profile.keyAccount),
                                               placeholder: kind.keyHint,
                                               secure: !Config.shared.showKeyPlain) as! NSTextField
            keyField.target = self
            keyField.action = #selector(commitKey(_:))
            keyFields[profile.id] = keyField
            let reveal = NSButton(checkboxWithTitle: "明文", target: self, action: #selector(revealKey(_:)))
            reveal.state = Config.shared.showKeyPlain ? .on : .off
            let keyRow = NSStackView(views: [keyField, reveal])
            keyRow.orientation = .horizontal
            keyRow.spacing = 6
            let keyNote = profile.isLoopback
                ? "检测到本机回环地址（Ollama / LM Studio / Magpie），通常无需填写 API Key。"
                : "按服务分开存进系统钥匙串；钥匙串不可用时退回 0600 权限的本地文件。"
            detailContent.addArrangedSubview(PrefsKit.row("API Key", keyRow, note: keyNote))
        } else if kind == .google || kind == .mymemory {
            let freeHint = NSTextField(labelWithString: "✓ 免费免密钥开放接口：无需申请 API Key，开箱即可直接翻译。")
            freeHint.font = NSFont.systemFont(ofSize: 11)
            freeHint.textColor = .systemGreen
            detailContent.addArrangedSubview(freeHint)
        }

        // 6) 大模型专属微调参数（推理强度 + Prompt 模板）
        if kind == .openai {
            let effortOptions: [(value: String, label: String)] = [
                ("default", "默认 (不发送字段)"),
                ("none", "关闭深度思考 (none)"),
                ("minimal", "极速思考 (minimal)"),
                ("low", "低强度 (low)"),
                ("medium", "中强度 (medium)"),
                ("high", "高强度 (high)")
            ]
            let effortPopup = PrefsKit.popup(
                effortOptions.map(\.label),
                selected: effortOptions.firstIndex { $0.value == (profile.reasoningEffort ?? "default") } ?? 0
            )
            effortPopup.target = self
            effortPopup.action = #selector(commitReasoningEffort(_:))
            detailContent.addArrangedSubview(PrefsKit.row("推理强度", effortPopup,
                note: "o系列/GPT-5/DeepSeek 等推理模型调低档位可大幅提速首字响应。"))
        }

        if kind == .openai || kind == .claude || kind == .gemini {
            let promptView = makeMultiline(profile.extraPrompt, height: 56)
            extraPromptView = promptView.view
            detailContent.addArrangedSubview(PrefsKit.row("补充 Prompt", promptView.container,
                note: "追加到系统提示后面，支持变量 $query.detectToLang、$query.text"))

            let userTplView = makeMultiline(profile.userPromptTemplate ?? "", height: 56)
            userTemplateView = userTplView.view
            detailContent.addArrangedSubview(PrefsKit.row("用户指令模板", userTplView.container,
                note: "可选。如：把下面内容翻成 $query.detectToLang：\\n$query.text"))
        }

        let test = NSButton(title: "测试连接", target: self, action: #selector(testConnection(_:)))
        test.bezelStyle = .rounded
        test.controlSize = .small
        detailContent.addArrangedSubview(NSStackView(views: [test, statusText]).withSpacing(10))
    }

    @objc private func openSystemTranslateSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private var promptTextViews: [NSTextView] = []
    private weak var extraPromptView: NSTextView?
    private weak var userTemplateView: NSTextView?

    private func makeMultiline(_ text: String, height: CGFloat) -> (container: NSView, view: NSTextView) {
        let view = NSTextView()
        view.string = text
        view.font = NSFont.systemFont(ofSize: 12)
        view.isRichText = false
        view.isVerticallyResizable = true
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.delegate = self
        promptTextViews.append(view)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return (scroll, view)
    }

    // MARK: 提交

    private func currentProfileIndex() -> Int? { draft.profiles.indices.contains(selectedRow) ? selectedRow : nil }

    @objc private func commitName(_ sender: NSTextField) {
        guard let index = currentProfileIndex() else { return }
        change { $0.profiles[index].name = sender.stringValue }
    }

    @objc private func commitProvider(_ sender: NSPopUpButton) {
        guard let index = currentProfileIndex(),
              ProviderKind.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let kind = ProviderKind.allCases[sender.indexOfSelectedItem]
        change { model in
            let old = model.profiles[index].providerKind
            model.profiles[index].provider = kind.rawValue
            // 换了服务商，Base URL 如果还是上一个的默认值，就跟着换成新默认值
            let current = model.profiles[index].baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty || current == old.defaultBaseURL {
                model.profiles[index].baseURL = kind.defaultBaseURL
            }
            if model.profiles[index].name.isEmpty || model.profiles[index].name == old.title {
                model.profiles[index].name = kind.title
            }
        }
    }

    /// 渲染一条插件配置项（text / menu / switch）
    private func makePluginOptionRow(_ declaration: PluginOptions.Declaration, plugin: String) -> NSView {
        let current = PluginOptions.values(for: plugin)[declaration.identifier] ?? declaration.defaultValue

        switch declaration.type {
        case "menu":
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.addItems(withTitles: declaration.menuTitles.isEmpty ? [current] : declaration.menuTitles)
            if let index = declaration.menuValues.firstIndex(of: current) {
                popup.selectItem(at: index)
            }
            let row = PrefsKit.row(declaration.title, popup, note: declaration.note.isEmpty ? nil : declaration.note)
            popup.target = self
            popup.action = #selector(pluginOptionMenuChanged(_:))
            pluginOptionContext[ObjectIdentifier(popup)] = (plugin, declaration.identifier, declaration.menuValues)
            return row
        case "switch":
            let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            check.state = (current == "true" || current == "1") ? .on : .off
            pluginOptionContext[ObjectIdentifier(check)] = (plugin, declaration.identifier, [])
            let row = PrefsKit.row(declaration.title, check, note: declaration.note.isEmpty ? nil : declaration.note)
            check.target = self
            check.action = #selector(pluginOptionSwitchChanged(_:))
            return row
        default:
            let field = PrefsKit.textControl(current, placeholder: declaration.title) as! NSTextField
            if declaration.isSecret {
                field.cell?.isScrollable = true
            }
            pluginOptionContext[ObjectIdentifier(field)] = (plugin, declaration.identifier, [])
            field.identifier = NSUserInterfaceItemIdentifier(plugin + "::" + declaration.identifier)
            field.target = self
            field.action = #selector(pluginOptionTextChanged(_:))
            return PrefsKit.row(declaration.title, field, note: declaration.note.isEmpty ? nil : declaration.note)
        }
    }

    @objc private func pluginOptionMenuChanged(_ sender: NSPopUpButton) {
        guard let context = pluginOptionContext[ObjectIdentifier(sender)] else { return }
        let index = max(0, sender.indexOfSelectedItem)
        let value = context.2.indices.contains(index) ? context.2[index] : sender.titleOfSelectedItem ?? ""
        PluginOptions.set(value, for: context.1, plugin: context.0)
        owner.flashSaved("已保存插件设置")
    }

    @objc private func pluginOptionSwitchChanged(_ sender: NSButton) {
        guard let context = pluginOptionContext[ObjectIdentifier(sender)] else { return }
        PluginOptions.set(sender.state == .on ? "true" : "false", for: context.1, plugin: context.0)
        owner.flashSaved("已保存插件设置")
    }

    @objc private func pluginOptionTextChanged(_ sender: NSTextField) {
        guard let context = pluginOptionContext[ObjectIdentifier(sender)] else { return }
        PluginOptions.set(sender.stringValue, for: context.1, plugin: context.0)
        owner.flashSaved("已保存插件设置")
    }

    @objc private func commitPluginFile(_ sender: NSPopUpButton) {
        guard let index = currentProfileIndex() else { return }
        let file = sender.titleOfSelectedItem ?? ""
        change { $0.profiles[index].pluginFile = file.isEmpty ? nil : file }
    }

    @objc private func commitBaseURL(_ sender: NSTextField) {
        guard let index = currentProfileIndex() else { return }
        change { $0.profiles[index].baseURL = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @objc private func commitModel(_ sender: NSTextField) {
        guard let index = currentProfileIndex() else { return }
        change { $0.profiles[index].model = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @objc private func commitKey(_ sender: NSTextField) {
        guard let index = currentProfileIndex() else { return }
        let id = draft.profiles[index].id
        change({ $0.keyEdits[id] = sender.stringValue }, rebuild: false)
        table.reloadData()
    }

    @objc private func revealKey(_ sender: NSButton) {
        Config.shared.showKeyPlain = (sender.state == .on)
        paneRebuild()
    }

    private func paneRebuild() {
        owner.mutate({ _ in }, rebuild: true)
    }

    @objc private func testConnection(_ sender: NSButton) {
        guard let index = currentProfileIndex() else { return }
        var profile = draft.profiles[index]
        if let pending = draft.keyEdits[profile.id] {
            // 还没保存的密钥也拿去试，用户不必先保存再测
            SecretStore.shared.setAPIKey(pending, account: profile.keyAccount)
        }
        sender.isEnabled = false
        statusText.stringValue = "测试中…"
        statusText.textColor = .secondaryLabelColor

        Task { [weak self] in
            let result = await Translator.validate(profile: profile)
            await MainActor.run {
                sender.isEnabled = true
                guard let self else { return }
                switch result {
                case .success:
                    self.statusText.stringValue = "连接正常"
                    self.statusText.textColor = .systemGreen
                case .failure(let error):
                    self.statusText.stringValue = error.localizedDescription
                    self.statusText.textColor = .systemRed
                }
            }
        }
    }

    @objc private func commitReasoningEffort(_ sender: NSPopUpButton) {
        guard let index = currentProfileIndex() else { return }
        let efforts = ["default", "none", "minimal", "low", "medium", "high"]
        guard efforts.indices.contains(sender.indexOfSelectedItem) else { return }
        let value = efforts[sender.indexOfSelectedItem]
        change { $0.profiles[index].reasoningEffort = (value == "default" ? nil : value) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        guard let index = currentProfileIndex() else { return }
        if field.placeholderString?.contains("api.openai.com") == true {
            change({ $0.profiles[index].baseURL = field.stringValue }, rebuild: false)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView,
              let index = currentProfileIndex() else { return }
        if tv === extraPromptView {
            change({ $0.profiles[index].extraPrompt = tv.string }, rebuild: false)
        } else if tv === userTemplateView {
            let val = tv.string
            change({ $0.profiles[index].userPromptTemplate = val.isEmpty ? nil : val }, rebuild: false)
        }
    }
}

extension NSStackView {
    func withSpacing(_ value: CGFloat) -> NSStackView {
        spacing = value
        return self
    }
}
