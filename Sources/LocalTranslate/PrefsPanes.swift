import AppKit

// MARK: - 翻译设置

final class TranslationPane: PrefsPane, NSTextViewDelegate {
    private var promptRef: NSTextView?

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === promptRef else { return }
        touch { $0.systemPrompt = view.string }
    }

    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("语言与模式", note: "影响每一次请求，不需要重启。"))

        let languages = Languages.all
        let popup = PrefsKit.popup(languages.map(\.name),
                                   selected: languages.firstIndex(where: { $0.code == draft.targetLanguage }) ?? 0)
        popup.target = self
        popup.action = #selector(pickLanguage(_:))
        stack.addArrangedSubview(PrefsKit.row("目标语言", popup))

        let srcOptions: [(code: String, name: String)] = [("auto", "自动检测")] + languages
        let srcPopup = PrefsKit.popup(srcOptions.map(\.name),
                                      selected: srcOptions.firstIndex(where: { $0.code == draft.sourceLanguage }) ?? 0)
        srcPopup.target = self
        srcPopup.action = #selector(pickSourceLanguage(_:))
        stack.addArrangedSubview(PrefsKit.row("源语言", srcPopup,
            note: "小语种自动检测常错，指定一下更准。默认「自动检测」，只有确定原文语种时才改。"))

        let primaryPopup = PrefsKit.popup(languages.map(\.name),
                                         selected: languages.firstIndex(where: { $0.code == draft.primaryLanguage }) ?? 0)
        primaryPopup.target = self
        primaryPopup.action = #selector(pickPrimaryLanguage(_:))
        stack.addArrangedSubview(PrefsKit.row("第一语言", primaryPopup, note: "母语（默认简体中文）"))

        let secondaryPopup = PrefsKit.popup(languages.map(\.name),
                                           selected: languages.firstIndex(where: { $0.code == draft.secondaryLanguage }) ?? (languages.firstIndex(where: { $0.code == "en" }) ?? 1))
        secondaryPopup.target = self
        secondaryPopup.action = #selector(pickSecondaryLanguage(_:))
        stack.addArrangedSubview(PrefsKit.row("第二语言", secondaryPopup, note: "常用外语（默认英语）"))

        let (autoSwitch, _) = PrefsKit.toggleRow("智能双语切换", isOn: draft.autoSwitchLanguage,
                                                note: "输入为第一语言时自动翻译为第二语言；输入为其他语言时自动翻译为第一语言。",
                                                target: self, action: #selector(toggleAutoSwitchLanguage(_:)))
        stack.addArrangedSubview(autoSwitch)

        let modes = TranslateMode.allCases.map { $0.title }
        let modePopup = PrefsKit.popup(modes, selected: TranslateMode.allCases.firstIndex(where: { $0.rawValue == draft.mode }) ?? 0)
        modePopup.target = self
        modePopup.action = #selector(pickMode(_:))
        stack.addArrangedSubview(PrefsKit.row("默认模式", modePopup, note: "翻译 / 润色 / 总结"))

        let promptScroll = NSScrollView()
        let promptView = NSTextView()
        promptView.string = draft.systemPrompt
        promptView.font = NSFont.systemFont(ofSize: 12)
        promptView.isRichText = false
        promptView.isVerticallyResizable = true
        promptView.textContainerInset = NSSize(width: 4, height: 4)
        promptScroll.documentView = promptView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.heightAnchor.constraint(equalToConstant: 68).isActive = true
        promptScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        promptView.delegate = self
        promptRef = promptView
        stack.addArrangedSubview(PrefsKit.row("补充 Prompt", promptScroll,
            note: "追加到系统提示后面，对所有服务生效；服务页里还能各加一条。比如「法律术语保留原文并加括号注释」。"))

        stack.addArrangedSubview(PrefsKit.sectionTitle("接口", note: "超时太短会让长文本翻译失败；5 到 300 秒。"))
        let slider = NSSlider(value: draft.timeoutSeconds, minValue: 5, maxValue: 300, target: self, action: #selector(timeoutChanged(_:)))
        slider.isContinuous = false
        let timeoutValue = NSTextField(labelWithString: "\(Int(draft.timeoutSeconds)) 秒")
        timeoutValue.font = NSFont.systemFont(ofSize: 11)
        timeoutValue.tag = 9001
        let row = NSStackView(views: [slider, timeoutValue])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        stack.addArrangedSubview(PrefsKit.row("请求超时", row))
    }

    @objc private func pickLanguage(_ sender: NSPopUpButton) {
        let all = Languages.all
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.targetLanguage = all[sender.indexOfSelectedItem].code }
    }

    @objc private func pickSourceLanguage(_ sender: NSPopUpButton) {
        let codes = ["auto"] + Languages.all.map(\.code)
        guard codes.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.sourceLanguage = codes[sender.indexOfSelectedItem] }
    }

    @objc private func pickPrimaryLanguage(_ sender: NSPopUpButton) {
        let all = Languages.all
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.primaryLanguage = all[sender.indexOfSelectedItem].code }
    }

    @objc private func pickSecondaryLanguage(_ sender: NSPopUpButton) {
        let all = Languages.all
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.secondaryLanguage = all[sender.indexOfSelectedItem].code }
    }

    @objc private func toggleAutoSwitchLanguage(_ sender: NSButton) {
        change { $0.autoSwitchLanguage = sender.state == .on }
    }

    @objc private func pickMode(_ sender: NSPopUpButton) {
        let all = TranslateMode.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.mode = all[sender.indexOfSelectedItem].rawValue }
    }

    @objc private func timeoutChanged(_ sender: NSSlider) {
        change { $0.timeoutSeconds = sender.doubleValue }
    }
}

// MARK: - 词典

final class DictionaryPane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        let (toggle, _) = PrefsKit.toggleRow(
            "选中的是单词或词组时查词典",
            isOn: draft.dictionaryEnabled,
            note: "额外问一次模型要结构化数据，显示音标、词性词义、动词形式和词组搭配。音标由模型给出，小模型可能标错，不想要就关掉。",
            target: self, action: #selector(toggleEnabled(_:)))
        stack.addArrangedSubview(toggle)

        let words = NSPopUpButton(frame: .zero, pullsDown: false)
        words.addItems(withTitles: ["1 个词", "2 个词", "3 个词", "4 个词", "5 个词", "6 个词"])
        words.selectItem(at: max(0, min(5, draft.dictionaryMaxWords - 1)))
        words.target = self
        words.action = #selector(pickWords(_:))
        stack.addArrangedSubview(PrefsKit.row("最多算作词组的长度", words,
                                              note: "超过这个长度就当成句子，只做翻译，不发词典请求。"))

        let note = NSTextField(wrappingLabelWithString: "词典请求和翻译请求并行发，不会互相等。解析失败会安静地退回普通译文排版，不会显示半截词典。")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.isSelectable = false
        stack.addArrangedSubview(note)

        stack.addArrangedSubview(PrefsKit.sectionTitle("离线词典 (ECDict)", note: "支持兼容 Bob 简明英汉词典的 ecdict.db SQLite 数据库，离线毫秒级查词，无需网络与 API Key。"))

        let isReady = ECDictService.isAvailable
        let dbStatus = isReady ? "状态：已就绪 (ecdict.db)" : "状态：未检测到数据库文件 (ecdict.db)"
        let statusLabel = NSTextField(labelWithString: dbStatus)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = isReady ? .systemGreen : .secondaryLabelColor

        let importBtn = NSButton(title: "导入词典…", target: self, action: #selector(importECDict))
        importBtn.bezelStyle = .rounded
        importBtn.controlSize = .small

        let revealBtn = NSButton(title: "打开词典文件夹", target: self, action: #selector(revealECDictFolder))
        revealBtn.bezelStyle = .rounded
        revealBtn.controlSize = .small

        let row = NSStackView(views: [statusLabel, NSView(), importBtn, revealBtn])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        stack.addArrangedSubview(PrefsKit.row("本地词库", row))
    }

    @objc private func toggleEnabled(_ sender: NSButton) { change { $0.dictionaryEnabled = (sender.state == .on) } }
    @objc private func pickWords(_ sender: NSPopUpButton) { change { $0.dictionaryMaxWords = sender.indexOfSelectedItem + 1 } }

    @objc private func importECDict() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let dest = ECDictService.dbURL
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                HUD.show("词典导入成功")
                self?.owner.mutate({ _ in }, rebuild: true)
            } catch {
                HUD.show("导入失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func revealECDictFolder() {
        let dir = ECDictService.dbURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([ECDictService.dbURL])
    }
}

// MARK: - 快捷键

final class HotkeysPane: PrefsPane {
    /// 一个快捷键录入行。冲突检查统一走 draft.conflictLabel，
    /// 免得像之前那样每加一个功能就要在八个闭包里各补一次判断。
    private func recorderRow(_ label: String, _ current: String, _ note: String?,
                             _ keyPath: WritableKeyPath<PrefsDraft, String>) -> NSView {
        let recorder = HotkeyRecorder(combo: current)
        recorder.onChange = { [weak self] value in
            guard let self else { return }
            var copy = self.draft
            copy[keyPath: keyPath] = value
            self.change { $0[keyPath: keyPath] = value }
        }
        recorder.isConflict = { [weak self] value in
            guard let self else { return false }
            return self.draft.conflictLabel(for: value, ignoring: label) != nil
        }
        return PrefsKit.row(label, recorder, note: note)
    }

    @objc private func toggleToolbar(_ sender: NSButton) {
        change { $0.showSelectionToolbar = (sender.state == .on) }
        SelectionAutoMonitor.shared.syncWithSettings()
    }

    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("全局快捷键", note: "点击输入框，然后按下新的组合键。esc 取消录入。"))

        let translateRecorder = HotkeyRecorder(combo: draft.hotkey)
        translateRecorder.onChange = { [weak self] value in
            self?.change { $0.hotkey = value }
        }
        translateRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            let d = self.draft
            return value == d.silentHotkey || value == d.inputHotkey || value == d.screenshotHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("划词翻译", translateRecorder,
                                              note: "在任意 App 里选中文字后按它，卡片在光标旁弹出"))

        let silentRecorder = HotkeyRecorder(combo: draft.silentHotkey)
        silentRecorder.onChange = { [weak self] value in
            self?.change { $0.silentHotkey = value }
        }
        silentRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            let d = self.draft
            return value == d.hotkey || value == d.inputHotkey || value == d.screenshotHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("静默翻译并复制", silentRecorder,
                                              note: "不弹卡片，译文直接进剪贴板，只在屏幕下方闪一个提示"))

        let inputRecorder = HotkeyRecorder(combo: draft.inputHotkey)
        inputRecorder.onChange = { [weak self] value in
            self?.change { $0.inputHotkey = value }
        }
        inputRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            return value == self.draft.hotkey || value == self.draft.silentHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("输入翻译", inputRecorder,
                                              note: "打开一个输入框，自己打一段字翻，不用先选中文字"))

        let shotRecorder = HotkeyRecorder(combo: draft.screenshotHotkey)
        shotRecorder.onChange = { [weak self] value in
            self?.change { $0.screenshotHotkey = value }
        }
        shotRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            let d = self.draft
            return value == d.hotkey || value == d.silentHotkey || value == d.inputHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("截图翻译", shotRecorder,
            note: "框选屏幕一块区域，识别其中的文字再翻译。要「屏幕录制」权限。"))

        let dictRecorder = HotkeyRecorder(combo: draft.dictionaryHotkey)
        dictRecorder.onChange = { [weak self] value in
            self?.change { $0.dictionaryHotkey = value }
        }
        dictRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            let d = self.draft
            return value == d.hotkey || value == d.silentHotkey
                || value == d.inputHotkey || value == d.screenshotHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("词典", dictRecorder,
            note: "打开词典窗口查词，看音标、词形、例句和同义反义"))

        let clipRecorder = HotkeyRecorder(combo: draft.clipboardHotkey)
        clipRecorder.onChange = { [weak self] value in self?.change { $0.clipboardHotkey = value } }
        clipRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            let d = self.draft
            return value == d.hotkey || value == d.silentHotkey || value == d.inputHotkey
                || value == d.screenshotHotkey || value == d.dictionaryHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("剪贴板翻译", clipRecorder,
            note: "把剪贴板里的文字直接翻出来，不用先选中"))

        let speakRecorder = HotkeyRecorder(combo: draft.speakHotkey)
        speakRecorder.onChange = { [weak self] value in self?.change { $0.speakHotkey = value } }
        speakRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            let d = self.draft
            return value == d.hotkey || value == d.silentHotkey || value == d.inputHotkey
                || value == d.screenshotHotkey || value == d.dictionaryHotkey
                || value == d.clipboardHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("朗读", speakRecorder,
            note: "念出上一次的译文；还没有译文就念原文"))

        let iconsRecorder = HotkeyRecorder(combo: draft.toggleIconsHotkey)
        iconsRecorder.onChange = { [weak self] value in self?.change { $0.toggleIconsHotkey = value } }
        iconsRecorder.isConflict = { [weak self] value in
            guard let self else { return false }
            let d = self.draft
            return value == d.hotkey || value == d.silentHotkey || value == d.inputHotkey
                || value == d.screenshotHotkey || value == d.dictionaryHotkey
                || value == d.clipboardHotkey || value == d.speakHotkey
        }
        stack.addArrangedSubview(PrefsKit.row("显示/隐藏菜单栏图标", iconsRecorder,
            note: "菜单栏被刘海挡住时按一下就藏起来，再按一下回来"))

        let (toolbar, _) = PrefsKit.toggleRow(
            "选中文字浮出小工具栏",
            isOn: draft.showSelectionToolbar,
            note: "选中后冒出一排小图标（翻译/复制/朗读/搜索），点了才动手。开了这个就不会再自动翻译。",
            target: self, action: #selector(toggleToolbar(_:)))
        stack.addArrangedSubview(toolbar)

        stack.addArrangedSubview(recorderRow("静默截图 OCR", draft.silentScreenshotOcrHotkey,
                                             "截取屏幕直接复制识别文字到剪贴板，不弹窗。", \.silentScreenshotOcrHotkey))
        stack.addArrangedSubview(recorderRow("访达选图 OCR", draft.finderImageOcrHotkey,
                                             "在访达选中图片后按下，直接识别图片里的文字和二维码。", \.finderImageOcrHotkey))
        stack.addArrangedSubview(recorderRow("静默划词替换", draft.silentReplaceHotkey,
                                             "选中的几个字直接换成译文，不弹窗口。", \.silentReplaceHotkey))
        stack.addArrangedSubview(recorderRow("静默输入框替换", draft.inputBoxReplaceHotkey,
                                             "整个输入框换成译文，适合打完一段直接翻。", \.inputBoxReplaceHotkey))

        let (autoSel, _) = PrefsKit.toggleRow(
            "选中文字就自动翻译",
            isOn: draft.autoTranslateSelection,
            note: "不用按快捷键。会自动忽略太短的选中，同一段文字 8 秒内不重复翻；默认关，因为误触发会白花钱。",
            target: self, action: #selector(toggleAutoSelect(_:)))
        stack.addArrangedSubview(autoSel)

        let (doubleOption, _) = PrefsKit.toggleRow(
            "双击 Option 键划词翻译",
            isOn: draft.doubleOptionTranslate,
            note: "连按两下左或右 Option 就翻译当前选区，不用记组合键。要辅助功能权限才能监听到全局按键。",
            target: self, action: #selector(toggleDoubleOption(_:)))
        stack.addArrangedSubview(doubleOption)
    }

    @objc private func toggleAutoSelect(_ sender: NSButton) {
        change { $0.autoTranslateSelection = (sender.state == .on) }
    }

    @objc private func toggleDoubleOption(_ sender: NSButton) { change { $0.doubleOptionTranslate = (sender.state == .on) } }
}

// MARK: - 外观与行为

final class AppearancePane: PrefsPane {

    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("卡片外观"))

        let appearances = ["跟随系统", "浅色", "深色"]
        let popup = PrefsKit.popup(appearances, selected: ["system", "light", "dark", ].firstIndex(of: draft.appearance) ?? 0)
        popup.target = self
        popup.action = #selector(pickAppearance(_:))
        stack.addArrangedSubview(PrefsKit.row("主题", popup, note: "切换立刻生效，不用等下次翻译"))

        let uiLangs = I18n.Language.allCases
        let langPopup = PrefsKit.popup(uiLangs.map(\.title),
                                       selected: uiLangs.firstIndex { $0.rawValue == draft.uiLanguage } ?? 0)
        langPopup.target = self
        langPopup.action = #selector(pickUILanguage(_:))
        stack.addArrangedSubview(PrefsKit.row("界面语言", langPopup, note: "支持简体中文、繁體中文与英文"))

        let fontSlider = NSSlider(value: draft.fontSize, minValue: 11, maxValue: 24, target: self, action: #selector(fontChanged(_:)))
        fontSlider.isContinuous = false
        let fontValue = NSTextField(labelWithString: "\(Int(draft.fontSize)) pt")
        fontValue.font = NSFont.systemFont(ofSize: 11)
        let row = NSStackView(views: [fontSlider, fontValue])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        stack.addArrangedSubview(PrefsKit.row("正文字号", row))

        let md = PrefsKit.toggleRow("译文按 Markdown 渲染", isOn: draft.renderMarkdown,
                                    note: "关掉就纯文本显示。标题、列表、表格、行内代码都不解析。",
                                    target: self, action: #selector(toggleMarkdown(_:))).0
        stack.addArrangedSubview(md)

        let think = PrefsKit.toggleRow("显示推理模型的思考过程", isOn: draft.showThink,
                                       note: "DeepSeek R1 这类模型返回的 reasoning 内容单独一块显示。",
                                       target: self, action: #selector(toggleThink(_:))).0
        stack.addArrangedSubview(think)

        let (review, _) = PrefsKit.toggleRow(
            "截图后先确认识别文字",
            isOn: draft.ocrReviewBeforeTranslate,
            note: "识别难免有错字，先给一个可编辑的原文框，确认或改完再翻。关掉就是识别完直接翻。",
            target: self, action: #selector(toggleOCRReview(_:)))
        stack.addArrangedSubview(review)

        stack.addArrangedSubview(PrefsKit.sectionTitle("网络",
            note: "需要梯子才能连上模型时用。本机地址（Magpie、本地 Ollama）永远直连，不走代理。"))

        // 代理会打死 Apple 系统翻译——Bob 官方 FAQ 明确说分流规则没用
        let proxyWarn = NSTextField(wrappingLabelWithString: "注意：开了代理后，Apple 系统翻译可能报「操作不被允许」。这跟本 App 的代理设置无关，是系统级翻译被网络环境干扰；分流规则无效，需要让 Apple 的翻译域名完全不走代理。遇到这种错，按提示里的话说给你听即可。")
        proxyWarn.font = NSFont.systemFont(ofSize: 11)
        proxyWarn.textColor = .systemOrange
        stack.addArrangedSubview(proxyWarn)

        let (proxyOn, _) = PrefsKit.toggleRow("使用代理", isOn: draft.proxyEnabled,
                                              note: nil, target: self, action: #selector(toggleProxy(_:)))
        stack.addArrangedSubview(proxyOn)

        let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        typePopup.controlSize = .small
        typePopup.addItems(withTitles: ["HTTP", "SOCKS5"])
        typePopup.selectItem(at: draft.proxyType.lowercased() == "socks5" ? 1 : 0)
        typePopup.target = self
        typePopup.action = #selector(pickProxyType(_:))
        stack.addArrangedSubview(PrefsKit.row("类型", typePopup))

        let hostField = PrefsKit.textControl(draft.proxyHost, placeholder: "127.0.0.1") as! NSTextField
        hostField.target = self
        hostField.action = #selector(commitProxyHost(_:))
        stack.addArrangedSubview(PrefsKit.row("服务器", hostField))

        let portField = PrefsKit.textControl(String(draft.proxyPort), placeholder: "7890") as! NSTextField
        portField.target = self
        portField.action = #selector(commitProxyPort(_:))
        stack.addArrangedSubview(PrefsKit.row("端口", portField))

        let userField = PrefsKit.textControl(draft.proxyUsername, placeholder: "用户名（可选）") as! NSTextField
        userField.target = self
        userField.action = #selector(commitProxyUser(_:))
        stack.addArrangedSubview(PrefsKit.row("认证", userField))

        let passField = PrefsKit.textControl(SecretStore.shared.apiKey(for: "proxy-password"),
                                             placeholder: "密码（可选）", secure: true) as! NSTextField
        passField.target = self
        passField.action = #selector(commitProxyPassword(_:))
        stack.addArrangedSubview(PrefsKit.row("密码", passField))

        let status = NSTextField(labelWithString: NetworkSession.describe())
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status)

        stack.addArrangedSubview(PrefsKit.sectionTitle("文本预处理", note: "在发送翻译前智能清洗原文。"))

        let pdfToggle = PrefsKit.toggleRow("合并 PDF 硬换行与断词连字符", isOn: draft.mergePDFNewlines,
                                           note: "去除 trans- 等断字连字符，并将段内硬换行拼为自然空格（中文直接相连）。",
                                           target: self, action: #selector(toggleMergePDF(_:))).0
        stack.addArrangedSubview(pdfToggle)

        let codeToggle = PrefsKit.toggleRow("代码标识符拆词 (CamelCase / snake_case)", isOn: draft.splitCodeIdentifiers,
                                            note: "选中 getUserProfile 或 parse_json 时自动拆解为自然英语单词再翻译。",
                                            target: self, action: #selector(toggleSplitCode(_:))).0
        stack.addArrangedSubview(codeToggle)

        stack.addArrangedSubview(PrefsKit.sectionTitle("取词方式", note: "先读焦点控件的选中文字，读不到再往下退。"))
        let modes = ["自动（先读选区，失败退回模拟复制）", "只读选区（不动剪贴板）", "只用剪贴板（模拟 ⌘C）"]
        let modePopup = PrefsKit.popup(modes, selected: ["auto", "ax", "clipboard", ].firstIndex(of: draft.selectionMode) ?? 0)
        modePopup.target = self
        modePopup.action = #selector(pickSelection(_:))
        stack.addArrangedSubview(PrefsKit.row("取词", modePopup,
            note: "中间那条不会改写你的剪贴板；有些自绘界面的软件只有剪贴板能拿到内容。"))

        let autoCopy = PrefsKit.toggleRow("翻译完成后自动复制第一个结果", isOn: draft.autoCopy,
                                          note: nil, target: self, action: #selector(toggleAutoCopy(_:))).0
        stack.addArrangedSubview(autoCopy)

        let hint = PrefsKit.toggleRow("复制成功后闪一下提示", isOn: draft.copyHint,
                                      note: nil, target: self, action: #selector(toggleCopyHint(_:))).0
        stack.addArrangedSubview(hint)

        let pin = PrefsKit.toggleRow("新弹出的卡片默认钉住", isOn: draft.pinByDefault,
                                     note: "钉住后失去焦点不会自动收起，可以一边看一边切到别的窗口。",
                                     target: self, action: #selector(togglePin(_:))).0
        stack.addArrangedSubview(pin)

        let top = PrefsKit.toggleRow("跨应用强力置顶", isOn: draft.alwaysOnTop,
                                     note: "提升窗口层级至状态栏级别，避免被部分自置顶或全屏应用遮挡。",
                                     target: self, action: #selector(toggleAlwaysOnTop(_:))).0
        stack.addArrangedSubview(top)

        let margin = PrefsKit.toggleRow("贴近屏幕边缘时不留空白边距", isOn: draft.noScreenMargin,
                                        note: "去除卡片与屏幕边界之间 12pt 的空白边距。",
                                        target: self, action: #selector(toggleNoScreenMargin(_:))).0
        stack.addArrangedSubview(margin)

        let posOptions: [(mode: String, title: String)] = [
            ("mouse", "跟随鼠标位置"),
            ("center", "屏幕正中显示"),
            ("last", "记忆上次位置")
        ]
        let posPopup = PrefsKit.popup(posOptions.map(\.title),
                                      selected: posOptions.firstIndex(where: { $0.mode == draft.windowLocationMode }) ?? 0)
        posPopup.target = self
        posPopup.action = #selector(pickWindowLocationMode(_:))
        stack.addArrangedSubview(PrefsKit.row("窗口位置", posPopup, note: "卡片呼出时的屏幕位置策略"))

        let excludedField = PrefsKit.textControl(draft.excludedApps, placeholder: "Terminal, iTerm2") as! NSTextField
        excludedField.target = self
        excludedField.action = #selector(commitExcludedApps(_:))
        stack.addArrangedSubview(PrefsKit.row("排除应用", excludedField, note: "在这些应用中不自动弹窗（逗号分隔 App 名称或 BundleID）"))

        stack.addArrangedSubview(PrefsKit.sectionTitle("朗读", note: "用系统语音合成，不联网、不要权限。"))

        let voices = SpeechService.availableVoices
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("en") }
        let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        voicePopup.controlSize = .small
        voicePopup.addItem(withTitle: "自动（按语言挑）")
        for voice in voices.prefix(24) {
            voicePopup.addItem(withTitle: "\(voice.name)  \(voice.language)")
        }
        if let index = voices.prefix(24).firstIndex(where: { $0.id == draft.speechVoiceID }) {
            voicePopup.selectItem(at: index + 1)
        } else {
            voicePopup.selectItem(at: 0)
        }
        voicePopup.target = self
        voicePopup.action = #selector(pickVoice(_:))
        stack.addArrangedSubview(PrefsKit.row("音色", voicePopup,
            note: "中文文本会自动挑中文音色，用英文音色念中文会听不懂"))

        let ttsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ttsPopup.controlSize = .small
        ttsPopup.addItems(withTitles: TtsEngine.allCases.map(\.title))
        ttsPopup.selectItem(at: TtsEngine.allCases.firstIndex { $0.rawValue == draft.ttsEngine } ?? 0)
        ttsPopup.target = self
        ttsPopup.action = #selector(pickTtsEngine(_:))
        stack.addArrangedSubview(PrefsKit.row("引擎", ttsPopup,
            note: "系统语音离线免 key；云端音色更好听，失败会自动退回系统语音。"))

        let currentTts = TtsEngine(rawValue: draft.ttsEngine) ?? .system
        if currentTts.needsKey {
            let ttsKey = PrefsKit.textControl(SecretStore.shared.apiKey(for: currentTts.keyAccount),
                                              placeholder: currentTts.keyHint, secure: true) as! NSTextField
            ttsKey.target = self
            ttsKey.action = #selector(commitTtsKey(_:))
            stack.addArrangedSubview(PrefsKit.row("语音密钥", ttsKey))
        }

        let rateSlider = NSSlider(value: draft.speechRate, minValue: 0.5, maxValue: 1.8,
                                  target: self, action: #selector(rateChanged(_:)))
        rateSlider.isContinuous = false
        let rateValue = NSTextField(labelWithString: String(format: "%.1f×", draft.speechRate))
        rateValue.font = NSFont.systemFont(ofSize: 11)
        let rateRow = NSStackView(views: [rateSlider, rateValue])
        rateRow.orientation = .horizontal
        rateRow.spacing = 8
        rateRow.translatesAutoresizingMaskIntoConstraints = false
        rateRow.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        stack.addArrangedSubview(PrefsKit.row("语速", rateRow))

        let (autoSpeak, _) = PrefsKit.toggleRow("查词或翻译完成后自动朗读发音", isOn: draft.autoSpeakWhenDone,
                                                note: "无需每次手动点击喇叭图标，查词完成自动播放发音。",
                                                target: self, action: #selector(toggleAutoSpeak(_:)))
        stack.addArrangedSubview(autoSpeak)

        let (menuBar, _) = PrefsKit.toggleRow(
            "在菜单栏显示图标",
            isOn: draft.showMenuBarIcon,
            note: "菜单栏图标被刘海挡住时可以先关掉这个，从 Dock 或快捷键进设置。",
            target: self, action: #selector(toggleMenuBarIcon(_:)))
        stack.addArrangedSubview(menuBar)

        let (dockIcon, _) = PrefsKit.toggleRow(
            "在 Dock 显示图标",
            isOn: draft.showDockIcon,
            note: "关掉后只在菜单栏待着，浏览器切 App 时看不到它。两个都关是关不掉的——会至少给你留一个入口。",
            target: self, action: #selector(toggleDockIcon(_:)))
        stack.addArrangedSubview(dockIcon)

        loginStatus = NSTextField(labelWithString: "")
        let login = PrefsKit.toggleRow("开机自动启动", isOn: draft.launchAtLogin,
                                       note: nil, target: self, action: #selector(toggleLogin(_:))).0
        stack.addArrangedSubview(login)
        if let loginStatus {
            loginStatus.font = NSFont.systemFont(ofSize: 11)
            loginStatus.textColor = .systemRed
            stack.addArrangedSubview(loginStatus)
        }
    }

    private var loginStatus: NSTextField?

    @objc private func pickTtsEngine(_ sender: NSPopUpButton) {
        guard TtsEngine.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.ttsEngine = TtsEngine.allCases[sender.indexOfSelectedItem].rawValue }
    }

    @objc private func commitTtsKey(_ sender: NSTextField) {
        let engine = TtsEngine(rawValue: draft.ttsEngine) ?? .system
        SecretStore.shared.setAPIKey(sender.stringValue, account: engine.keyAccount)
    }

    @objc private func pickVoice(_ sender: NSPopUpButton) {
        let voices = SpeechService.availableVoices
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("en") }
        let index = sender.indexOfSelectedItem
        if index <= 0 {
            change { $0.speechVoiceID = "" }
        } else if voices.indices.contains(index - 1) {
            let voice = voices[index - 1]
            change { $0.speechVoiceID = voice.id }
            // 选完立刻念一句，让人听到是什么声音
            SpeechService.shared.speak("你好，这是当前音色")
        }
    }

    @objc private func rateChanged(_ sender: NSSlider) {
        change { $0.speechRate = sender.doubleValue }
    }

    @objc private func toggleOCRReview(_ sender: NSButton) {
        change { $0.ocrReviewBeforeTranslate = (sender.state == .on) }
    }

    @objc private func toggleProxy(_ sender: NSButton) {
        change { $0.proxyEnabled = (sender.state == .on) }
        NetworkSession.invalidate()
    }

    @objc private func pickProxyType(_ sender: NSPopUpButton) {
        change { $0.proxyType = sender.indexOfSelectedItem == 1 ? "socks5" : "http" }
        NetworkSession.invalidate()
    }

    @objc private func commitProxyHost(_ sender: NSTextField) {
        change({ $0.proxyHost = sender.stringValue }, rebuild: false)
        NetworkSession.invalidate()
    }

    @objc private func commitProxyPort(_ sender: NSTextField) {
        change({ $0.proxyPort = Int(sender.stringValue) ?? 7890 }, rebuild: false)
        NetworkSession.invalidate()
    }

    @objc private func commitProxyUser(_ sender: NSTextField) {
        change({ $0.proxyUsername = sender.stringValue }, rebuild: false)
        NetworkSession.invalidate()
    }

    @objc private func commitProxyPassword(_ sender: NSTextField) {
        SecretStore.shared.setAPIKey(sender.stringValue, account: "proxy-password")
        NetworkSession.invalidate()
    }

    @objc private func pickAppearance(_ sender: NSPopUpButton) {
        let values = ["system", "light", "dark"]
        guard values.indices.contains(sender.indexOfSelectedItem) else { return }
        let value = values[sender.indexOfSelectedItem]
        change { $0.appearance = value }
        AppearanceApplier.apply(value)   // 立刻可见，不用等保存
    }

    @objc private func pickUILanguage(_ sender: NSPopUpButton) {
        let langs = I18n.Language.allCases
        guard langs.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.uiLanguage = langs[sender.indexOfSelectedItem].rawValue }
    }

    @objc private func fontChanged(_ sender: NSSlider) { change { $0.fontSize = sender.doubleValue } }
    @objc private func toggleMarkdown(_ sender: NSButton) { change { $0.renderMarkdown = sender.state == .on } }
    @objc private func toggleThink(_ sender: NSButton) { change { $0.showThink = sender.state == .on } }
    @objc private func toggleAutoCopy(_ sender: NSButton) { change { $0.autoCopy = sender.state == .on } }
    @objc private func toggleCopyHint(_ sender: NSButton) { change { $0.copyHint = sender.state == .on } }
    @objc private func togglePin(_ sender: NSButton) { change { $0.pinByDefault = sender.state == .on } }
    @objc private func toggleAlwaysOnTop(_ sender: NSButton) { change { $0.alwaysOnTop = sender.state == .on } }
    @objc private func toggleNoScreenMargin(_ sender: NSButton) { change { $0.noScreenMargin = sender.state == .on } }
    @objc private func toggleMergePDF(_ sender: NSButton) { change { $0.mergePDFNewlines = sender.state == .on } }
    @objc private func toggleSplitCode(_ sender: NSButton) { change { $0.splitCodeIdentifiers = sender.state == .on } }
    @objc private func toggleAutoSpeak(_ sender: NSButton) { change { $0.autoSpeakWhenDone = sender.state == .on } }

    @objc private func pickWindowLocationMode(_ sender: NSPopUpButton) {
        let modes = ["mouse", "center", "last"]
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.windowLocationMode = modes[sender.indexOfSelectedItem] }
    }

    @objc private func commitExcludedApps(_ sender: NSTextField) {
        change({ $0.excludedApps = sender.stringValue }, rebuild: false)
    }

    @objc private func pickSelection(_ sender: NSPopUpButton) {
        let values = ["auto", "ax", "clipboard"]
        guard values.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.selectionMode = values[sender.indexOfSelectedItem] }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        let wanted = sender.state == .on
        if let problem = LaunchAtLogin.set(wanted) {
            NSSound.beep()
            loginStatus?.stringValue = "开机自启设置失败：\(problem)"
            change { $0.launchAtLogin = LaunchAtLogin.isEnabled }
            return
        }
        change { $0.launchAtLogin = wanted }
    }
}

// MARK: - 权限与诊断

final class PermissionsPane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        let snapshot = PermissionState.current()

        stack.addArrangedSubview(PrefsKit.sectionTitle("系统权限", note: "读不到选中的文字，九成是这里没开。"))

        // 辅助功能
        let a11y = PrefsKit.statusLine(symbol: snapshot.accessibility ? "checkmark.circle.fill" : "xmark.circle.fill",
                                       color: snapshot.accessibility ? .systemGreen : .systemRed,
                                       text: snapshot.accessibility
                                        ? "辅助功能已授权，可以读取任意 App 里选中的文字"
                                        : "还没有辅助功能权限 —— 现在划词翻译拿不到内容")
        stack.addArrangedSubview(a11y)

        let grant = NSButton(title: snapshot.accessibility ? "打开系统设置确认" : "去打开系统设置",
                             target: self, action: #selector(openSettings))
        grant.bezelStyle = .rounded
        grant.controlSize = .small
        let request = NSButton(title: "重新申请授权", target: self, action: #selector(reRequest))
        request.bezelStyle = .rounded
        request.controlSize = .small
        let recheck = NSButton(title: "重新检测", target: self, action: #selector(recheck))
        recheck.bezelStyle = .rounded
        recheck.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([grant, request, recheck], trailing: false))

        if snapshot.accessibility {
            stack.addArrangedSubview(hint("刚授权过但没生效？把列表里的 LocalTranslate 关一下再开，然后重启本 App。"))
        } else {
            stack.addArrangedSubview(hint("授权弹窗如果被系统吃掉看不到了，先确认这个 App 是从「应用程序」文件夹启动的，不是从临时目录里跑的副本。"))
        }

        // Option 快捷键风险（macOS 15/26 系统 bug）
        if let warning = SystemHotkeyRisk.optionWarning {
            stack.addArrangedSubview(PrefsKit.sectionTitle("快捷键稳定性",
                note: "macOS 15/26 上「Option + 字母」快捷键会偶发失效，这是系统 bug。"))
            stack.addArrangedSubview(hint(warning))
        }

        // 屏幕录制（截图翻译要用）
        stack.addArrangedSubview(PrefsKit.sectionTitle("屏幕录制", note: "截图翻译要抓画面，这是另一个授权，和辅助功能分开。会通过 ScreenCaptureKit 实测是否真正可截屏。"))
        let slot = NSStackView()
        slot.orientation = .vertical
        slot.alignment = .leading
        screenStatusSlot = slot
        stack.addArrangedSubview(slot)

        let shotOK = ScreenOCR.hasPermission
        updateScreenStatusSlot(
            symbol: shotOK ? "clock.arrow.circlepath" : "xmark.circle.fill",
            color: shotOK ? .secondaryLabelColor : .systemRed,
            text: shotOK ? "预检通过，正在实测 ScreenCaptureKit 截图能力…" : "未授权（预检或窗口标题读取失败），请去系统设置授权后重启"
        )
        if !CommandLine.arguments.contains("--selftest") {
            refreshScreenStatusAsync()
        }

        let shotBtn = NSButton(title: shotOK ? "打开系统设置确认" : "去授权屏幕录制",
                               target: self, action: #selector(openScreenRecording))
        shotBtn.bezelStyle = .rounded
        shotBtn.controlSize = .small

        let testShotBtn = NSButton(title: "实测截图权限", target: self, action: #selector(probeScreenRecordingNow))
        testShotBtn.bezelStyle = .rounded
        testShotBtn.controlSize = .small

        stack.addArrangedSubview(PrefsKit.buttonRow([shotBtn, testShotBtn], trailing: false))

        // Apple 翻译语言包（离线引擎，缺包就翻不了对应语向）
        stack.addArrangedSubview(PrefsKit.sectionTitle("Apple 翻译语言包",
            note: "苹果离线翻译要按语种下载语言包。缺哪个语种，那个语向就会自动跳过苹果、改用谷歌等在线引擎。"))
        let langSlot = NSStackView()
        langSlot.orientation = .vertical
        langSlot.alignment = .leading
        appleLangSlot = langSlot
        stack.addArrangedSubview(langSlot)
        updateAppleLangSlot(symbol: "clock.arrow.circlepath", color: .secondaryLabelColor,
                            text: "正在检测已安装的语言包…")
        if !CommandLine.arguments.contains("--selftest") {
            refreshAppleLanguagePacks()
        }

        let openLangBtn = NSButton(title: "打开系统设置下载语言包…",
                                   target: self, action: #selector(openAppleLanguageSettings))
        openLangBtn.bezelStyle = .rounded
        openLangBtn.controlSize = .small
        let recheckLangBtn = NSButton(title: "重新检测", target: self, action: #selector(recheckAppleLanguagePacks))
        recheckLangBtn.bezelStyle = .rounded
        recheckLangBtn.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([openLangBtn, recheckLangBtn], trailing: false))

        // OCR 引擎
        stack.addArrangedSubview(PrefsKit.sectionTitle("文字识别引擎",
            note: "系统 Vision 离线免 key；云端引擎在手写体或复杂排版认不出时更稳。"))
        let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        enginePopup.controlSize = .small
        enginePopup.addItems(withTitles: OcrEngine.allCases.map(\.title))
        enginePopup.selectItem(at: OcrEngine.allCases.firstIndex { $0.rawValue == draft.ocrEngine } ?? 0)
        enginePopup.target = self
        enginePopup.action = #selector(pickOcrEngine(_:))
        stack.addArrangedSubview(PrefsKit.row("引擎", enginePopup))

        let currentEngine = OcrEngine(rawValue: draft.ocrEngine) ?? .system
        if currentEngine.needsKey {
            let keyField = PrefsKit.textControl(SecretStore.shared.apiKey(for: currentEngine.keyAccount),
                                                placeholder: currentEngine.keyHint, secure: true) as! NSTextField
            keyField.target = self
            keyField.action = #selector(commitOcrKey(_:))
            stack.addArrangedSubview(PrefsKit.row("密钥", keyField,
                note: "按引擎分开存钥匙串。填错会在这张截图时直接报错，不会静默失败。"))
        }

        // 签名
        stack.addArrangedSubview(PrefsKit.sectionTitle("签名身份",
            note: "辅助功能授权认的是签名身份。ad-hoc 每次重新编译都会变，等于每次都要重勾一遍。"))
        stack.addArrangedSubview(PrefsKit.statusLine(
            symbol: snapshot.signature.contains("固定证书") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            color: snapshot.signature.contains("固定证书") ? .systemGreen : .systemOrange,
            text: snapshot.signature))
        let fix = NSButton(title: "一键修复签名身份", target: self, action: #selector(runSetupSigning(_:)))
        fix.bezelStyle = .rounded
        fix.controlSize = .small

        let resetTcc = NSButton(title: "重置异常 TCC 权限", target: self, action: #selector(resetTCCPermissions))
        resetTcc.bezelStyle = .rounded
        resetTcc.controlSize = .small
        resetTcc.toolTip = "当已勾选辅助功能或屏幕录制却依然报错时，清理 macOS 卡死的授权缓存以便重新勾选"

        stack.addArrangedSubview(PrefsKit.buttonRow([fix, resetTcc], trailing: false))

        // 钥匙串
        stack.addArrangedSubview(PrefsKit.sectionTitle("钥匙串", note: "API Key 优先存这里；不可用时自动退回本地文件，功能不受影响。"))
        stack.addArrangedSubview(PrefsKit.statusLine(
            symbol: snapshot.keychainUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            color: snapshot.keychainUsable ? .systemGreen : .systemOrange,
            text: snapshot.keychainDetail))

        // 快捷键实际注册情况
        stack.addArrangedSubview(PrefsKit.sectionTitle("已注册的快捷键"))
        if snapshot.registeredHotkeys.isEmpty {
            stack.addArrangedSubview(hint("一个都没注册上，检查是不是和其它 App 撞了"))
        } else {
            for line in snapshot.registeredHotkeys { stack.addArrangedSubview(hint(line)) }
        }

        // 快捷键撞系统的情况
        let conflicts = HotKeyConflicts.currentWarnings([
            ("划词", Config.shared.hotkey), ("静默", Config.shared.silentHotkey),
            ("输入", Config.shared.inputHotkey), ("截图", Config.shared.screenshotHotkey),
            ("词典", Config.shared.dictionaryHotkey), ("剪贴板", Config.shared.clipboardHotkey),
            ("朗读", Config.shared.speakHotkey), ("图标", Config.shared.toggleIconsHotkey),
        ])
        if !conflicts.isEmpty {
            stack.addArrangedSubview(PrefsKit.sectionTitle("快捷键冲突",
                note: "macOS 没有公开接口能查别的 App 占了哪些组合，这里只比对系统保留键。"))
            for line in conflicts { stack.addArrangedSubview(hint(line)) }
        }

        // 自检
        stack.addArrangedSubview(PrefsKit.sectionTitle("自检", note: "不改动任何配置，把接口、取词、渲染各条链路跑一遍。"))
        let run = NSButton(title: "跑一遍模块自检", target: self, action: #selector(runSelfTest(_:)))
        run.bezelStyle = .rounded
        run.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([run], trailing: false))
        output = NSTextField(wrappingLabelWithString: "")
        output?.font = NSFont.systemFont(ofSize: 11)
        output?.textColor = .secondaryLabelColor
        output?.isSelectable = true
        if let output { stack.addArrangedSubview(output) }
    }

    private var output: NSTextField?
    private weak var screenStatusSlot: NSStackView?
    private weak var appleLangSlot: NSStackView?

    private func updateAppleLangSlot(symbol: String, color: NSColor, text: String) {
        guard let slot = appleLangSlot else { return }
        slot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slot.addArrangedSubview(PrefsKit.statusLine(symbol: symbol, color: color, text: text))
    }

    private func refreshAppleLanguagePacks() {
        Task { [weak self] in
            guard #available(macOS 15.0, *) else {
                await MainActor.run {
                    self?.updateAppleLangSlot(symbol: "exclamationmark.triangle.fill", color: .systemOrange,
                                              text: "系统版本低于 macOS 15，用不了 Apple 离线翻译")
                }
                return
            }
            let pairs: [(String, String, String)] = [
                ("英文 → 中文", "en", "zh"), ("中文 → 英文", "zh", "en"),
                ("日文 → 中文", "ja", "zh"), ("韩文 → 中文", "ko", "zh"),
                ("法文 → 中文", "fr", "zh"), ("德文 → 中文", "de", "zh"),
                ("西班牙文 → 中文", "es", "zh"), ("俄文 → 中文", "ru", "zh"),
            ]
            var installed: [String] = []
            var missing: [String] = []
            for (label, from, to) in pairs {
                let status = await AppleTranslator.availability(targetLanguage: to, sourceLanguage: from)
                if status == .installed { installed.append(label) } else { missing.append(label) }
            }
            await MainActor.run {
                if missing.isEmpty {
                    self?.updateAppleLangSlot(symbol: "checkmark.circle.fill", color: .systemGreen,
                                              text: "全部语言包都已安装（\(installed.count) 个方向），苹果离线翻译可以全语种直接用")
                } else {
                    self?.updateAppleLangSlot(
                        symbol: "exclamationmark.triangle.fill",
                        color: .systemOrange,
                        text: "已装：\(installed.joined(separator: "、"))；缺：\(missing.joined(separator: "、"))"
                             + "。缺的语向会自动跳过苹果、改用谷歌/MyMemory，不影响使用。")
                }
            }
        }
    }

    @objc private func openAppleLanguageSettings() {
        // 语言包在「系统设置 → 通用 → 语言与地区 → 翻译语言」
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        HUD.show("在「语言与地区」里点「翻译语言」，把要用的语种加进去即可")
    }

    @objc private func recheckAppleLanguagePacks() {
        updateAppleLangSlot(symbol: "clock.arrow.circlepath", color: .secondaryLabelColor,
                            text: "正在重新检测…")
        refreshAppleLanguagePacks()
    }

    private func updateScreenStatusSlot(symbol: String, color: NSColor, text: String) {
        guard let slot = screenStatusSlot else { return }
        slot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slot.addArrangedSubview(PrefsKit.statusLine(symbol: symbol, color: color, text: text))
    }

    private func refreshScreenStatusAsync() {
        Task { [weak self] in
            let status = await ScreenOCR.probePermission(timeoutSeconds: 2.5)
            await MainActor.run {
                guard let self else { return }
                switch status {
                case .granted:
                    self.updateScreenStatusSlot(
                        symbol: "checkmark.circle.fill",
                        color: .systemGreen,
                        text: "已授权且实测截屏正常，⌘⇧S 框选即可取字翻译"
                    )
                case .preflightOnly(let reason):
                    self.updateScreenStatusSlot(
                        symbol: "exclamationmark.triangle.fill",
                        color: .systemOrange,
                        text: "授权假阳性：系统预检显示通过，但实测截屏被拒（\(reason)）。请点击下方「重置异常 TCC 权限」或重勾开关并重启！"
                    )
                case .denied(let reason):
                    self.updateScreenStatusSlot(
                        symbol: "xmark.circle.fill",
                        color: .systemRed,
                        text: "未授权（\(reason)），请先到系统设置开启屏幕录制后重启 App"
                    )
                }
            }
        }
    }

    @objc private func probeScreenRecordingNow() {
        updateScreenStatusSlot(symbol: "clock.arrow.circlepath", color: .secondaryLabelColor, text: "正在触发 ScreenCaptureKit 实测截屏…")
        refreshScreenStatusAsync()
    }

    private func hint(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        return label
    }

    @objc private func pickOcrEngine(_ sender: NSPopUpButton) {
        guard OcrEngine.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let engine = OcrEngine.allCases[sender.indexOfSelectedItem]
        change { $0.ocrEngine = engine.rawValue }
    }

    @objc private func commitOcrKey(_ sender: NSTextField) {
        let engine = OcrEngine(rawValue: draft.ocrEngine) ?? .system
        SecretStore.shared.setAPIKey(sender.stringValue, account: engine.keyAccount)
    }

    @objc private func openScreenRecording() {
        _ = ScreenOCR.requestPermission()
        ScreenOCR.openPermissionSettings()
    }

    @objc private func openSettings() { PermissionState.openAccessibilitySettings() }
    @objc private func reRequest() { PermissionState.requestAccessibility() }
    @objc private func recheck() { owner.mutate({ _ in }, rebuild: true) }

    /// 在 App 里跑模块自检，结果直接写在按钮下面，不弹框、也不把人赶去终端
    @objc private func runSelfTest(_ sender: NSButton) {
        output?.stringValue = "自检中…"
        sender.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = SelfTest.moduleReport()
            DispatchQueue.main.async { [weak self] in
                sender.isEnabled = true
                guard let self else { return }
                let failed = lines.contains { $0.hasPrefix("✗") }
                self.output?.stringValue = lines.joined(separator: "\n")
                self.output?.textColor = failed ? .systemRed : .secondaryLabelColor
            }
        }
    }

    /// 直接执行 setup_signing.sh，把它的输出贴回来
    @objc private func runSetupSigning(_ sender: NSButton) {
        output?.stringValue = "正在执行…"
        sender.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ScriptRunner.runSetupSigning()
            DispatchQueue.main.async { [weak self] in
                sender.isEnabled = true
                guard let self else { return }
                self.output?.stringValue = result.text
                self.output?.textColor = result.ok ? .secondaryLabelColor : .systemRed
            }
        }
    }

    @objc private func resetTCCPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.localtranslate.app"
        for service in ["Accessibility", "ScreenCapture"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", service, bundleID]
            try? proc.run()
            proc.waitUntilExit()
        }
        HUD.show("已重置 \(bundleID) 的辅助功能与屏幕录制授权缓存")
        owner.mutate({ _ in }, rebuild: true)
    }
}

// MARK: - 历史记录

final class HistoryPane: PrefsPane {

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [HistoryStore.Record] = []

    override func configure(_ stack: NSStackView) {
        // 先列最近记录，再谈设置——和 Bob 一样，点开这一项就能看到历史本身
        table.headerView = nil
        table.rowHeight = 52
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("historyInline"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        stack.addArrangedSubview(PrefsKit.sectionTitle("最近记录",
            note: "双击一条可以重新翻译；删除只影响本地记录。"))
        stack.addArrangedSubview(scroll)
        rows = Array(HistoryStore.allRecords().prefix(50))
        table.reloadData()

        let keep = PrefsKit.toggleRow("保留翻译历史", isOn: draft.keepHistory,
                                      note: "关掉之后不再写入新记录，已有记录保留。",
                                      target: self, action: #selector(toggleKeep(_:))).0
        stack.addArrangedSubview(keep)

        let limit = NSPopUpButton(frame: .zero, pullsDown: false)
        limit.addItems(withTitles: ["100 条", "200 条", "500 条", "1000 条", "不限"])
        let map = [100, 200, 500, 1000, 0]
        limit.selectItem(at: map.firstIndex(of: draft.historyLimit) ?? 2)
        limit.target = self
        limit.action = #selector(pickLimit(_:))
        stack.addArrangedSubview(PrefsKit.row("最多留", limit,
            note: "存在本地 JSON 文件里，不联网，随时可以删。"))

        let openFav = NSButton(title: "打开收藏夹", target: self, action: #selector(openFavorites))
        openFav.bezelStyle = .rounded
        openFav.controlSize = .small
        stack.addArrangedSubview(PrefsKit.row("收藏夹", openFav,
            note: "翻译卡片上的星标（⌘S）会把译文存进收藏夹，支持搜索、导出 Anki/CSV/JSON。"))

        let open = NSButton(title: "打开历史窗口", target: self, action: #selector(openHistory))
        open.bezelStyle = .rounded
        open.controlSize = .small
        let reveal = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealFile))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        let clear = NSButton(title: "清空全部", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([open, reveal, clear], trailing: false))

        stack.addArrangedSubview(hint("当前 \(HistoryStore.all().count) 条，文件：\(HistoryStore.fileURL.path)"))
    }

    private func hint(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        return label
    }

    @objc private func openFavorites() { FavoriteWindow.shared.show() }

    @objc private func replaySelected() {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return }
        NotificationCenter.default.post(name: .localTranslateReplay,
                                        object: HistoryEntry(source: rows[row].source, result: rows[row].result,
                                                             mode: rows[row].mode, model: rows[row].model,
                                                             targetLanguage: rows[row].targetLanguage,
                                                             date: rows[row].date))
    }

    @objc private func toggleKeep(_ sender: NSButton) { change { $0.keepHistory = sender.state == .on } }
    @objc private func pickLimit(_ sender: NSPopUpButton) {
        let map = [100, 200, 500, 1000, 0]
        guard map.indices.contains(sender.indexOfSelectedItem) else { return }
        change { $0.historyLimit = map[sender.indexOfSelectedItem] }
    }
    @objc private func openHistory() { HistoryWindow.shared.show() }
    @objc private func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.fileURL])
    }
    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "清空所有历史记录？"
        alert.informativeText = "本地文件会被清空，撤销不了。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            HistoryStore.clear()
            owner.mutate({ _ in }, rebuild: true)
        }
    }
}

// MARK: - 导入导出

final class TransferPane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        stack.addArrangedSubview(PrefsKit.sectionTitle("配置搬家", note: "导出的 JSON 含 Base URL、模型名和服务开关。密钥默认不带，勾选后会一起导出。"))

        let includeKeys = PrefsKit.toggleRow("导出时包含 API Key", isOn: false,
                                             note: "文件是明文，只在确实要迁移到另一台机器时再开。",
                                             target: self, action: #selector(toggleIncludeKeys(_:))).0
        stack.addArrangedSubview(includeKeys)

        let export = NSButton(title: "导出配置…", target: self, action: #selector(doExport))
        export.bezelStyle = .rounded
        export.controlSize = .small
        let importButton = NSButton(title: "导入配置…", target: self, action: #selector(doImport))
        importButton.bezelStyle = .rounded
        importButton.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([export, importButton], trailing: false))

        result = NSTextField(wrappingLabelWithString: "")
        result!.font = NSFont.systemFont(ofSize: 11)
        result!.textColor = .secondaryLabelColor
        stack.addArrangedSubview(result!)
    }

    private var result: NSTextField?
    private var includeKeys = false

    @objc private func toggleIncludeKeys(_ sender: NSButton) { includeKeys = sender.state == .on }

    @objc private func doExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "localtranslate-config.json"
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try ConfigArchive.exportJSON(includeKeys: self.includeKeys).write(to: url)
                self.result?.stringValue = "已导出到 \(url.path)"
            } catch {
                self.result?.stringValue = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func doImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let data = try Data(contentsOf: url)
                try ConfigArchive.importJSON(data)
                self.result?.stringValue = "已导入，重新打开设置可看到新值"
                self.owner.mutate({ _ in }, rebuild: true)
            } catch {
                self.result?.stringValue = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 关于

final class AboutPane: PrefsPane {
    override func configure(_ stack: NSStackView) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let name = NSTextField(labelWithString: "LocalTranslate")
        name.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        let version = NSTextField(labelWithString: "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        version.font = NSFont.systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor

        let text = NSStackView(views: [name, version])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let top = NSStackView(views: [icon, text])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 16
        stack.addArrangedSubview(top)

        stack.addArrangedSubview(PrefsKit.sectionTitle("这是什么",
            note: "本地跑的划词翻译工具。界面和交互参考 Bob，翻译走 OpenAI 兼容接口，模型自己填。不联网上传除翻译请求以外的东西。"))

        let homepage = NSButton(title: "参考项目 nextai-translator", target: self, action: #selector(openHome))
        homepage.bezelStyle = .rounded
        homepage.controlSize = .small
        stack.addArrangedSubview(PrefsKit.buttonRow([homepage], trailing: false))
    }

    @objc private func openHome() {
        NSWorkspace.shared.open(URL(string: "https://github.com/nextai-translator/nextai-translator")!)
    }
}


extension HistoryPane: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let title = NSTextField(labelWithString: item.source.replacingOccurrences(of: "\n", with: " "))
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: item.result.replacingOccurrences(of: "\n", with: " "))
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === table { replaySelected() }
    }
}
