import Foundation

/// 快捷键默认值与迁移。
///
/// 为什么要改：Bob 官方 FAQ 明确说 macOS 15/26 的「Option + 字母」快捷键会
/// **偶发失效**，是系统 bug，软件修不了只能规避——建议改用带 Control 或 Command 的组合。
/// 我早期把默认全设成了 ⌥ 系（还误以为「撞对了 Bob 键位」），正好踩在这个 bug 上。
///
/// 迁移只动「纯 Option、没带 Control/Command」的旧值，用户自己显式设过的
/// 带 Control/Command 的组合不碰。
enum HotkeyDefaults {

    /// key → 新默认组合（都用 Control+Shift+字母，避开系统占用）
    static let table: [(key: String, combo: String)] = [
        ("hotkey", "control+shift+d"),                        // 划词翻译
        ("silentHotkey", "control+shift+z"),                  // 静默翻译并复制
        ("inputHotkey", "control+shift+a"),                   // 输入翻译
        ("screenshotHotkey", "control+shift+s"),              // 截图翻译
        ("dictionaryHotkey", "control+shift+k"),              // 词典
        ("clipboardHotkey", "control+shift+c"),               // 剪贴板翻译
        ("speakHotkey", "control+shift+r"),                   // 朗读
        ("toggleIconsHotkey", "control+shift+h"),             // 显示/隐藏图标
        ("silentScreenshotOcrHotkey", "control+shift+o"),     // 静默截图 OCR
        ("silentReplaceHotkey", "control+shift+e"),           // 静默划词替换
        ("inputBoxReplaceHotkey", "control+shift+w"),         // 静默输入框替换
    ]

    static func fallback(for key: String) -> String {
        table.first { $0.key == key }?.combo ?? "control+shift+d"
    }

    /// 一次性迁移：把存量的「纯 Option」组合换成新的 Control 系默认。
    /// 返回改动的条数，给日志和自测用。
    @discardableResult
    static func migrate(_ defaults: UserDefaults = .standard) -> Int {
        var changed = 0
        for (key, combo) in table {
            guard let stored = defaults.string(forKey: key), !stored.isEmpty else { continue }
            let norm = HotKeyConflicts.normalize(stored)
            // normalize 把 control 归一成 ctrl、command 归一成 cmd，这里按归一后的 token 判断
            let hasOption = norm.contains("option")
            let hasSafe = norm.contains("ctrl") || norm.contains("cmd")
            // 只有「用了 Option 且没用 Control/Command」的才迁
            if hasOption && !hasSafe {
                defaults.set(combo, forKey: key)
                changed += 1
            }
        }
        if changed > 0 {
            defaults.set(true, forKey: "hotkeysMigratedFromOption")
            Debug.log("快捷键迁移：\(changed) 个纯 ⌥ 组合改成 ⌃ 系（规避 macOS Option 失效）")
        }
        return changed
    }
}

/// 系统版本与 Option 快捷键风险。
enum SystemHotkeyRisk {
    /// macOS 版本号（主.次）
    static var version: (major: Int, minor: Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion)
    }

    /// 一句话风险提示；nil 表示这个系统没这个问题。
    static var optionWarning: String? {
        let (major, minor) = version
        if major < 15 { return nil }
        // 15.0 / 15.1：Option 快捷键被系统整体禁用，本 App 的 ⌥ 组合会完全失灵
        if major == 15 && minor <= 1 {
            return "当前 macOS \(major).\(minor) 会整体禁用「Option + 字母」快捷键。本 App 已默认改用 ⌃ 组合；若你手动设了 ⌥ 键，请升级系统或改回 ⌃/⌘。"
        }
        // 15.2+ 与 26.x：偶发失效
        return "macOS \(major) 上「Option + 字母」快捷键会偶发失效（系统 bug）。本 App 默认已用 ⌃⇧ 组合规避；别把快捷键设成纯 ⌥。"
    }
}
