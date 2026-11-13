import AppKit

/// 选中即翻：选中文字就弹卡片，不用按快捷键。
///
/// 这条路上「误触发」比「触发不了」讨厌得多——选中一段代码、拖选一半、
/// 在自己窗口里选中，都会变成一次请求（还要花钱）。所以判定做得保守：
///
/// - 同一段文字必须连续两次轮询都一样（约 0.7 秒）才算「选好了」
/// - 至少要 2 个字符，避免误触
/// - 同一段文字 8 秒内不重复翻
/// - 本 App 自己在前台时不触发（否则卡片里的选中会自我循环）
/// - 只读 AX，绝不模拟 ⌘C —— 每 0.35 秒一次的轮询碰剪贴板会毁掉用户剪贴板
final class SelectionAutoMonitor {

    static let shared = SelectionAutoMonitor()

    var onTrigger: ((String) -> Void)?
    /// 文本稳定选中时回调（不管要不要自动翻译）。工具栏用这个。
    var onSettled: ((String, NSPoint) -> Void)?

    private var timer: Timer?
    private var pendingText: String?
    private var pendingSince: Date?
    private var lastTriggerText: String?
    private var lastTriggerAt = Date.distantPast

    /// 两次轮询之间至少隔这么久，且要连续两次一样才认
    private let pollInterval: TimeInterval = 0.35
    private let confirmWindow: TimeInterval = 0.6
    private let sameTextCooldown: TimeInterval = 8
    private let minCharacters = 2

    private init() {}

    var isRunning: Bool { timer != nil }

    /// 按设置和权限决定开不开
    func syncWithSettings() {
        let shouldRun = (Config.shared.autoTranslateSelection || Config.shared.showSelectionToolbar)
            && AXIsProcessTrusted()
        setActive(shouldRun)
    }

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            pendingText = nil
            pendingSince = nil
            let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            Debug.log("选中即翻：开")
        } else {
            timer?.invalidate()
            timer = nil
            pendingText = nil
            pendingSince = nil
            Debug.log("选中即翻：关")
        }
    }

    static func isAppExcluded(bundleID: String?, appName: String?) -> Bool {
        let list = Config.shared.excludedAppList
        guard !list.isEmpty else { return false }
        let b = bundleID?.lowercased() ?? ""
        let n = appName?.lowercased() ?? ""
        for item in list {
            let target = item.lowercased()
            if !target.isEmpty, (b.contains(target) || n.contains(target)) {
                return true
            }
        }
        return false
    }

    private func poll() {
        // 自己在前台就不看：卡片里的选中、设置里的选中都不该触发
        if NSApp.isActive { return }
        if TranslationCard.shared.isVisible { return }

        // 排除应用黑名单：终端、游戏等排除应用中不自动弹窗触发
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            if Self.isAppExcluded(bundleID: frontApp.bundleIdentifier, appName: frontApp.localizedName) {
                return
            }
        }

        let candidate = SelectionReader.axSelectedText()
        if let text = evaluate(candidate: candidate, at: Date()) {
            onSettled?(text, NSEvent.mouseLocation)
            if onTrigger != nil { onTrigger?(text) }
        }
    }

    /// 判定逻辑单独拎出来：自测直接喂候选文本和时间，不依赖真实键盘鼠标。
    /// 返回要翻译的文本，或者 nil。
    func evaluate(candidate: String?, at now: Date) -> String? {
        guard let raw = candidate else {
            pendingText = nil
            pendingSince = nil
            return nil
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minCharacters else {
            pendingText = nil
            pendingSince = nil
            return nil
        }

        // 同一段文字刚翻过，冷却期内不再翻
        if let last = lastTriggerText, last == text, now.timeIntervalSince(lastTriggerAt) < sameTextCooldown {
            return nil
        }

        if pendingText != text {
            pendingText = text
            pendingSince = now
            return nil
        }
        // 内容一样，但还没稳定够久
        guard let since = pendingSince, now.timeIntervalSince(since) >= confirmWindow else {
            return nil
        }

        lastTriggerText = text
        lastTriggerAt = now
        pendingText = nil
        pendingSince = nil
        return text
    }
}