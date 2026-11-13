import AppKit
import ApplicationServices

/// 取当前选中的文字。
/// 优先走 Accessibility API 读焦点控件的 AXSelectedText；读不到就退回模拟复制。
enum SelectionReader {

    /// 失败原因。面板上直接显示，用户一眼能看出该做什么。
    enum Failure: Error, CustomStringConvertible {
        case notTrusted
        case noFocusedApp(status: Int)
        case noSelection
        case clipboardEmpty

        var description: String {
            switch self {
            case .notTrusted:
                return "没有辅助功能权限，读不到选中文字。去系统设置里勾选 LocalTranslate。"
            case .noFocusedApp(let status):
                if status == -25212 {
                    return "当前窗口没把选中内容交给系统（AX 返回「无值」）。常见于密码框、游戏窗口，"
                        + "或开了安全键盘输入的应用。可以在「设置 → 外观与行为 → 取词」里改成"
                        + "「只用剪贴板（模拟 ⌘C）」，那条路不依赖无障碍接口。"
                }
                return "读不到当前应用（AX 错误码 \(status)）。已经试过模拟复制，也没拿到内容——"
                    + "换个窗口再试，或把取词方式改成「只用剪贴板」。"
            case .noSelection:
                return "当前应用没有暴露选中文字，先选中内容再按快捷键。"
            case .clipboardEmpty:
                return "选中文字读取失败，模拟复制也没拿到内容。"
            }
        }
    }

    /// 组合读取。走哪条路由设置里的「取词方式」决定：
    /// auto = 先读选区、失败退剪贴板；ax = 只读选区，绝不动剪贴板；clipboard = 直接模拟 ⌘C。
    static func selectedText(allowClipboardFallback: Bool? = nil) -> Result<String, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let mode = Config.shared.selectionMode
        let allowFallback = allowClipboardFallback ?? (mode != "ax")
        if mode == "clipboard" {
            return clipboardSelectedText().map { Result.success($0) } ?? .failure(.clipboardEmpty)
        }

        // 焦点刚切换时 AX 会短暂读空，重试一次
        for attempt in 0..<2 {
            switch readAXSelection() {
            case .success(let text):
                return .success(text)
            case .failure(.noSelection), .failure(.noFocusedApp):
                // -25212 / 无值 都算「这次读不到」，不该直接判死：
                // 还有剪贴板兜底这条路可走。
                break
            case .failure(let other):
                return .failure(other)
            }
            if attempt == 0 { usleep(120_000) }
        }

        if allowFallback, let text = clipboardSelectedText() {
            return .success(text)
        }
        return .failure(allowFallback ? .clipboardEmpty : .noSelection)
    }

    /// 只要结果，不要失败原因的场景用这个。
    static func selectedTextOrNil() -> String? {
        switch selectedText() {
        case .success(let text): return text
        case .failure: return nil
        }
    }

    // MARK: - AX 路径

    /// 只读 AX 选区，绝不碰剪贴板。
    /// 「选中即翻」每 0.35 秒轮询一次，这条路里一旦出现模拟 ⌘C 就会毁掉用户剪贴板。
    static func axSelectedText() -> String? {
        if case .success(let text) = readAXSelection() { return text }
        return nil
    }

    private static func readAXSelection() -> Result<String, Failure> {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppRef: CFTypeRef?
        let s1 = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef)
        guard s1 == .success, let appRef = focusedAppRef else {
            Debug.log("focusedApp status=\(s1.rawValue)")
            return .failure(.noFocusedApp(status: Int(s1.rawValue)))
        }
        let app = appRef as! AXUIElement

        // 路径 1：焦点控件。多数浏览器、Office、终端可用。
        var focusedElementRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
           let element = focusedElementRef,
           let text = selectedText(of: element as! AXUIElement) {
            Debug.log("焦点控件命中")
            return .success(text)
        }

        // 路径 2：有些 App 不暴露 AXFocusedUIElement（比如 TextEdit），
        // 只能从窗口往下找真正带选区的控件。
        var windowRefs: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowRefs) == .success,
           let windows = windowRefs as? [AXUIElement] {
            for window in windows.prefix(3) {
                visited = 0
                if let text = searchSelectedText(in: window, depth: 0) {
                    Debug.log("窗口遍历命中")
                    return .success(text)
                }
            }
        }
        return .failure(.noSelection)
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        var selected: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        guard status == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    private static var visited = 0

    /// 深度优先找带非空选区的控件，限制层数和节点数，避免在大窗口里卡住。
    private static func searchSelectedText(in element: AXUIElement, depth: Int) -> String? {
        guard depth <= 6, visited < 400 else { return nil }
        visited += 1

        if let text = selectedText(of: element) { return text }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else {
            return nil
        }
        for child in kids {
            if let text = searchSelectedText(in: child, depth: depth + 1) {
                return text
            }
        }
        return nil
    }

    // MARK: - 剪贴板回退

    /// 快照剪贴板全部类型的数据，用于事后还原。
    private struct PasteboardSnapshot {
        let items: [[String: Data]]

        static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
            var items: [[String: Data]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var perItem: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        perItem[type.rawValue] = data
                    }
                }
                if !perItem.isEmpty { items.append(perItem) }
            }
            return PasteboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let restored: [NSPasteboardItem] = items.map { dict in
                let newItem = NSPasteboardItem()
                for (type, data) in dict {
                    newItem.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return newItem
            }
            pasteboard.writeObjects(restored)
        }
    }

    /// 回退方案：模拟 Cmd+C 复制，读剪贴板，完事原样还原。
    static func clipboardSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) else {
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // 动态轮询等待：本地 App 15ms 内极速返回，Parallels Desktop 虚拟机与大型 Electron 最长补偿至 750ms
        var copied: String?
        for _ in 0..<50 {
            usleep(15_000)
            if pasteboard.changeCount != changeCountBefore {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        snapshot.restore(to: pasteboard)

        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return copied
    }
}
