import AppKit
import Carbon.HIToolbox

/// 静默替换翻译：在可编辑区域里直接把原文换成译文，不弹任何窗口。
///
/// Bob 的两种用法：
/// - 静默划词翻译：选中几个字 → 按快捷键 → 只有这几个字被替换
/// - 静默输入框翻译：输入框里打完一段 → 按快捷键 → 整个输入框被替换
///
/// 写回有两条路：先试无障碍接口（不碰剪贴板、不会丢用户内容），
/// 不支持的应用再退回「写剪贴板 + 模拟 ⌘V」，并且事后把剪贴板还原。
enum SilentReplace {

    enum Scope {
        case selection      // 只替换选中的部分
        case wholeField     // 先全选，再替换整个输入框
    }

    enum Failure: Error {
        case notTrusted
        case nothingSelected
        case cannotFocus
        case translation(String)
        case writeFailed

        var message: String {
            switch self {
            case .notTrusted: return "需要辅助功能权限才能替换文字"
            case .nothingSelected: return "没有可选中的文字，先在输入框里选中内容"
            case .cannotFocus: return "当前应用没给出可编辑的输入区"
            case .translation(let reason): return reason
            case .writeFailed: return "这个应用不接受写入，换个应用再试"
            }
        }
    }

    /// 触发快捷键时前台是哪个 App。写完回前要把它拉回前台，否则 ⌘V 会粘到我们自己身上。
    private static var targetAppPID: pid_t?

    private static func rememberTargetApp() {
        targetAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func reactivateTargetApp() {
        guard let pid = targetAppPID,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isActive else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// 入口。必须在主线程调用。
    static func perform(scope: Scope, completion: ((Result<Void, Failure>) -> Void)? = nil) {
        rememberTargetApp()
        Debug.log("静默替换开始 scope=\(scope)")
        guard AXIsProcessTrusted() else {
            Debug.log("静默替换失败：没有辅助功能权限")
            finish(.failure(.notTrusted), completion); return
        }

        // 输入框翻译先全选
        if scope == .wholeField {
            sendKey(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command])
            // 全选是异步生效的，稍等一下再读
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                readAndTranslate(scope: scope, completion: completion)
            }
            return
        }
        readAndTranslate(scope: scope, completion: completion)
    }

    private static func readAndTranslate(scope: Scope, completion: ((Result<Void, Failure>) -> Void)?) {
        switch SelectionReader.selectedText(allowClipboardFallback: scope == .selection) {
        case .failure(let error):
            Debug.log("静默替换失败：读取选区 \(error.description)")
            finish(.failure(.translation(error.description)), completion)
        case .success(let text):
            Debug.log("静默替换读到 \(text.count) 字")
            let trimmed = TextPreprocessor.process(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !trimmed.isEmpty else { finish(.failure(.nothingSelected), completion); return }

            let targetLanguage = Config.shared.targetLanguage
            TranslateRunner.shared.runSilently(
                source: trimmed,
                mode: TranslateMode(rawValue: Config.shared.mode) ?? .translate,
                targetLanguage: targetLanguage
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error):
                        Debug.log("静默替换失败：翻译 \(error.message)")
                        finish(.failure(.translation(error.message)), completion)
                    case .success(let translated):
                        Debug.log("静默替换译文就绪，开始写回（\(translated.count) 字）")
                        writeBack(translated, completion: completion)
                    }
                }
            }
        }
    }

    // MARK: 写回

    @discardableResult
    static func writeBackText(_ text: String, completion: ((Result<Void, Failure>) -> Void)? = nil) -> Bool {
        writeBack(text, completion: completion)
        return true
    }

    /// 找一个「原文里没有、译文里有」的片段做校验指纹。
    /// 之前直接拿译文开头 16 字去比，遇到「译文开头和原文一样（都是日期/编号）」就假通过了。
    private static func verificationProbe(_ text: String, existing: String) -> String? {
        let chars = Array(text)
        guard chars.count >= 6 else {
            return existing.contains(text) ? nil : text
        }
        var start = chars.count / 3
        while start + 6 <= chars.count {
            let piece = String(chars[start..<(start + 6)])
            if !existing.contains(piece) { return piece }
            start += 3
        }
        return nil
    }

    private static func readFocusedValue() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func writeBack(_ text: String, completion: ((Result<Void, Failure>) -> Void)?) {
        let before = readFocusedValue() ?? ""
        let probe = verificationProbe(text, existing: before)
        if let probe, setTextViaAccessibility(text, probe: probe) {
            Debug.log("静默替换：AX 写回成功（命中校验）")
            finish(.success(()), completion)
            return
        }
        Debug.log("静默替换：AX 写回无效，改用剪贴板粘贴")
        reactivateTargetApp()

        // 退回剪贴板粘贴，完事还原用户原来的剪贴板
        let pasteboard = NSPasteboard.general
        let backup = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let data = item.data(forType: .string) else { return nil }
            return (item.types.first?.rawValue ?? "public.data", data)
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 等目标 App 真正回到前台再发 ⌘V，否则按键落空
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            sendKey(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command])

            var waited = 0.0
            func check(_ done: @escaping (Bool) -> Void) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let after = readFocusedValue() ?? ""
                    let ok: Bool
                    if let probe {
                        ok = after.contains(probe)
                    } else {
                        ok = !after.isEmpty && after != before
                    }
                    waited += 0.25
                    if ok || waited >= 1.75 { done(ok) } else { check(done) }
                }
            }
            check { ok in
                if !backup.isEmpty {
                    pasteboard.clearContents()
                    for (type, data) in backup {
                        let item = NSPasteboardItem()
                        item.setData(data, forType: NSPasteboard.PasteboardType(type))
                        pasteboard.writeObjects([item])
                    }
                }
                if ok {
                    Debug.log("静默替换：剪贴板粘贴成功（回读校验通过）")
                    finish(.success(()), completion)
                } else {
                    Debug.log("静默替换：粘贴后回读没变化")
                    finish(.failure(.writeFailed), completion)
                }
            }
        }
    }

    /// 用无障碍接口把选中区替换成指定文本，并用「指纹」回读校验。
    /// Word 这类应用对 `kAXSelectedText` 返回 `.success` 却什么都不做，只信返回值会被骗。
    private static func setTextViaAccessibility(_ text: String, probe: String) -> Bool {
        guard let element = focusedElement() else { return false }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard status == .success else {
            Debug.log("静默替换：AX set 返回 \(status.rawValue)")
            return false
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let current = value as? String else {
            Debug.log("静默替换：AX 回读不到控件文本")
            return false
        }
        guard current.contains(probe) else {
            Debug.log("静默替换：AX 回读校验失败（应用忽略了写入）")
            return false
        }
        return true
    }


    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef else { return nil }
        let app = appRef as! AXUIElement

        var elementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &elementRef) == .success,
           let elementRef {
            return elementRef as! AXUIElement
        }
        return nil
    }

    // MARK: 按键模拟

    private static func sendKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }

        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func finish(_ result: Result<Void, Failure>, _ completion: ((Result<Void, Failure>) -> Void)?) {
        switch result {
        case .success:
            if Config.shared.copyHint { HUD.show("已替换为译文") }
        case .failure(let error):
            HUD.show(error.message)
        }
        completion?(result)
    }
}
