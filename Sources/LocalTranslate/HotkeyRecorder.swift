import AppKit
import Carbon.HIToolbox

/// 点击后按下组合键来录入快捷键。
///
/// Bob 的快捷键页就是这种录入框。原来让用户手打 "cmd+shift+x" 字符串，
/// 打错了、用了系统保留组合，界面都不给反馈，等于把出错推给用户。
final class HotkeyRecorder: NSView {

    var onChange: ((String) -> Void)?

    /// 与其它录制框冲突时要能提示，所以把全部已占用组合交给外部判断
    var isConflict: ((String) -> Bool)?

    private let label = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "点击后按下新组合键")
    private var recording = false
    private var monitor: Any?
    private var combo: String

    init(combo: String) {
        self.combo = combo
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 22))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            heightAnchor.constraint(equalToConstant: 22),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startRecording()
    }

    func setCombo(_ value: String, notify: Bool = false) {
        combo = value
        render()
        if notify { onChange?(value) }
    }

    var currentCombo: String { combo }

    // MARK: - 录入

    private func startRecording() {
        guard !recording else { return }
        recording = true
        hintLabel.isHidden = false
        label.isHidden = true
        hintLabel.stringValue = "请按下组合键…（esc 取消）"
        layer?.borderColor = NSColor.controlAccentColor.cgColor

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            return self.handle(event)
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {         // esc 取消
            stopRecording()
            render()
            return nil
        }
        guard event.type == .keyDown else { return nil }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 必须有修饰键，否则会把普通打字抢走
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else {
            flashHint("至少要带上 ⌘ / ⌥ / ⌃ 其中一个")
            return nil
        }
        guard let pressed = HotkeyRecorder.comboString(event: event, modifiers: modifiers) else {
            flashHint("这个键还不支持，换一个")
            return nil
        }

        if (isConflict?(pressed)) ?? false {
            flashHint("这个组合已经被另一个快捷键占用了")
            return nil
        }

        combo = pressed
        stopRecording()
        onChange?(pressed)
        render()
        return nil
    }

    private var hintRestore: DispatchWorkItem?

    private func flashHint(_ text: String) {
        hintLabel.isHidden = false
        label.isHidden = true
        hintLabel.stringValue = text
        hintRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recording else { return }
            self.hintLabel.stringValue = "点击后按下新组合键"
        }
        hintRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func render() {
        hintLabel.isHidden = true
        label.isHidden = false
        label.stringValue = combo.isEmpty ? "未设置" : HotKeyManager.displayString(combo)
        label.textColor = combo.isEmpty ? .tertiaryLabelColor : .labelColor
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// 事件 → "cmd+shift+x"
    static func comboString(event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        guard let key = keyName(event.keyCode) else { return nil }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// keyCode → 我们解析表认识的键名
    static func keyName(_ code: UInt16) -> String? {
        switch Int(code) {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "o"
        case 32: return "u"
        case 33: return "["
        case 34: return "i"
        case 35: return "p"
        case 37: return "l"
        case 38: return "j"
        case 39: return "'"
        case 40: return "k"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "n"
        case 46: return "m"
        case 47: return "."
        case 49: return "space"
        case 50: return "`"
        case 36: return "return"
        case 48: return "tab"
        case 51: return "delete"
        case 53: return "esc"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return nil
        }
    }
}
