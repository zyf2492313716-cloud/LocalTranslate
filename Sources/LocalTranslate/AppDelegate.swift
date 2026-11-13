import AppKit
import ApplicationServices

@main
struct LocalTranslateApp {
    static func main() {
        let args = CommandLine.arguments
        // 给脚本用：不启动界面，翻完就退
        if args.count > 2, args[1] == "--translate" {
            exit(ScriptCLI.translate(Array(args.dropFirst(2))))
        }
        if args.count > 1, args[1] == "--selftest" {
            let code = SelfTest.run(arguments: Array(args.dropFirst(2)))
            exit(code)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 菜单栏应用，不出现在 Dock
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var selectionWindow: ScreenSelectionWindow?
    private let panelController = StatusPanelController()
    private var statusMenu: NSMenu?
    private var statusItem: NSStatusItem?
    private var lastResult: String?
    private var lastSource: String = ""

    /// 在 Finder 里双击、或者从 Dock/启动台再点一次时，把设置界面调出来。
    /// 这个 App 是 LSUIElement（只在菜单栏），没有这个回调的话双击等于什么都没发生——
    /// 用户会以为软件坏了。
    /// 外部通过 localtranslate:// 调起来
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // 拖到图标 / 双击文件时，系统走的是这里（file:// URL），不是 openFiles
            if url.isFileURL {
                let ext = url.pathExtension.lowercased()
                if ext == "bobplugin" || ext == "js" {
                    installPluginFile(url)
                } else if ImageOCR.isImage(url) {
                    runImageOCR([url])
                }
                continue
            }
            switch URLRouter.parse(url) {
            case .failure(let message):
                Debug.log("URL 处理失败：\(message)")
                HUD.show(message)
            case .command(let command):
                handle(command)
            }
        }
    }

    /// Finder 双击 / 拖到应用图标：.bobplugin 直接装，图片直接识别
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Debug.log("openFiles 被调用：\(filenames)")
        var handled = false
        for path in filenames {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            if ext == "bobplugin" || ext == "js" {
                installPluginFile(url)
                handled = true
            } else if ImageOCR.isImage(url) {
                runImageOCR([url])
                handled = true
            }
        }
        sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    private func handle(_ command: URLRouter.Command) {
        switch command {
        case .translate(let text, let target, let copy):
            if let target { Config.shared.targetLanguage = target }
            if copy {
                TranslateRunner.shared.runSilently(
                    source: text,
                    mode: TranslateMode(rawValue: Config.shared.mode) ?? .translate,
                    targetLanguage: Config.shared.targetLanguage
                ) { result in
                    if case .success(let translated) = result {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(translated, forType: .string)
                    }
                }
            } else {
                runTranslation(source: text)
            }
        case .input:
            openInputTranslation()
        case .screenshot:
            screenshotTranslate()
        case .dictionary(let word):
            DictionaryWindow.shared.show(word: word)
        case .vocabulary:
            openVocabulary()
        case .favorites:
            openFavorites()
        case .helper:
            installBrowserHelper()
        case .history:
            HistoryWindow.shared.show()
        case .settings:
            openSettings()
        case .speak(let text):
            SpeechService.shared.speak(text)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindow.shared.showSettings()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        setupStatusItem()
        setupHotKeys()
        setupCardCallbacks()
        setupHistoryReplay()
        setupDoubleOption()
        setupAutoSelection()
        PluginRuntime.installSampleIfNeeded()
        // 存量纯 ⌥ 快捷键迁移成 ⌃ 系（macOS 15/26 的 Option 偶发失效）
        _ = HotkeyDefaults.migrate()
        panelController.onTranslate = { [weak self] text, profile in
            self?.translateFromPanel(text, profile: profile)
        }
        panelController.onOpenInput = { [weak self] in self?.openInputTranslation() }
        panelController.onOpenDictionary = { [weak self] in self?.openDictionary() }
        panelController.onOpenSettings = { [weak self] in self?.openSettings() }
        _ = AppIcons.apply(menuBar: Config.shared.showMenuBarIcon,
                           dock: Config.shared.showDockIcon,
                           statusItem: statusItem)
        setupObservers()

        // 手动打开（双击 App / 桌面快捷方式）时把界面亮出来，否则只有 Dock 图标，
        // 用户会以为没启动。开了开机自启的话这次可能是登录时拉起来的，就不弹窗打扰。
        if !Config.shared.launchAtLogin {
            // 不用「有没有可见窗口」来判断：菜单栏图标本身也会被算进 NSApp.windows，
            // 那个判断会一直为真，界面永远不弹。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreferencesWindow.shared.showSettings()
            }
        }

        // 提示辅助功能权限。用系统的非阻塞授权弹窗：
        // 自己跑 NSAlert.runModal() 会占住主 run loop，Carbon 热键在 modal 模式下不派发。
        requestAccessibilityIfNeeded(prompt: true)
    }

    // MARK: - 外观

    private func applyAppearance() {
        switch Config.shared.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil   // 跟随系统
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 没授权时图标带个感叹号，一眼能看出「装了但没用」
        let symbol = AXIsProcessTrusted() ? "character.bubble" : "exclamationmark.markdown"
        item.button?.image = NSImage(systemSymbolName: AXIsProcessTrusted() ? symbol : "exclamationmark.triangle",
                                     accessibilityDescription: "LocalTranslate")
        item.button?.image?.isTemplate = true
        if !AXIsProcessTrusted() {
            item.button?.toolTip = "还没有辅助功能权限，划词翻译读不到选中的文字"
        }

        let menu = NSMenu()

        let translateItem = NSMenuItem(title: "翻译选中内容", action: #selector(translateSelection), keyEquivalent: "")
        translateItem.target = self
        menu.addItem(translateItem)

        let dictItem = NSMenuItem(title: "词典…", action: #selector(openDictionary), keyEquivalent: "d")
        dictItem.keyEquivalentModifierMask = [.command, .shift]
        dictItem.target = self
        menu.addItem(dictItem)

        let compareItem = NSMenuItem(title: "对照视图…", action: #selector(openCompare), keyEquivalent: "")
        compareItem.target = self
        menu.addItem(compareItem)

        let rep1 = NSMenuItem(title: "静默替换选中文字", action: #selector(silentReplaceSelection), keyEquivalent: "")
        rep1.target = self
        menu.addItem(rep1)
        let rep2 = NSMenuItem(title: "静默替换整个输入框", action: #selector(silentReplaceInputBox), keyEquivalent: "")
        rep2.target = self
        menu.addItem(rep2)

        let pluginItem = NSMenuItem(title: "打开插件目录…", action: #selector(openPluginFolder), keyEquivalent: "")
        pluginItem.target = self
        menu.addItem(pluginItem)

        let installPluginItem = NSMenuItem(title: "安装 Bob 插件 (.bobplugin)…", action: #selector(installBobPlugin), keyEquivalent: "")
        installPluginItem.target = self
        menu.addItem(installPluginItem)

        let vocabItem = NSMenuItem(title: "生词本…", action: #selector(openVocabulary), keyEquivalent: "")
        vocabItem.target = self
        menu.addItem(vocabItem)

        let shotItem = NSMenuItem(title: "截图翻译…", action: #selector(screenshotTranslate), keyEquivalent: "s")
        shotItem.keyEquivalentModifierMask = [.command, .shift]
        shotItem.target = self
        menu.addItem(shotItem)

        let ocrWorkItem = NSMenuItem(title: "截图 OCR 工作台…", action: #selector(openOCRWorkspace), keyEquivalent: "")
        ocrWorkItem.target = self
        menu.addItem(ocrWorkItem)

        let silentOcrItem = NSMenuItem(title: "静默截图 OCR", action: #selector(silentScreenshotOcr), keyEquivalent: "")
        silentOcrItem.target = self
        menu.addItem(silentOcrItem)

        let origItem = NSMenuItem(title: "原图翻译…", action: #selector(originalImageTranslate), keyEquivalent: "")
        origItem.target = self
        menu.addItem(origItem)

        let batchItem = NSMenuItem(title: "访达选图 OCR…", action: #selector(finderBatchOcr), keyEquivalent: "")
        batchItem.target = self
        menu.addItem(batchItem)

        let inputItem = NSMenuItem(title: "输入翻译…", action: #selector(openInputTranslation), keyEquivalent: "i")
        inputItem.keyEquivalentModifierMask = [.command, .shift]
        inputItem.target = self
        menu.addItem(inputItem)

        let silentItem = NSMenuItem(title: "静默翻译并复制", action: #selector(silentTranslateSelection), keyEquivalent: "")
        silentItem.target = self
        menu.addItem(silentItem)

        let modeMenu = NSMenuItem(title: "模式", action: nil, keyEquivalent: "")
        let modeSub = NSMenu()
        for mode in TranslateMode.allCases {
            let m = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = mode.rawValue
            modeSub.addItem(m)
        }
        modeMenu.submenu = modeSub
        menu.addItem(modeMenu)

        let langMenu = NSMenuItem(title: "目标语言", action: nil, keyEquivalent: "")
        let langSub = NSMenu()
        for lang in Languages.all {
            let l = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            l.target = self
            l.representedObject = lang.code
            langSub.addItem(l)
        }
        langMenu.submenu = langSub
        menu.addItem(langMenu)

        let appearanceMenu = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let appearanceSub = NSMenu()
        for (value, title) in [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")] {
            let a = NSMenuItem(title: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            a.target = self
            a.representedObject = value
            appearanceSub.addItem(a)
        }
        appearanceMenu.submenu = appearanceSub
        menu.addItem(appearanceMenu)

        menu.addItem(.separator())

        let reopenItem = NSMenuItem(title: "显示上次翻译", action: #selector(reopenLastTranslation), keyEquivalent: "")
        reopenItem.target = self
        menu.addItem(reopenItem)

        let installFromURLItem = NSMenuItem(title: "从链接安装插件…", action: #selector(installPluginFromURL), keyEquivalent: "")
        installFromURLItem.target = self
        menu.addItem(installFromURLItem)

        let helperItem = NSMenuItem(title: "安装浏览器助手…", action: #selector(installBrowserHelper), keyEquivalent: "")
        helperItem.target = self
        menu.addItem(helperItem)

        let popclipItem = NSMenuItem(title: "安装 PopClip 扩展…", action: #selector(installPopClipExtension), keyEquivalent: "")
        popclipItem.target = self
        menu.addItem(popclipItem)

        let imageOcrItem = NSMenuItem(title: "识别图片文件…", action: #selector(ocrSelectedImages), keyEquivalent: "")
        imageOcrItem.target = self
        menu.addItem(imageOcrItem)

        let favItem = NSMenuItem(title: "收藏夹…", action: #selector(openFavorites), keyEquivalent: "")
        favItem.target = self
        menu.addItem(favItem)

        let historyItem = NSMenuItem(title: "翻译历史", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionItem = NSMenuItem(title: "权限与诊断…", action: #selector(openPermissionsPane), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let logItem = NSMenuItem(title: "导出日志…", action: #selector(exportLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let grantItem = NSMenuItem(title: "授予辅助功能权限", action: #selector(grantAccessibility), keyEquivalent: "")
        grantItem.target = self
        menu.addItem(grantItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        // 左键弹面板，右键还是老菜单。为了拿到点击类型，这里不能直接挂 menu。
        statusMenu = menu
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // 支持将图片直接拖拽至菜单栏图标进行 OCR 识别与翻译
            let dropOverlay = StatusItemDragDropView(frame: button.bounds)
            dropOverlay.autoresizingMask = [.width, .height]
            dropOverlay.onDropImageURL = { [weak self] url in
                self?.processDroppedImage(url)
            }
            button.addSubview(dropOverlay)
        }
        statusItem = item
        updateMenuChecks()
    }

    /// 左键弹面板，右键弹菜单（临时挂上 menu 再触发一次点击）
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRight {
            statusItem?.menu = statusMenu
            sender.performClick(nil)
            statusItem?.menu = nil
            return
        }
        guard let button = statusItem?.button else { return }
        panelController.toggle(relativeTo: button)
    }

    private func updateMenuChecks() {
        guard let menu = statusItem?.menu else { return }
        if let modeSub = menu.item(withTitle: "模式")?.submenu {
            for item in modeSub.items {
                item.state = (item.representedObject as? String) == Config.shared.mode ? .on : .off
            }
        }
        if let langSub = menu.item(withTitle: "目标语言")?.submenu {
            for item in langSub.items {
                item.state = (item.representedObject as? String) == Config.shared.targetLanguage ? .on : .off
            }
        }
        if let appearanceSub = menu.item(withTitle: "外观")?.submenu {
            for item in appearanceSub.items {
                item.state = (item.representedObject as? String) == Config.shared.appearance ? .on : .off
            }
        }
    }

    /// 双击 Option 划词。要辅助功能权限才能收到全局按键，没授权时按了没反应，
    /// 所以只在授权后才挂监听。
    private func setupDoubleOption() {
        DoubleOptionMonitor.shared.onTrigger = { [weak self] in
            self?.translateSelection()
        }
        DoubleOptionMonitor.shared.setActive(Config.shared.doubleOptionTranslate && AXIsProcessTrusted())
    }

    /// 选中即翻：监视到「稳定选中的文字」就弹卡片
    private func setupAutoSelection() {
        // 工具栏优先：开了工具栏就只冒图标，不自动发请求
        SelectionAutoMonitor.shared.onSettled = { [weak self] text, point in
            guard Config.shared.showSelectionToolbar else { return }
            SelectionToolbar.shared.show(text: text, near: point)
            _ = self
        }
        SelectionAutoMonitor.shared.onTrigger = { [weak self] text in
            guard Config.shared.autoTranslateSelection, !Config.shared.showSelectionToolbar else { return }
            Debug.log("选中即翻触发，\(text.count) 字")
            self?.runTranslation(source: text)
        }
        SelectionToolbar.shared.onTranslate = { [weak self] text in
            self?.runTranslation(source: text)
        }
        SelectionAutoMonitor.shared.syncWithSettings()
    }

    // MARK: - 快捷键

    private func setupHotKeys() {
        let combo = Config.shared.hotkey
        let silent = Config.shared.silentHotkey
        HotKeyManager.shared.onTrigger = { [weak self] kind in
            switch kind {
            case .translate: self?.translateSelection()
            case .silent:    self?.silentTranslateSelection()
            case .input:     self?.openInputTranslation()
            case .screenshot: self?.screenshotTranslate()
            case .dictionary: self?.openDictionary()
            case .clipboard:  self?.translateClipboard()
            case .speak:      self?.speakLastResult()
            case .toggleIcons: self?.toggleIconsViaHotkey()
            case .silentReplace: SilentReplace.perform(scope: .selection)
            case .inputBoxReplace: SilentReplace.perform(scope: .wholeField)
            case .silentScreenshotOcr: self?.silentScreenshotOcr()
            case .finderImageOcr: self?.ocrSelectedImages()
            }
        }
        let ok = HotKeyManager.shared.register(combo, kind: .translate)
        Debug.log("划词快捷键 \(combo) 注册\(ok ? "成功" : "失败")")
        let okSilent = HotKeyManager.shared.register(silent, kind: .silent)
        Debug.log("静默快捷键 \(silent) 注册\(okSilent ? "成功" : "失败")")

        let input = Config.shared.inputHotkey
        let okInput = HotKeyManager.shared.register(input, kind: .input)
        Debug.log("输入翻译快捷键 \(input) 注册\(okInput ? "成功" : "失败")")

        let shot = Config.shared.screenshotHotkey
        let okShot = HotKeyManager.shared.register(shot, kind: .screenshot)
        Debug.log("截图翻译快捷键 \(shot) 注册\(okShot ? "成功" : "失败")")

        let silentShot = Config.shared.silentScreenshotOcrHotkey
        let okSilentShot = HotKeyManager.shared.register(silentShot, kind: .silentScreenshotOcr)
        Debug.log("静默截图OCR快捷键 \(silentShot) 注册\(okSilentShot ? "成功" : "失败")")

        for (combo, kind, label) in [(Config.shared.silentReplaceHotkey, HotKeyManager.Kind.silentReplace, "静默划词替换"),
                                     (Config.shared.inputBoxReplaceHotkey, .inputBoxReplace, "静默输入框替换")] {
            let ok = HotKeyManager.shared.register(combo, kind: kind)
            Debug.log("\(label)快捷键 \(combo) 注册\(ok ? "成功" : "失败")")
        }

        let finderOCR = Config.shared.finderImageOcrHotkey
        if !finderOCR.isEmpty {
            let okFinder = HotKeyManager.shared.register(finderOCR, kind: .finderImageOcr)
            Debug.log("访达选图OCR快捷键 \(finderOCR) 注册\(okFinder ? "成功" : "失败")")
        }

        let dict = Config.shared.dictionaryHotkey
        let okDict = HotKeyManager.shared.register(dict, kind: .dictionary)
        Debug.log("词典快捷键 \(dict) 注册\(okDict ? "成功" : "失败")")

        for (combo, kind, label) in [(Config.shared.clipboardHotkey, HotKeyManager.Kind.clipboard, "剪贴板翻译"),
                                     (Config.shared.speakHotkey, .speak, "朗读"),
                                     (Config.shared.toggleIconsHotkey, .toggleIcons, "显示/隐藏图标")] {
            let ok = HotKeyManager.shared.register(combo, kind: kind)
            Debug.log("\(label)快捷键 \(combo) 注册\(ok ? "成功" : "失败")")
        }
    }

    // MARK: - 卡片回调

    private func setupCardCallbacks() {
        let card = TranslationCard.shared
        card.onReRequest = { [weak self] text in
            self?.runTranslation(source: text)
        }
        card.onRetry = { [weak self] in
            guard let self, !self.lastSource.isEmpty else { return }
            self.runTranslation(source: self.lastSource)
        }
        card.onOpenHistory = { [weak self] in
            self?.openHistory()
        }
        card.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        card.onCompleted = { [weak self] model, text, seconds in
            guard let self else { return }
            let name = ProfileStore.all().first(where: { $0.id == model })?.name ?? model
            HistoryStore.append(HistoryEntry(
                source: self.lastSource,
                result: text,
                mode: Config.shared.mode,
                model: name,
                targetLanguage: Config.shared.targetLanguage,
                date: Date(),
                seconds: seconds
            ))
            // 只自动复制第一个开着的服务的结果，否则几个服务的结果互相覆盖
            if Config.shared.autoCopy, model == ProfileStore.enabled().first?.id {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    /// 历史面板里点「重新翻译」：拿那条记录的原文重新走一遍当前配置
    private func setupObservers() {
        // 用户从系统设置回来，图标要跟着变
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusIcon()
            DoubleOptionMonitor.shared.setActive(Config.shared.doubleOptionTranslate && AXIsProcessTrusted())
            SelectionAutoMonitor.shared.syncWithSettings()
        }
        NotificationCenter.default.addObserver(forName: .localTranslatePrefsSaved,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusIcon()
            self?.updateMenuChecks()
            _ = AppIcons.apply(menuBar: Config.shared.showMenuBarIcon,
                               dock: Config.shared.showDockIcon,
                               statusItem: self?.statusItem)
            DoubleOptionMonitor.shared.setActive(Config.shared.doubleOptionTranslate && AXIsProcessTrusted())
        }
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let trusted = AXIsProcessTrusted()
        button.image = NSImage(systemSymbolName: trusted ? "character.bubble" : "exclamationmark.triangle",
                               accessibilityDescription: "LocalTranslate")
        button.image?.isTemplate = true
        button.toolTip = trusted ? "LocalTranslate" : "还没有辅助功能权限，划词翻译读不到选中的文字"
    }

    private func setupHistoryReplay() {
        NotificationCenter.default.addObserver(
            forName: .localTranslateReplay,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let entry = note.object as? HistoryEntry else { return }
            self.runTranslation(source: entry.source)
        }
    }

    // MARK: - 翻译

    @objc func translateSelection() {
        // 卡片正拿着焦点时先收起，否则 AX 的「焦点应用」会变成我们自己，读不到用户刚选的文字。
        // 收起后要让 AppKit 把 resignKey 处理完再读，所以走下一次主队列循环，
        // 不能用 usleep 把主线程钉住。
        if TranslationCard.shared.isVisible { TranslationCard.shared.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            switch SelectionReader.selectedText() {
            case .failure(let error):
                Debug.log("selection failed: \(error)")
                self.showCardWithError(error.description)
            case .success(let text):
                self.runTranslation(source: text)
            }
        }
    }

    private func showCardWithError(_ message: String) {
        let config = Config.shared
        TranslationCard.shared.present(
            source: "",
            mode: TranslateMode(rawValue: config.mode) ?? .translate,
            targetLanguage: config.targetLanguage,
            profiles: ProfileStore.enabled()
        )
        TranslationCard.shared.fail(model: ProfileStore.enabled().first?.id ?? "", message: message)
    }

    @objc private func silentTranslateSelection() {
        if TranslationCard.shared.isVisible { TranslationCard.shared.close() }
        switch readSelection() {
        case .failure(let error):
            HUD.show(error.description)
        case .success(let text):
            let cleaned = TextPreprocessor.process(text)
            let mode = TranslateMode(rawValue: Config.shared.mode) ?? .translate
            TranslateRunner.shared.runSilently(
                source: cleaned,
                mode: mode,
                targetLanguage: Config.shared.targetLanguage
            ) { result in
                switch result {
                case .success(let translated):
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(translated, forType: .string)
                    HUD.show("已复制译文")
                    HistoryStore.append(HistoryEntry(
                        source: cleaned, result: translated, mode: mode.rawValue,
                        model: ProfileStore.enabled().first?.name ?? "",
                        targetLanguage: Config.shared.targetLanguage,
                        date: Date(), seconds: nil
                    ))
                case .failure(let error):
                    HUD.show(error.message)
                }
            }
        }
    }

    private func readSelection() -> Result<String, SelectionReader.Failure> {
        SelectionReader.selectedText()
    }

    private func runTranslation(source: String, profiles explicitProfiles: [ServiceProfile]? = nil) {
        let cleaned = TextPreprocessor.process(source)
        lastSource = cleaned
        let config = Config.shared
        let mode = TranslateMode(rawValue: config.mode) ?? .translate
        let profiles = explicitProfiles ?? ProfileStore.enabled()

        TranslationCard.shared.present(
            source: cleaned, mode: mode,
            targetLanguage: config.targetLanguage,
            profiles: profiles
        )
        TranslateRunner.shared.run(
            source: cleaned, mode: mode,
            targetLanguage: config.targetLanguage,
            profiles: profiles,
            card: TranslationCard.shared
        )
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Config.shared.mode = raw
        updateMenuChecks()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Config.shared.targetLanguage = code
        updateMenuChecks()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        Config.shared.appearance = value
        applyAppearance()
        updateMenuChecks()
    }

    // MARK: - 其他

    @objc private func openHistory() {
        HistoryWindow.shared.show()
    }

    @objc func openPluginFolder() {
        PluginRuntime.ensureDirectory()
        PluginRuntime.installSampleIfNeeded()
        // 存量纯 ⌥ 快捷键迁移成 ⌃ 系（macOS 15/26 的 Option 偶发失效）
        _ = HotkeyDefaults.migrate()
        NSWorkspace.shared.open(PluginRuntime.directory)
    }

    @objc func installBobPlugin() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["bobplugin", "js"]
        panel.message = "选择 .bobplugin 插件（也支持单个 .js 插件）"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.installPluginFile(url)
            }
        }
    }

    /// 统一的插件安装入口：文件、双击、拖拽、URL 下载都走这里
    func installPluginFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "js" {
            PluginRuntime.ensureDirectory()
            let dest = PluginRuntime.directory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                HUD.show("已安装 JS 插件：\(url.lastPathComponent)")
                offerAddingPluginAsService(named: url.deletingPathExtension().lastPathComponent,
                                           file: url.lastPathComponent)
            } catch {
                HUD.show("安装失败：\(error.localizedDescription)")
            }
            return
        }

        switch PluginRuntime.installBobPlugin(at: url) {
        case .success(let res):
            let file = res.targetDirectory.lastPathComponent
            HUD.show("已安装插件：\(res.pluginName)")
            // 装完直接问一句要不要当服务用——这才是「易于上手」的关键一步
            offerAddingPluginAsService(named: res.pluginName, file: file)
        case .failure(let err):
            HUD.show(err.message)
        }
    }

    /// 装好插件后主动问「要不要现在就用它翻译」
    private func offerAddingPluginAsService(named name: String, file: String) {
        let alert = NSAlert()
        alert.messageText = "已安装「\(name)」"
        alert.informativeText = "要把它添加成一个翻译服务吗？添加后会立即出现在翻译卡片的服务列表里。"
        alert.addButton(withTitle: "添加为服务")
        alert.addButton(withTitle: "以后再说")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var profiles = ProfileStore.all()
        guard !profiles.contains(where: { $0.pluginFile == file }) else {
            HUD.show("这个插件已经添加过了")
            return
        }
        profiles.insert(ServiceProfile(
            id: "plugin-\(UUID().uuidString.prefix(8))",
            name: name,
            baseURL: "",
            model: "",
            enabled: true,
            extraPrompt: "",
            magpieModel: nil,
            provider: ProviderKind.plugin.rawValue,
            pluginFile: file
        ), at: 0)
        _ = ProfileStore.save(profiles)
        HUD.show("已添加服务：\(name)")
    }

    /// 生成本地服务 + Chromium 扩展，并打开说明
    @objc func installBrowserHelper() {
        guard let port = HelperServer.shared.start(preferredPort: Config.shared.helperPort) else {
            HUD.show("本地服务起不来（端口被占用）")
            return
        }
        switch BrowserHelper.generateExtension(port: port) {
        case .success(let dir):
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
            let alert = NSAlert()
            alert.messageText = "浏览器助手已就绪（端口 \(port)）"
            alert.informativeText = """
            1. 打开 chrome://extensions（Edge 是 edge://extensions）
            2. 打开右上角「开发者模式」
            3. 点「加载已解压的扩展程序」，选刚打开的文件夹
            4. 在网页里选中文字，右侧会出现「译」按钮

            目录：\(dir.path)
            """
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "复制目录路径")
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dir.path, forType: .string)
            }
        case .failure(let failure):
            HUD.show(failure.message)
        }
    }

    @objc func installPopClipExtension() {
        switch PopClipInstaller.install() {
        case .success:
            HUD.show("已生成 PopClip 扩展，按提示安装即可")
        case .failure(let failure):
            HUD.show(failure.message)
        }
    }

    /// 从链接安装：粘一个 .bobplugin 的下载地址
    @objc func installPluginFromURL() {
        let alert = NSAlert()
        alert.messageText = "从链接安装插件"
        alert.informativeText = "粘贴 .bobplugin 的下载地址（一般就是 GitHub Release 的直链）。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "https://github.com/.../xxx.bobplugin"
        alert.accessoryView = field
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else { return }

        Task {
            do {
                let (data, response) = try await NetworkSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    await MainActor.run { HUD.show("下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
                    return
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try data.write(to: tmp)
                await MainActor.run {
                    self.installPluginFile(tmp)
                }
            } catch {
                await MainActor.run { HUD.show("下载失败：\(error.localizedDescription)") }
            }
        }
    }

    @objc func openFavorites() {
        FavoriteWindow.shared.show()
    }

    @objc func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "localtranslate_debug.log"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = (try? String(contentsOfFile: Debug.logPath, encoding: .utf8))
                ?? "暂无本地日志内容。可在偏好设置开启调试日志后复现问题并导出。\n"
            try? content.write(to: url, atomically: true, encoding: .utf8)
            HUD.show("日志已导出")
        }
    }

    /// 重新显示上一次的翻译内容（防误关/再次查阅）
    @objc func reopenLastTranslation() {
        guard !lastSource.isEmpty else {
            HUD.show("暂无上一次翻译内容")
            return
        }
        runTranslation(source: lastSource)
    }

    /// 处理拖拽到菜单栏图标的图片文件进行 OCR 识别并翻译
    func processDroppedImage(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            HUD.show("无法读取该图片文件")
            return
        }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            HUD.show("图片转换失败")
            return
        }
        Task {
            let engine = OcrEngine(rawValue: Config.shared.ocrEngine) ?? .system
            let outcome = await ScreenOCR.recognize(cg, engine: engine)
            await MainActor.run {
                switch outcome {
                case .success(let text):
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else {
                        HUD.show("图片中未识别到文字")
                        return
                    }
                    self.runTranslation(source: cleaned)
                case .failure(let msg):
                    HUD.show(msg)
                }
            }
        }
    }

    private func showScreenCaptureAlert(detail: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        var body = "截图取字要先在系统设置里允许 LocalTranslate 录制屏幕。授权后通常需要重启一次 App。"
        if let detail, !detail.isEmpty {
            body += "\n\n系统拦截原因：\(detail)\n若系统设置里看似已勾选但仍被拦截，请点击「重置 TCC 并重授权」，然后重新勾选并重启本 App。"
        }
        alert.informativeText = body
        alert.addButton(withTitle: "去打开系统设置")
        alert.addButton(withTitle: "重置 TCC 并重授权")
        alert.addButton(withTitle: "取消")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            _ = ScreenOCR.requestPermission()
            ScreenOCR.openPermissionSettings()
        } else if resp == .alertSecondButtonReturn {
            _ = ScreenOCR.resetAndReRequestScreenCapture()
            ScreenOCR.openPermissionSettings()
        }
    }

    private func verifyScreenPermissionBeforeSnip(onGranted: @escaping () -> Void) {
        guard ScreenOCR.hasPermission else {
            showScreenCaptureAlert(detail: "系统预检或窗口标题读取显示未获授权")
            return
        }
        Task {
            let status = await ScreenOCR.probePermission(timeoutSeconds: 2.0)
            await MainActor.run {
                switch status {
                case .granted:
                    onGranted()
                case .preflightOnly(let detail), .denied(let detail):
                    self.showScreenCaptureAlert(detail: detail)
                }
            }
        }
    }

    /// 选区回调已经给了裁剪好的快照就直接用——省一次抓屏，也避免遮罩残影
    private func runWithCropped(_ cropped: CGImage?, rect: CGRect, screen: NSScreen,
                                onImage: @escaping (CGImage) async -> Void) {
        if let cropped, cropped.width > 1, cropped.height > 1 {
            Task { await onImage(cropped) }
            return
        }
        captureAndRun(rect: rect, screen: screen, onImage: onImage)
    }

    private func captureAndRun(rect: CGRect, screen: NSScreen, onImage: @escaping (CGImage) async -> Void) {
        Task {
            let outcome = await ScreenOCR.captureDetailed(rect: rect, screen: screen)
            switch outcome {
            case .success(let image):
                await onImage(image)
            case .permissionDenied(let detail):
                await MainActor.run { self.showScreenCaptureAlert(detail: detail) }
            case .failure(let detail):
                await MainActor.run { HUD.show("截图失败：\(detail)") }
            }
        }
    }

    /// 打开独立 OCR 工作台，支持连续识别拼接与锁定截图区重复抓取
    @objc func openOCRWorkspace() {
        let ocrWin = OCRWindow.shared
        ocrWin.onRequestSnip = { [weak self] in
            self?.runWorkspaceOCR()
        }
        ocrWin.onTranslateText = { [weak self] text in
            self?.runTranslation(source: text)
        }
        runWorkspaceOCR()
    }

    private func runWorkspaceOCR() {
        verifyScreenPermissionBeforeSnip { [weak self] in
            guard let self else { return }
            if Config.shared.ocrLockArea, let lockedRect = Config.shared.lastOcrRect {
                let screen = NSScreen.main ?? NSScreen.screens[0]
                self.captureAndRun(rect: lockedRect, screen: screen) { img in
                    await MainActor.run { OCRWindow.shared.recognizeAndPresent(image: img) }
                }
                return
            }

            let picker = ScreenSelectionWindow()
            self.selectionWindow = picker
            picker.begin { [weak self] rect, screen, cropped in
                guard let self else { return }
                self.selectionWindow = nil
                guard let rect else { return }
                Config.shared.lastOcrRect = rect
                self.runWithCropped(cropped, rect: rect, screen: screen) { image in
                    await MainActor.run { OCRWindow.shared.recognizeAndPresent(image: image) }
                }
            }
        }
    }

    /// 框选 → OCR → 翻译。没屏幕录制权限时把话说明白，别让人对着没反应的遮罩发呆。
    @objc func screenshotTranslate() {
        verifyScreenPermissionBeforeSnip { [weak self] in
            guard let self else { return }
            let picker = ScreenSelectionWindow()
            self.selectionWindow = picker   // 留住，不然拖框的视图会被提前释放
            picker.begin { [weak self] rect, screen, cropped in
                guard let self else { return }
                self.selectionWindow = nil
                guard let rect else { return }   // 取消或者框太小
                self.runWithCropped(cropped, rect: rect, screen: screen) { image in
                    let engine = OcrEngine(rawValue: Config.shared.ocrEngine) ?? .system
                    let outcome = await ScreenOCR.recognize(image, engine: engine)
                    var cleaned: String
                    switch outcome {
                    case .success(let text):
                        cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .failure(let message):
                        await MainActor.run { HUD.show(message) }
                        return
                    }
                    if Config.shared.ocrQRCode {
                        let codes = await ScreenOCR.detectQRcodes(image)
                        if !codes.isEmpty {
                            cleaned += "\n\n" + codes.map { "二维码：\($0)" }.joined(separator: "\n")
                        }
                    }
                    await MainActor.run {
                        guard !cleaned.isEmpty else {
                            HUD.show("这块区域没识别到文字")
                            return
                        }
                        Debug.log("截图识别到 \(cleaned.count) 字")
                        if Config.shared.ocrReviewBeforeTranslate {
                            InputTranslationWindow.shared.show(prefill: cleaned)
                        } else {
                            self.runTranslation(source: cleaned)
                        }
                    }
                }
            }
        }
    }

    /// 访达选图 OCR：优先识别访达里选中的图片；没选中就弹面板挑。
    /// 结果直接进「识别结果」窗口，可编辑、可复制，也可以一键翻译。
    @objc func ocrSelectedImages() {
        var urls = ImageOCR.finderSelection()
        if urls.isEmpty { urls = ImageOCR.pickImages() }
        runImageOCR(urls)
    }

    /// 双击图片/拖到图标上、以及热键选中图片，都走这里
    private var lastOCRPath: String = ""
    private var lastOCRTime = Date.distantPast

    func runImageOCR(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 同一次打开可能同时走到 open(urls:) 和 openFiles:，2 秒内同一批文件只处理一次
        let key = urls.map(\.path).joined(separator: "|")
        if key == lastOCRPath, Date().timeIntervalSince(lastOCRTime) < 2 { return }
        lastOCRPath = key
        lastOCRTime = Date()
        Debug.log("访达选图OCR：\(urls.count) 个文件")

        let engine = OcrEngine(rawValue: Config.shared.ocrEngine) ?? .system
        Task {
            var collected: [String] = []
            var firstImage: CGImage?
            for url in urls {
                let outcome = await ImageOCR.recognize(file: url, engine: engine)
                switch outcome {
                case .success(let result):
                    if firstImage == nil { firstImage = ImageOCR.loadCGImage(url) }
                    collected.append(result.combined)
                case .failure(let failure):
                    collected.append("[\(url.lastPathComponent)] \(failure.message)")
                }
            }
            await MainActor.run {
                let text = collected.joined(separator: "\n\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    HUD.show("没识别到内容")
                    return
                }
                if Config.shared.ocrReviewBeforeTranslate {
                    OCRWindow.shared.present(image: firstImage, text: text)
                } else if let first = firstImage {
                    OCRWindow.shared.present(image: first, text: text)
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    HUD.show("已识别 \(text.count) 字并复制")
                }
            }
        }
    }

    /// 静默截图 OCR：框选后后台识别，直接把文本写入剪贴板，不弹卡片或窗口
    @objc func silentScreenshotOcr() {
        verifyScreenPermissionBeforeSnip { [weak self] in
            guard let self else { return }
            let picker = ScreenSelectionWindow()
            self.selectionWindow = picker
            picker.begin { [weak self] rect, screen, cropped in
                guard let self else { return }
                self.selectionWindow = nil
                guard let rect else { return }
                self.runWithCropped(cropped, rect: rect, screen: screen) { image in
                    let engine = OcrEngine(rawValue: Config.shared.ocrEngine) ?? .system
                    let outcome = await ScreenOCR.recognize(image, engine: engine)
                    var qrSuffix = ""
                    if Config.shared.ocrQRCode {
                        let codes = await ScreenOCR.detectQRcodes(image)
                        if !codes.isEmpty {
                            qrSuffix = "\n\n" + codes.map { "二维码：\($0)" }.joined(separator: "\n")
                        }
                    }
                    await MainActor.run {
                        switch outcome {
                        case .success(let text):
                            var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines) + qrSuffix
                            guard !cleaned.isEmpty else {
                                HUD.show("这块区域没识别到文字")
                                return
                            }
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(cleaned, forType: .string)
                            HUD.show("已识别并拷贝 (\(cleaned.count)字)")
                        case .failure(let message):
                            HUD.show(message)
                        }
                    }
                }
            }
        }
    }

    /// 原图翻译：截图 → 逐段翻译 → 把译文画回原图，图片放剪贴板
    @objc func originalImageTranslate() {
        guard let profile = ProfileStore.firstUsable() else {
            HUD.show("还没有可用的翻译服务，去设置里加一个")
            return
        }
        verifyScreenPermissionBeforeSnip { [weak self] in
            guard let self else { return }
            let picker = ScreenSelectionWindow()
            self.selectionWindow = picker
            picker.begin { [weak self] rect, screen, cropped in
                guard let self else { return }
                self.selectionWindow = nil
                guard let rect else { return }
                self.runWithCropped(cropped, rect: rect, screen: screen) { image in
                    let result = await ScreenOCR.originalImageTranslate(image,
                                                                        targetLanguage: Config.shared.targetLanguage,
                                                                        profile: profile)
                    await MainActor.run {
                        guard let result else {
                            HUD.show("没识别到文字，或者翻译都失败了")
                            return
                        }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))])
                        HUD.show("原图翻译已放到剪贴板")
                    }
                }
            }
        }
    }

    /// 访达批量选图 OCR：多选图片，一次性识别，全部拼到剪贴板
    @objc func finderBatchOcr() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        HUD.show("正在识别 \(urls.count) 张…")
        Task.detached(priority: .userInitiated) {
            let engine = OcrEngine(rawValue: Config.shared.ocrEngine) ?? .system
            var chunks: [String] = []
            for url in urls {
                guard let img = NSImage(contentsOf: url),
                      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let outcome = await ScreenOCR.recognize(cg, engine: engine)
                if case .success(let text) = outcome,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append("=== \(url.lastPathComponent) ===\n\(text)")
                }
            }
            await MainActor.run {
                guard !chunks.isEmpty else {
                    HUD.show("这些图里都没识别到文字")
                    return
                }
                let combined = chunks.joined(separator: "\n\n")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(combined, forType: .string)
                HUD.show("已识别 \(chunks.count) 张并拷贝")
            }
        }
    }

    /// 面板里发起翻译：指定的服务只用那一个，没指定就用全部开着的
    private func translateFromPanel(_ text: String, profile: ServiceProfile?) {
        if TranslationCard.shared.isVisible { TranslationCard.shared.close() }
        if let profile {
            runTranslation(source: text, profiles: [profile])
        } else {
            runTranslation(source: text)
        }
    }

    /// 剪贴板翻译：翻当前剪贴板里的文字
    @objc private func translateClipboard() {
        clipboardTranslate()
    }

    /// 卡片工具条上的「剪贴板翻译」按钮走这里（同一个实现，两处入口共用）
    func clipboardTranslate() {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            HUD.show("剪贴板里没有文字")
            return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            HUD.show("剪贴板里没有文字")
            return
        }
        if TranslationCard.shared.isVisible { TranslationCard.shared.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.runTranslation(source: text)
        }
    }

    /// 朗读上一次的译文（没有就朗读原文）
    @objc private func speakLastResult() {
        SpeechService.shared.speak(SpeechService.shared.lastSpokenText
                                   ?? lastResult ?? lastSource ?? "")
    }

    /// 一键隐藏/显示菜单栏图标。Dock 保持不动，所以不会把自己关到找不回来。
    @objc private func toggleIconsViaHotkey() {
        let menuBar = Config.shared.showMenuBarIcon
        Config.shared.showMenuBarIcon = !menuBar
        _ = AppIcons.apply(menuBar: Config.shared.showMenuBarIcon,
                           dock: Config.shared.showDockIcon,
                           statusItem: statusItem)
        HUD.show(Config.shared.showMenuBarIcon ? "菜单栏图标已显示" : "菜单栏图标已隐藏")
    }

    @objc private func openCompare() {
        let latest = TranslateRunner.shared.latest
        guard latest.count > 0 else {
            HUD.show("还没有翻译结果，先翻一段试试")
            return
        }
        CompareWindow.shared.show(
            source: TranslateRunner.shared.latestSource,
            columns: latest.map { CompareWindow.Column(title: $0.name, text: $0.text) }
        )
    }

    @objc private func silentReplaceSelection() {
        SilentReplace.perform(scope: .selection)
    }

    @objc private func silentReplaceInputBox() {
        SilentReplace.perform(scope: .wholeField)
    }

    @objc private func openVocabulary() {
        VocabularyWindow.shared.show()
    }

    @objc private func openDictionary() {
        // 词典快捷键要有东西可查：优先用当前选区，没有选区退回剪贴板。
        // 以前只是把空窗口弹出来，用户按了快捷键看到一片空白，像坏了。
        var word = SelectionReader.axSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if word?.isEmpty != false {
            word = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let candidate = (word?.isEmpty == false) ? word : nil
        DictionaryWindow.shared.show(word: candidate)
    }

    @objc private func openInputTranslation() {
        InputTranslationWindow.shared.show()
    }

    @objc private func openSettings() {
        PreferencesWindow.shared.showSettings()
    }

    @objc private func openPermissionsPane() {
        PreferencesWindow.shared.show(section: .permissions)
    }

    @objc private func grantAccessibility() {
        if !requestAccessibilityIfNeeded(prompt: true) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    private func requestAccessibilityIfNeeded(prompt: Bool) -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted { return true }
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        return false
    }
}

/// 状态栏图标拖拽接收层，支持用户将图片直接丢到状态栏图标进行翻译
final class StatusItemDragDropView: NSView {
    var onDropImageURL: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("不支持 nib") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 返回 nil 让所有普通鼠标左键/右键点击直接穿透给下层的 NSStatusBarButton
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL else {
            return []
        }
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "webp", "tiff", "gif", "bmp"].contains(ext) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL else {
            return false
        }
        onDropImageURL?(url)
        return true
    }
}
