import Foundation

/// 应用配置。普通设置存 UserDefaults，API Key 存 Keychain。
final class Config {
    static let shared = Config()

    private let defaults = UserDefaults.standard
    private let defaultsSuite = "com.localtranslate.settings"

    private init() {
        defaults.register(defaults: [
            "baseURL": "https://api.openai.com/v1",
            "model": "gpt-4o-mini",
            "targetLanguage": "zh-Hans",
            "hotkey": "control+shift+d",
            "silentHotkey": "control+shift+z",
            "dictionaryEnabled": true,
            "appearance": "system",
            "mode": "translate",
            "systemPrompt": "",
            "keepHistory": true,
            "autoCopy": false,
            "showThink": true,
            "timeoutSeconds": 60,
            "fontSize": 15,
            "renderMarkdown": true,
            "launchAtLogin": false,
            "doubleOptionTranslate": false,
            "selectionMode": "auto",
            "historyLimit": 500,
            "dictionaryMaxWords": 4,
            "copyHint": true,
            "pinByDefault": false,
            "showKeyPlain": false,
            "magpieBaseURL": "http://127.0.0.1:3425",
            "inputHotkey": "control+shift+a",
            "autoTranslateSelection": false,
            "screenshotHotkey": "control+shift+s",
            "dictionaryHotkey": "control+shift+k",
            "showMenuBarIcon": true,
            "clipboardHotkey": "control+shift+c",
            "speakHotkey": "control+shift+r",
            "toggleIconsHotkey": "control+shift+h",
            "silentScreenshotOcrHotkey": "control+shift+o",
            "silentReplaceHotkey": "control+shift+e",
            "inputBoxReplaceHotkey": "control+shift+w",
            "speechVoiceID": "",
            "speechRate": 1.0,
            "showSelectionToolbar": false,
            "proxyEnabled": false,
            "proxyType": "http",
            "proxyHost": "",
            "proxyPort": 7890,
            "proxyUsername": "",
            "ocrReviewBeforeTranslate": false,
            "ocrEngine": "system",
            "ttsEngine": "system",
            "showDockIcon": true,
            "sourceLanguage": "auto",
            "pinnedProfileIDs": [String](),
            "primaryLanguage": "zh-Hans",
            "secondaryLanguage": "en",
            "autoSwitchLanguage": true,
            "alwaysOnTop": false,
            "noScreenMargin": false,
            "uiLanguage": "system",
            "mergePDFNewlines": true,
            "splitCodeIdentifiers": true,
            "windowLocationMode": "mouse",
            "lastWindowOrigin": "",
            "excludedApps": "Terminal, iTerm2",
            "autoSpeakWhenDone": false,
            "ocrContinuous": false,
            "ocrLockArea": false,
            "ocrAutoCopy": true,
            "lastOcrRectString": "",
            "thinkCollapsed": true,
        ])
        _ = HotkeyDefaults.migrate(defaults)
    }

    /// 自测要能快照并还原配置，所以这个口子不开成 private
    var d: UserDefaults { defaults }

    var baseURL: String {
        get { d.string(forKey: "baseURL") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "baseURL") }
    }

    var model: String {
        get { d.string(forKey: "model") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "model") }
    }

    /// 多模型对比用的模型列表。设置里一行一个，或者用英文逗号分隔。
    var modelList: [String] {
        let raw = model
        var parts = raw.split { $0 == "," || $0 == "\n" }
        if parts.isEmpty { parts = [] }
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? [raw.trimmingCharacters(in: .whitespaces)] : cleaned
    }

    /// 静默翻译并复制的快捷键
    /// 面板里上次选的服务 id
    var panelProfileID: String? {
        get { d.string(forKey: "panelProfileID") }
        set { d.set(newValue, forKey: "panelProfileID") }
    }

    /// 静默划词替换：选中几个字，按快捷键直接替换成译文
    var silentReplaceHotkey: String {
        get { d.string(forKey: "silentReplaceHotkey") ?? "control+shift+e" }
        set { d.set(newValue, forKey: "silentReplaceHotkey") }
    }

    /// 静默输入框替换：整个输入框内容替换成译文
    var inputBoxReplaceHotkey: String {
        get { d.string(forKey: "inputBoxReplaceHotkey") ?? "control+shift+w" }
        set { d.set(newValue, forKey: "inputBoxReplaceHotkey") }
    }

    /// 剪贴板翻译
    var clipboardHotkey: String {
        get { d.string(forKey: "clipboardHotkey") ?? "control+shift+c" }
        set { d.set(newValue, forKey: "clipboardHotkey") }
    }

    /// 朗读上一次译文
    var speakHotkey: String {
        get { d.string(forKey: "speakHotkey") ?? "control+shift+r" }
        set { d.set(newValue, forKey: "speakHotkey") }
    }

    /// 一键隐藏/显示菜单栏图标
    var toggleIconsHotkey: String {
        get { d.string(forKey: "toggleIconsHotkey") ?? "control+shift+h" }
        set { d.set(newValue, forKey: "toggleIconsHotkey") }
    }

    /// 静默截图 OCR：截取屏幕，直接将识别文字拷贝到剪贴板，不弹窗
    var silentScreenshotOcrHotkey: String {
        get { d.string(forKey: "silentScreenshotOcrHotkey") ?? "control+shift+o" }
        set { d.set(newValue, forKey: "silentScreenshotOcrHotkey") }
    }

    /// 朗读用哪个引擎
    /// 访达选图 OCR（无默认快捷键，和 Bob 一样留空避免和输入法打架）
    var finderImageOcrHotkey: String {
        get { d.string(forKey: "finderImageOcrHotkey") ?? "" }
        set { d.set(newValue, forKey: "finderImageOcrHotkey") }
    }

    /// 浏览器助手本地服务端口
    var helperPort: UInt16 {
        get { UInt16(d.object(forKey: "helperPort") as? Int ?? 8765) }
        set { d.set(Int(newValue), forKey: "helperPort") }
    }

    var ttsEngine: String {
        get { d.string(forKey: "ttsEngine") ?? "system" }
        set { d.set(newValue, forKey: "ttsEngine") }
    }

    /// 截图取字用哪个引擎
    /// 截图/图片识别时顺带读二维码
    var ocrQRCode: Bool {
        get { d.object(forKey: "ocrQRCode") as? Bool ?? true }
        set { d.set(newValue, forKey: "ocrQRCode") }
    }

    var ocrEngine: String {
        get { d.string(forKey: "ocrEngine") ?? "system" }
        set { d.set(newValue, forKey: "ocrEngine") }
    }

    /// 指定原文语言。默认 "auto" 交给模型/服务自己检测；手动指定能改善小语种误判。
    var sourceLanguage: String {
        get { d.string(forKey: "sourceLanguage") ?? "auto" }
        set { d.set(newValue, forKey: "sourceLanguage") }
    }

    /// 钉在切换栏右侧的服务 id（对应 Bob 的钉住服务）
    var pinnedProfileIDs: [String] {
        get { d.array(forKey: "pinnedProfileIDs") as? [String] ?? [] }
        set { d.set(newValue, forKey: "pinnedProfileIDs") }
    }

    /// 源语言显示名（"auto" 除外）
    var sourceLanguagePrompt: String? {
        let code = sourceLanguage
        guard code != "auto", !code.isEmpty else { return nil }
        return Languages.promptName(for: code)
    }

    /// 第一语言（母语），默认简体中文
    var primaryLanguage: String {
        get { d.string(forKey: "primaryLanguage") ?? "zh-Hans" }
        set { d.set(newValue, forKey: "primaryLanguage") }
    }

    /// 第二语言（常用外语），默认英语
    var secondaryLanguage: String {
        get { d.string(forKey: "secondaryLanguage") ?? "en" }
        set { d.set(newValue, forKey: "secondaryLanguage") }
    }

    /// 输入为第一语言时自动译为第二语言，输入为其他语言时自动译为第一语言
    var autoSwitchLanguage: Bool {
        get { d.object(forKey: "autoSwitchLanguage") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoSwitchLanguage") }
    }

    /// 截图识别完先让人确认/修改原文，再翻译。
    /// 识别难免错字，直接翻会把错字一起翻进去，还看不出来错在哪。
    var ocrReviewBeforeTranslate: Bool {
        get { d.object(forKey: "ocrReviewBeforeTranslate") as? Bool ?? false }
        set { d.set(newValue, forKey: "ocrReviewBeforeTranslate") }
    }

    /// 跨应用强力置顶
    var alwaysOnTop: Bool {
        get { d.object(forKey: "alwaysOnTop") as? Bool ?? false }
        set { d.set(newValue, forKey: "alwaysOnTop") }
    }

    /// 贴近屏幕边缘时不留空白边距
    var noScreenMargin: Bool {
        get { d.object(forKey: "noScreenMargin") as? Bool ?? false }
        set { d.set(newValue, forKey: "noScreenMargin") }
    }

    /// 界面语言 (system / zh-Hans / zh-Hant / en)
    var uiLanguage: String {
        get { d.string(forKey: "uiLanguage") ?? "system" }
        set { d.set(newValue, forKey: "uiLanguage") }
    }

    /// 自动合并 PDF/文献复制导致的换行与恢复断词连字符
    var mergePDFNewlines: Bool {
        get { d.object(forKey: "mergePDFNewlines") as? Bool ?? true }
        set { d.set(newValue, forKey: "mergePDFNewlines") }
    }

    /// 自动拆分代码驼峰、下划线及连接线标识符
    var splitCodeIdentifiers: Bool {
        get { d.object(forKey: "splitCodeIdentifiers") as? Bool ?? true }
        set { d.set(newValue, forKey: "splitCodeIdentifiers") }
    }

    /// 窗口出现位置模式：mouse (跟随鼠标，默认), center (屏幕居中), last (记忆上次位置)
    var windowLocationMode: String {
        get { d.string(forKey: "windowLocationMode") ?? "mouse" }
        set { d.set(newValue, forKey: "windowLocationMode") }
    }

    /// 记忆的上一次窗口坐标 "x,y"
    var lastWindowOrigin: String {
        get { d.string(forKey: "lastWindowOrigin") ?? "" }
        set { d.set(newValue, forKey: "lastWindowOrigin") }
    }

    /// 排除应用黑名单（逗号或换行分隔的 App 名称或 BundleID）
    var excludedApps: String {
        get { d.string(forKey: "excludedApps") ?? "Terminal, iTerm2" }
        set { d.set(newValue, forKey: "excludedApps") }
    }

    var excludedAppList: [String] {
        excludedApps.split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 翻译或查词完成后自动朗读发音
    var autoSpeakWhenDone: Bool {
        get { d.object(forKey: "autoSpeakWhenDone") as? Bool ?? false }
        set { d.set(newValue, forKey: "autoSpeakWhenDone") }
    }

    /// 独立 OCR 工作台：连续识别拼接
    var ocrContinuous: Bool {
        get { d.object(forKey: "ocrContinuous") as? Bool ?? false }
        set { d.set(newValue, forKey: "ocrContinuous") }
    }

    /// 独立 OCR 工作台：锁定上次截图选区
    var ocrLockArea: Bool {
        get { d.object(forKey: "ocrLockArea") as? Bool ?? false }
        set { d.set(newValue, forKey: "ocrLockArea") }
    }

    /// 独立 OCR 工作台：识别完成自动复制到剪贴板
    var ocrAutoCopy: Bool {
        get { d.object(forKey: "ocrAutoCopy") as? Bool ?? true }
        set { d.set(newValue, forKey: "ocrAutoCopy") }
    }

    /// 上一次截图选区坐标 "x,y,w,h"
    var lastOcrRectString: String {
        get { d.string(forKey: "lastOcrRectString") ?? "" }
        set { d.set(newValue, forKey: "lastOcrRectString") }
    }

    var lastOcrRect: CGRect? {
        get {
            let parts = lastOcrRectString.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, parts[2] > 5, parts[3] > 5 else { return nil }
            return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        set {
            if let r = newValue {
                lastOcrRectString = "\(r.origin.x),\(r.origin.y),\(r.size.width),\(r.size.height)"
            } else {
                lastOcrRectString = ""
            }
        }
    }

    /// 卡片思考块是否默认折叠（跨重启记忆）
    var thinkCollapsed: Bool {
        get { d.object(forKey: "thinkCollapsed") as? Bool ?? true }
        set { d.set(newValue, forKey: "thinkCollapsed") }
    }

    var proxyEnabled: Bool {
        get { d.object(forKey: "proxyEnabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "proxyEnabled") }
    }

    var proxyType: String {
        get { d.string(forKey: "proxyType") ?? "http" }
        set { d.set(newValue, forKey: "proxyType") }
    }

    var proxyHost: String {
        get { d.string(forKey: "proxyHost") ?? "" }
        set { d.set(newValue, forKey: "proxyHost") }
    }

    /// 1...65535，越界会被夹住
    var proxyPort: Int {
        get {
            let raw = d.object(forKey: "proxyPort") as? Int ?? 7890
            return max(1, min(65535, raw))
        }
        set { d.set(max(1, min(65535, newValue)), forKey: "proxyPort") }
    }

    var proxyUsername: String {
        get { d.string(forKey: "proxyUsername") ?? "" }
        set { d.set(newValue, forKey: "proxyUsername") }
    }

    /// 划词工具栏。默认关：它会在每次选中时冒出来，先让用户自己开。
    var showSelectionToolbar: Bool {
        get { d.object(forKey: "showSelectionToolbar") as? Bool ?? false }
        set { d.set(newValue, forKey: "showSelectionToolbar") }
    }

    /// 朗读音色 id（空 = 按语言自动挑）
    var speechVoiceID: String {
        get { d.string(forKey: "speechVoiceID") ?? "" }
        set { d.set(newValue, forKey: "speechVoiceID") }
    }

    /// 朗读语速倍率，0.5 ~ 1.8
    var speechRate: Double {
        get { max(0.5, min(1.8, d.object(forKey: "speechRate") as? Double ?? 1.0)) }
        set { d.set(max(0.5, min(1.8, newValue)), forKey: "speechRate") }
    }

    /// 菜单栏图标是否显示
    var showMenuBarIcon: Bool {
        get { d.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMenuBarIcon") }
    }

    /// Dock 图标是否显示
    var showDockIcon: Bool {
        get { d.object(forKey: "showDockIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showDockIcon") }
    }

    /// 词典窗口快捷键
    var dictionaryHotkey: String {
        get { d.string(forKey: "dictionaryHotkey") ?? "control+shift+k" }
        set { d.set(newValue, forKey: "dictionaryHotkey") }
    }

    /// 截图翻译快捷键
    var screenshotHotkey: String {
        get { d.string(forKey: "screenshotHotkey") ?? "control+shift+s" }
        set { d.set(newValue, forKey: "screenshotHotkey") }
    }

    /// 选中即翻。默认关：开着容易误触发，要用户主动打开。
    var autoTranslateSelection: Bool {
        get { d.bool(forKey: "autoTranslateSelection") }
        set { d.set(newValue, forKey: "autoTranslateSelection") }
    }

    /// 输入翻译窗口的快捷键
    var inputHotkey: String {
        get { d.string(forKey: "inputHotkey") ?? "control+shift+a" }
        set { d.set(newValue, forKey: "inputHotkey") }
    }

    var silentHotkey: String {
        get { d.string(forKey: "silentHotkey") ?? "control+shift+z" }
        set { d.set(newValue, forKey: "silentHotkey") }
    }

    /// 划词时是否尝试词典模式
    var dictionaryEnabled: Bool {
        get { d.object(forKey: "dictionaryEnabled") == nil ? true : d.bool(forKey: "dictionaryEnabled") }
        set { d.set(newValue, forKey: "dictionaryEnabled") }
    }

    /// 外观：system / light / dark
    var appearance: String {
        get { d.string(forKey: "appearance") ?? "system" }
        set { d.set(newValue, forKey: "appearance") }
    }

    var targetLanguage: String {
        get { d.string(forKey: "targetLanguage") ?? "zh-Hans" }
        set { d.set(newValue, forKey: "targetLanguage") }
    }

    var hotkey: String {
        get { d.string(forKey: "hotkey") ?? "control+shift+d" }
        set { d.set(newValue, forKey: "hotkey") }
    }

    /// translate / polish / summarize
    /// 早期版本把界面中文名存了进去，这里统一映射回稳定标识。
    var mode: String {
        get {
            let stored = d.string(forKey: "mode") ?? "translate"
            if let match = TranslateMode.allCases.first(where: { $0.rawValue == stored }) {
                return match.rawValue
            }
            if let match = TranslateMode.allCases.first(where: { $0.title == stored }) {
                return match.rawValue
            }
            return "translate"
        }
        set { d.set(newValue, forKey: "mode") }
    }

    var systemPrompt: String {
        get { d.string(forKey: "systemPrompt") ?? "" }
        set { d.set(newValue, forKey: "systemPrompt") }
    }

    var keepHistory: Bool {
        get { d.bool(forKey: "keepHistory") }
        set { d.set(newValue, forKey: "keepHistory") }
    }

    var autoCopy: Bool {
        get { d.bool(forKey: "autoCopy") }
        set { d.set(newValue, forKey: "autoCopy") }
    }

    var showThink: Bool {
        get { d.bool(forKey: "showThink") }
        set { d.set(newValue, forKey: "showThink") }
    }

    // MARK: - 新增项（都要被真正消费，别做摆设）

    /// 请求超时秒数，5...300
    var timeoutSeconds: Double {
        get {
            let raw = d.object(forKey: "timeoutSeconds") as? Double ?? 60
            return min(max(raw, 5), 300)
        }
        set { d.set(min(max(newValue, 5), 300), forKey: "timeoutSeconds") }
    }

    /// 卡片正文字号
    var fontSize: Double {
        get { min(max(d.object(forKey: "fontSize") as? Double ?? 15, 11), 24) }
        set { d.set(min(max(newValue, 11), 24), forKey: "fontSize") }
    }

    /// 译文按 Markdown 渲染，关掉就纯文本
    var renderMarkdown: Bool {
        get { d.object(forKey: "renderMarkdown") == nil ? true : d.bool(forKey: "renderMarkdown") }
        set { d.set(newValue, forKey: "renderMarkdown") }
    }

    var launchAtLogin: Bool {
        get { d.bool(forKey: "launchAtLogin") }
        set { d.set(newValue, forKey: "launchAtLogin") }
    }

    /// 双击 Option 划词翻译（要辅助功能权限）
    var doubleOptionTranslate: Bool {
        get { d.bool(forKey: "doubleOptionTranslate") }
        set { d.set(newValue, forKey: "doubleOptionTranslate") }
    }

    /// 取词方式：auto（AX 优先，退剪贴板）/ ax（只用 AX）/ clipboard（直接模拟复制）
    var selectionMode: String {
        get { d.string(forKey: "selectionMode") ?? "auto" }
        set { d.set(newValue, forKey: "selectionMode") }
    }

    var historyLimit: Int {
        get { max(0, d.object(forKey: "historyLimit") as? Int ?? 500) }
        set { d.set(max(0, newValue), forKey: "historyLimit") }
    }

    /// 判定"是单词/词组"的英文单词数上限
    var dictionaryMaxWords: Int {
        get { max(1, d.object(forKey: "dictionaryMaxWords") as? Int ?? 4) }
        set { d.set(max(1, newValue), forKey: "dictionaryMaxWords") }
    }

    /// 复制成功后在提示条闪一下
    var copyHint: Bool {
        get { d.object(forKey: "copyHint") == nil ? true : d.bool(forKey: "copyHint") }
        set { d.set(newValue, forKey: "copyHint") }
    }

    /// 新弹出的卡片默认钉住（失焦不关）
    var pinByDefault: Bool {
        get { d.bool(forKey: "pinByDefault") }
        set { d.set(newValue, forKey: "pinByDefault") }
    }

    /// 设置里是否明文显示 API Key
    var showKeyPlain: Bool {
        get { d.bool(forKey: "showKeyPlain") }
        set { d.set(newValue, forKey: "showKeyPlain") }
    }

    /// Magpie 网关地址
    var magpieBaseURL: String {
        get { d.string(forKey: "magpieBaseURL") ?? "http://127.0.0.1:3425" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "magpieBaseURL") }
    }

    /// Magpie 的 gateway-key（开了才需要，回环默认不需要）
    var magpieGatewayKey: String { SecretStore.shared.apiKey(for: "magpie-gateway") }

    /// 拼接后的完整 endpoint
    var chatEndpoint: String {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return base }
        return base + "/chat/completions"
    }

    var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty && !SecretStore.shared.apiKey.isEmpty
    }
}
