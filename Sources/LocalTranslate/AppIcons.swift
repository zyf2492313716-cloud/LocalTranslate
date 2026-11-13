import AppKit

/// 菜单栏图标与 Dock 图标开关。
///
/// 有一条硬规则：**不能两个都关**。关掉菜单栏图标之后如果连 Dock 也没有，
/// 这个 App 就彻底没有入口了——快捷键还能用，但用户没法打开设置去改回来。
/// 所以 resolve 会在两者都关时强制把 Dock 打开，界面层再给一句说明。
enum AppIcons {

    struct Settings: Equatable {
        var menuBar: Bool
        var dock: Bool
    }

    /// 纯逻辑：把用户的意愿修正成一个安全的组合
    static func resolve(menuBar: Bool, dock: Bool) -> Settings {
        if menuBar || dock { return Settings(menuBar: menuBar, dock: dock) }
        // 两个都想关 → 保留 Dock，至少还有个能点的地方
        return Settings(menuBar: false, dock: true)
    }

    /// 真正应用，返回修正后生效的组合
    @discardableResult
    static func apply(menuBar: Bool, dock: Bool, statusItem: NSStatusItem?) -> Settings {
        let effective = resolve(menuBar: menuBar, dock: dock)
        NSApp.setActivationPolicy(effective.dock ? .regular : .accessory)
        statusItem?.isVisible = effective.menuBar
        Debug.log("图标：菜单栏=\(effective.menuBar) Dock=\(effective.dock)")
        return effective
    }

    /// 从设置读
    static var current: Settings {
        let config = Config.shared
        return resolve(menuBar: config.showMenuBarIcon, dock: config.showDockIcon)
    }
}