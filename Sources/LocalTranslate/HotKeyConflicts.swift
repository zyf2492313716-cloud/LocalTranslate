import Foundation

/// 快捷键冲突提示。
///
/// 说清楚能做到什么：macOS **没有公开 API** 能查「这个组合键被谁注册了」。
/// `RegisterEventHotKey` 只会告诉我「我自己注册失败」，不会告诉我「微信占了 ⌥D」。
///
/// 所以这里做两件真能做的事：
/// 1. 和系统已知保留组合比对（保存前就能看出会打不过）
/// 2. 报告自己注册的结果（失败会在权限页列出来）
///
/// 这不是真占用检测，只是白名单。界面上也不该说成检测。
enum HotKeyConflicts {

    /// 系统固定占用、抢不过的组合
    static let reserved: [(combo: String, why: String)] = [
        ("cmd+space", "聚焦搜索"),
        ("cmd+tab", "切换应用"),
        ("cmd+shift+3", "全屏截图"),
        ("cmd+shift+4", "区域截图"),
        ("cmd+shift+5", "截图工具栏"),
        ("cmd+option+esc", "强制退出"),
        ("cmd+control+q", "锁屏"),
        ("cmd+shift+q", "注销"),
        ("cmd+grave", "同应用窗口切换"),
    ]

    /// 返回这个组合撞上的系统快捷键说明，没撞返回 nil
    static func warning(for combo: String) -> String? {
        let normalized = normalize(combo)
        guard let hit = reserved.first(where: { normalize($0.combo) == normalized }) else { return nil }
        return "这个组合被系统占用（\(hit.why)），很可能按了没反应"
    }

    /// 大小写、别名、修饰键顺序统一，避免同一个组合两种写法比不出来
    static func normalize(_ combo: String) -> String {
        let parts = combo.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
            .map { token -> String in
                switch token {
                case "command", "cmd", "meta": return "cmd"
                case "option", "alt", "opt": return "option"
                case "control", "ctrl": return "ctrl"
                case "shift": return "shift"
                case "`": return "grave"
                default: return token
                }
            }
        // 修饰键排序一致，否则 shift+cmd+x 和 cmd+shift+x 不等
        let order = ["ctrl", "option", "shift", "cmd"]
        let modifiers = parts.filter { order.contains($0) }.sorted {
            (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0)
        }
        let keys = parts.filter { !order.contains($0) }
        return (modifiers + keys).joined(separator: "+")
    }

    /// 当前所有快捷键里，哪些撞了系统
    static func currentWarnings(_ combos: [(label: String, combo: String)]) -> [String] {
        combos.compactMap { item in
            guard let why = warning(for: item.combo) else { return nil }
            return "\(item.label) \(item.combo)：\(why)"
        }
    }
}
