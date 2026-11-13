import AppKit
import Carbon.HIToolbox

/// 全局快捷键，用 Carbon 的 RegisterEventHotKey 实现，不需要辅助功能权限。
///
/// 两个坑：
/// 1. 事件处理器只装一次并全程复用。Carbon 拿的是 C 函数指针，反复装卸容易留下悬空引用。
/// 2. 每个热键的 id 必须递增。Carbon 用 (signature, id) 唯一标识热键，
///    复用同一个 id 重新注册会返回 eventHotKeyExists(-9878)，热键会悄悄失效。
final class HotKeyManager {

    static let shared = HotKeyManager()

    /// 支持多个互不相同的全局快捷键
    enum Kind: UInt32, CaseIterable {
        case translate = 1
        case silent = 2
        case input = 3
        case screenshot = 4
        case dictionary = 5
        case silentReplace = 9
        case inputBoxReplace = 10
        case clipboard = 6
        case speak = 7
        case toggleIcons = 8
        case silentScreenshotOcr = 11
        case finderImageOcr = 12
    }

    private static let signature: OSType = 0x4C54_4B59  // 'LTKY'

    private var refs: [Kind: EventHotKeyRef] = [:]
    private var idByKind: [Kind: UInt32] = [:]
    private var eventHandler: EventHandlerRef?
    private var handlerInstalled = false
    private var nextHotKeyID: UInt32 = 100

    private(set) var registered: [Kind: String] = [:]

    /// 快捷键触发回调
    var onTrigger: ((Kind) -> Void)?

    private init() {}

    @discardableResult
    func register(_ combo: String, kind: Kind) -> Bool {
        unregisterHotKey(kind)
        guard let parsed = HotKeyManager.parse(combo) else { return false }

        installHandlerIfNeeded()
        guard handlerInstalled else { return false }

        nextHotKeyID += 1
        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: nextHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Debug.log("热键 \(combo) 注册返回 \(status)")
            return false
        }
        idByKind[kind] = nextHotKeyID
        refs[kind] = ref
        registered[kind] = combo
        return true
    }

    private func unregisterHotKey(_ kind: Kind) {
        if let ref = refs[kind] {
            UnregisterEventHotKey(ref)
            refs[kind] = nil
            idByKind[kind] = nil
            registered[kind] = nil
        }
    }

    func unregister() {
        for kind in Kind.allCases { unregisterHotKey(kind) }
    }

    // MARK: - 事件处理器

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let getStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard getStatus == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                let manager = HotKeyManager.shared
                guard let kind = manager.kind(forID: id) else { return }
                Debug.log("热键命中 kind=\(kind)")
                manager.onTrigger?(kind)
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        handlerInstalled = (status == noErr && eventHandler != nil)
    }

    private func kind(forID id: UInt32) -> Kind? {
        idByKind.first { $0.value == id }?.key
    }

    // MARK: - 解析

    struct ParsedCombo {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// 把 "cmd+shift+x" 解析成 keyCode + modifiers
    static func parse(_ combo: String) -> ParsedCombo? {
        let parts = combo.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyPart = parts.last else { return nil }

        var modifiers: UInt32 = 0
        var keyCode: UInt32? = nil

        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super", "meta": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "fn", "function": break   // fn 不参与 Carbon 注册
            default: break
            }
        }

        // 至少要有一个修饰键，否则会抢走普通按键
        if modifiers == 0 { return nil }

        switch keyPart {
        case "a": keyCode = 0
        case "s": keyCode = 1
        case "d": keyCode = 2
        case "f": keyCode = 3
        case "h": keyCode = 4
        case "g": keyCode = 5
        case "z": keyCode = 6
        case "x": keyCode = 7
        case "c": keyCode = 8
        case "v": keyCode = 9
        case "b": keyCode = 11
        case "q": keyCode = 12
        case "w": keyCode = 13
        case "e": keyCode = 14
        case "r": keyCode = 15
        case "y": keyCode = 16
        case "t": keyCode = 17
        case "1": keyCode = 18
        case "2": keyCode = 19
        case "3": keyCode = 20
        case "4": keyCode = 21
        case "6": keyCode = 22
        case "5": keyCode = 23
        case "=": keyCode = 24
        case "9": keyCode = 25
        case "7": keyCode = 26
        case "-": keyCode = 27
        case "8": keyCode = 28
        case "0": keyCode = 29
        case "]": keyCode = 30
        case "o": keyCode = 31
        case "u": keyCode = 32
        case "[": keyCode = 33
        case "i": keyCode = 34
        case "p": keyCode = 35
        case "l": keyCode = 37
        case "j": keyCode = 38
        case "'": keyCode = 39
        case "k": keyCode = 40
        case ";": keyCode = 41
        case "\\": keyCode = 42
        case ",": keyCode = 43
        case "/": keyCode = 44
        case "n": keyCode = 45
        case "m": keyCode = 46
        case ".": keyCode = 47
        case "`": keyCode = 50
        case "space": keyCode = 49
        case "enter", "return": keyCode = 36
        case "tab": keyCode = 48
        case "delete", "backspace": keyCode = 51
        case "esc", "escape": keyCode = 53
        case "left": keyCode = 123
        case "right": keyCode = 124
        case "down": keyCode = 125
        case "up": keyCode = 126
        default: return nil
        }

        guard let keyCode else { return nil }
        return ParsedCombo(keyCode: keyCode, modifiers: modifiers)
    }

    /// 供 UI 显示：把 "cmd+shift+x" 显示成 "⇧⌘X"
    static func displayString(_ combo: String) -> String {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let keyPart = parts.last else { return combo }
        var symbols = ""
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super", "meta": symbols += "⌘"
            case "shift": symbols += "⇧"
            case "opt", "option", "alt": symbols += "⌥"
            case "ctrl", "control": symbols += "⌃"
            case "fn": symbols += "fn"
            default: break
            }
        }
        return symbols + keyPart.uppercased()
    }
}
