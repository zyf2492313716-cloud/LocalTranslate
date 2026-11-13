import Foundation

/// Bob 插件里的 `$option` 用户配置。
///
/// 插件在 info.json 里声明 options（text / menu / switch），Bob 会把它们渲染成设置项。
/// 我们之前只注入 defaultValue，等于所有需要填 Key 的插件都用不了。
/// 这里用 UserDefaults 存「插件目录名 → [选项 id: 值]」，注入时覆盖默认值。
enum PluginOptions {

    private static let key = "pluginOptions"
    private static let lock = NSLock()

    static func all() -> [String: [String: String]] {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
    }

    static func values(for plugin: String) -> [String: String] {
        all()[plugin] ?? [:]
    }

    static func set(_ value: String, for option: String, plugin: String) {
        lock.lock(); defer { lock.unlock() }
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
        var entry = map[plugin] ?? [:]
        if value.isEmpty { entry.removeValue(forKey: option) } else { entry[option] = value }
        if entry.isEmpty { map.removeValue(forKey: plugin) } else { map[plugin] = entry }
        UserDefaults.standard.set(map, forKey: key)
    }

    /// 读 info.json 里的选项声明，给设置界面用
    struct Declaration {
        var identifier: String
        var title: String
        var type: String        // text / menu / switch
        var defaultValue: String
        var menuTitles: [String]
        var menuValues: [String]
        var isSecret: Bool
        var note: String
    }

    static func declarations(plugin: String) -> [Declaration] {
        let infoURL = PluginRuntime.directory
            .appendingPathComponent(plugin)
            .appendingPathComponent("info.json")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = object["options"] as? [[String: Any]] else { return [] }

        return options.compactMap { opt in
            guard let id = opt["identifier"] as? String else { return nil }
            let type = (opt["type"] as? String) ?? "text"
            var titles: [String] = []
            var values: [String] = []
            if let menu = opt["menuValues"] as? [[String: Any]] {
                for item in menu {
                    titles.append((item["title"] as? String) ?? "")
                    values.append((item["value"] as? String) ?? "")
                }
            }
            let textConfig = opt["textConfig"] as? [String: Any]
            return Declaration(
                identifier: id,
                title: (opt["title"] as? String) ?? id,
                type: type,
                defaultValue: String(describing: opt["defaultValue"] ?? ""),
                menuTitles: titles,
                menuValues: values,
                isSecret: (textConfig?["type"] as? String) == "secure",
                note: (opt["desc"] as? String) ?? ""
            )
        }
    }
}
