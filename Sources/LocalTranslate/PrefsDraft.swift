import AppKit

/// 待保存的设置草稿。
///
/// 界面上的改动先进草稿，点「保存」才落到配置。这样误改一项不至于立刻影响正在用的功能，
/// 「撤销」也才有东西可以退回去。
struct PrefsDraft: Equatable, Codable {
    var targetLanguage: String
    var sourceLanguage: String
    var primaryLanguage: String
    var secondaryLanguage: String
    var autoSwitchLanguage: Bool
    var mode: String
    var systemPrompt: String
    var timeoutSeconds: Double
    var fontSize: Double
    var renderMarkdown: Bool
    var showThink: Bool
    var autoCopy: Bool
    var copyHint: Bool
    var pinByDefault: Bool
    var appearance: String
    var uiLanguage: String
    var selectionMode: String
    var dictionaryEnabled: Bool
    var dictionaryMaxWords: Int
    var keepHistory: Bool
    var historyLimit: Int
    var hotkey: String
    var silentHotkey: String
    var inputHotkey: String
    var screenshotHotkey: String
    var silentScreenshotOcrHotkey: String
    var finderImageOcrHotkey: String
    var dictionaryHotkey: String
    var silentReplaceHotkey: String
    var inputBoxReplaceHotkey: String
    var clipboardHotkey: String
    var speakHotkey: String
    var toggleIconsHotkey: String
    var speechVoiceID: String
    var speechRate: Double
    var showSelectionToolbar: Bool
    var proxyEnabled: Bool
    var proxyType: String
    var proxyHost: String
    var proxyPort: Int
    var proxyUsername: String
    var ocrReviewBeforeTranslate: Bool
    var ocrEngine: String
    var ocrContinuous: Bool
    var ocrAutoCopy: Bool
    var ocrLockArea: Bool
    var ttsEngine: String
    var showMenuBarIcon: Bool
    var showDockIcon: Bool
    var alwaysOnTop: Bool
    var noScreenMargin: Bool
    var mergePDFNewlines: Bool
    var splitCodeIdentifiers: Bool
    var autoTranslateSelection: Bool
    var windowLocationMode: String
    var excludedApps: String
    var autoSpeakWhenDone: Bool
    var doubleOptionTranslate: Bool
    var launchAtLogin: Bool
    var magpieBaseURL: String

    var profiles: [ServiceProfile]
    /// 本次编辑里改过的密钥：profileID → 新值。没动过的服务不写钥匙串。
    var keyEdits: [String: String] = [:]

    static func load() -> PrefsDraft {
        let config = Config.shared
        return PrefsDraft(
            targetLanguage: config.targetLanguage,
            sourceLanguage: config.sourceLanguage,
            primaryLanguage: config.primaryLanguage,
            secondaryLanguage: config.secondaryLanguage,
            autoSwitchLanguage: config.autoSwitchLanguage,
            mode: config.mode,
            systemPrompt: config.systemPrompt,
            timeoutSeconds: config.timeoutSeconds,
            fontSize: config.fontSize,
            renderMarkdown: config.renderMarkdown,
            showThink: config.showThink,
            autoCopy: config.autoCopy,
            copyHint: config.copyHint,
            pinByDefault: config.pinByDefault,
            appearance: config.appearance,
            uiLanguage: config.uiLanguage,
            selectionMode: config.selectionMode,
            dictionaryEnabled: config.dictionaryEnabled,
            dictionaryMaxWords: config.dictionaryMaxWords,
            keepHistory: config.keepHistory,
            historyLimit: config.historyLimit,
            hotkey: config.hotkey,
            silentHotkey: config.silentHotkey,
            inputHotkey: config.inputHotkey,
            screenshotHotkey: config.screenshotHotkey,
            silentScreenshotOcrHotkey: config.silentScreenshotOcrHotkey,
            finderImageOcrHotkey: config.finderImageOcrHotkey,
            dictionaryHotkey: config.dictionaryHotkey,
            silentReplaceHotkey: config.silentReplaceHotkey,
            inputBoxReplaceHotkey: config.inputBoxReplaceHotkey,
            clipboardHotkey: config.clipboardHotkey,
            speakHotkey: config.speakHotkey,
            toggleIconsHotkey: config.toggleIconsHotkey,
            speechVoiceID: config.speechVoiceID,
            speechRate: config.speechRate,
            showSelectionToolbar: config.showSelectionToolbar,
            proxyEnabled: config.proxyEnabled,
            proxyType: config.proxyType,
            proxyHost: config.proxyHost,
            proxyPort: config.proxyPort,
            proxyUsername: config.proxyUsername,
            ocrReviewBeforeTranslate: config.ocrReviewBeforeTranslate,
            ocrEngine: config.ocrEngine,
            ocrContinuous: config.ocrContinuous,
            ocrAutoCopy: config.ocrAutoCopy,
            ocrLockArea: config.ocrLockArea,
            ttsEngine: config.ttsEngine,
            showMenuBarIcon: config.showMenuBarIcon,
            showDockIcon: config.showDockIcon,
            alwaysOnTop: config.alwaysOnTop,
            noScreenMargin: config.noScreenMargin,
            mergePDFNewlines: config.mergePDFNewlines,
            splitCodeIdentifiers: config.splitCodeIdentifiers,
            autoTranslateSelection: config.autoTranslateSelection,
            windowLocationMode: config.windowLocationMode,
            excludedApps: config.excludedApps,
            autoSpeakWhenDone: config.autoSpeakWhenDone,
            doubleOptionTranslate: config.doubleOptionTranslate,
            launchAtLogin: LaunchAtLogin.isEnabled,
            magpieBaseURL: config.magpieBaseURL,
            profiles: ProfileStore.all()
        )
    }

    /// 和当前生效的配置比，决定「撤销/保存」能不能点
    /// 所有快捷键，供冲突检查用
    var hotkeys: [(label: String, combo: String)] {
        [("划词翻译", hotkey), ("静默翻译并复制", silentHotkey), ("输入翻译", inputHotkey),
         ("截图翻译", screenshotHotkey), ("静默截图 OCR", silentScreenshotOcrHotkey), ("词典", dictionaryHotkey),
         ("剪贴板翻译", clipboardHotkey), ("朗读", speakHotkey), ("显示/隐藏图标", toggleIconsHotkey),
         ("静默划词替换", silentReplaceHotkey), ("静默输入框替换", inputBoxReplaceHotkey)]
    }

    /// 这个组合是否已被另一个功能占用
    func conflictLabel(for combo: String, ignoring label: String) -> String? {
        hotkeys.first { $0.label != label && $0.combo == combo }?.label
    }

    func isDirty() -> Bool {
        let live = PrefsDraft.load()
        if normalized() != live.normalized() { return true }
        if !keyEdits.isEmpty { return true }
        return false
    }

    private func normalized() -> PrefsDraft {
        var copy = self
        copy.keyEdits = [:]
        return copy
    }

    /// 落盘。返回 nil 表示成功，否则是第一条需要告诉用户的问题。
    @discardableResult
    func apply() -> String? {
        let config = Config.shared
        config.targetLanguage = targetLanguage
        config.sourceLanguage = sourceLanguage
        config.primaryLanguage = primaryLanguage
        config.secondaryLanguage = secondaryLanguage
        config.autoSwitchLanguage = autoSwitchLanguage
        config.mode = mode
        config.systemPrompt = systemPrompt
        config.timeoutSeconds = timeoutSeconds
        config.fontSize = fontSize
        config.renderMarkdown = renderMarkdown
        config.showThink = showThink
        config.autoCopy = autoCopy
        config.copyHint = copyHint
        config.pinByDefault = pinByDefault
        config.appearance = appearance
        config.uiLanguage = uiLanguage
        config.selectionMode = selectionMode
        config.dictionaryEnabled = dictionaryEnabled
        config.dictionaryMaxWords = dictionaryMaxWords
        config.keepHistory = keepHistory
        config.historyLimit = historyLimit
        config.hotkey = hotkey
        config.silentHotkey = silentHotkey
        config.inputHotkey = inputHotkey
        config.screenshotHotkey = screenshotHotkey
        config.silentScreenshotOcrHotkey = silentScreenshotOcrHotkey
        config.finderImageOcrHotkey = finderImageOcrHotkey
        config.dictionaryHotkey = dictionaryHotkey
        config.silentReplaceHotkey = silentReplaceHotkey
        config.inputBoxReplaceHotkey = inputBoxReplaceHotkey
        config.clipboardHotkey = clipboardHotkey
        config.speakHotkey = speakHotkey
        config.toggleIconsHotkey = toggleIconsHotkey
        config.speechVoiceID = speechVoiceID
        config.speechRate = speechRate
        config.showSelectionToolbar = showSelectionToolbar
        config.proxyEnabled = proxyEnabled
        config.proxyType = proxyType
        config.proxyHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        config.proxyPort = proxyPort
        config.proxyUsername = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        config.ocrReviewBeforeTranslate = ocrReviewBeforeTranslate
        config.ocrEngine = ocrEngine
        config.ocrContinuous = ocrContinuous
        config.ocrAutoCopy = ocrAutoCopy
        config.ocrLockArea = ocrLockArea
        config.ttsEngine = ttsEngine
        NetworkSession.invalidate()
        // 两个都关会失去入口，这里先修正再存
        let icons = AppIcons.resolve(menuBar: showMenuBarIcon, dock: showDockIcon)
        config.showMenuBarIcon = icons.menuBar
        config.showDockIcon = icons.dock
        config.alwaysOnTop = alwaysOnTop
        config.noScreenMargin = noScreenMargin
        config.mergePDFNewlines = mergePDFNewlines
        config.splitCodeIdentifiers = splitCodeIdentifiers
        config.autoTranslateSelection = autoTranslateSelection
        config.windowLocationMode = windowLocationMode
        config.excludedApps = excludedApps
        config.autoSpeakWhenDone = autoSpeakWhenDone
        SelectionAutoMonitor.shared.syncWithSettings()
        config.doubleOptionTranslate = doubleOptionTranslate
        config.magpieBaseURL = magpieBaseURL

        var saved = profiles
        for index in saved.indices {
            saved[index].model = saved[index].model.trimmingCharacters(in: .whitespacesAndNewlines)
            saved[index].baseURL = saved[index].baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let writeOK = ProfileStore.save(saved)
        if !writeOK { return "服务列表写入失败，检查磁盘权限" }

        for (profileID, value) in keyEdits {
            guard let profile = saved.first(where: { $0.id == profileID }) else { continue }
            SecretStore.shared.setAPIKey(value, account: profile.keyAccount)
        }

        AppearanceApplier.apply(appearance)
        HotKeyManager.shared.unregister()
        let translateOK = HotKeyManager.shared.register(hotkey, kind: .translate)
        let silentOK = HotKeyManager.shared.register(silentHotkey, kind: .silent)
        DoubleOptionMonitor.isEnabled = doubleOptionTranslate

        var notes: [String] = []
        if !writeOK { notes.append("服务列表没能保存") }
        if !translateOK { notes.append("划词快捷键注册失败，可能被别的 App 占用") }
        if !silentOK { notes.append("静默快捷键注册失败，可能被别的 App 占用") }
        if saved.allSatisfy({ !$0.enabled }) { notes.append("所有服务都是关着的，会默认用第一个") }
        return notes.first
    }
}

/// 外观切换集中一处，菜单和设置页都要用
enum AppearanceApplier {
    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
