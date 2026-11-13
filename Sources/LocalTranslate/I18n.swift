import Foundation

/// 界面多语言本地化（支持简体中文、繁体中文、英文，对齐 Bob 1.15.0）。
enum I18n {

    enum Language: String, CaseIterable {
        case system = "system"
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case en = "en"

        var title: String {
            switch self {
            case .system: return "跟随系统 (Auto)"
            case .zhHans: return "简体中文"
            case .zhHant: return "繁體中文"
            case .en: return "English"
            }
        }
    }

    /// 当前有效语言代码
    static var currentLanguage: Language {
        let configured = Config.shared.uiLanguage
        if let explicit = Language(rawValue: configured), explicit != .system {
            return explicit
        }
        let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
            return .zhHant
        } else if preferred.hasPrefix("zh") {
            return .zhHans
        } else {
            return .en
        }
    }

    private static let strings: [String: [Language: String]] = [
        "app.name": [.zhHans: "LocalTranslate", .zhHant: "LocalTranslate", .en: "LocalTranslate"],
        "menu.translate": [.zhHans: "翻译选中内容", .zhHant: "翻譯選中內容", .en: "Translate Selection"],
        "menu.dictionary": [.zhHans: "词典…", .zhHant: "詞典…", .en: "Dictionary…"],
        "menu.favorites": [.zhHans: "收藏夹…", .zhHant: "收藏夾…", .en: "Favorites…"],
        "menu.history": [.zhHans: "翻译历史", .zhHant: "翻譯歷史", .en: "Translation History"],
        "menu.settings": [.zhHans: "设置…", .zhHant: "設定…", .en: "Settings…"],
        "menu.screenshot": [.zhHans: "截图翻译…", .zhHant: "截圖翻譯…", .en: "Screenshot Translate…"],
        "menu.silentOcr": [.zhHans: "静默截图 OCR", .zhHant: "靜默截圖 OCR", .en: "Silent Screenshot OCR"],
        "menu.input": [.zhHans: "输入翻译…", .zhHant: "輸入翻譯…", .en: "Input Translate…"],
        "menu.compare": [.zhHans: "对照视图…", .zhHant: "對照視圖…", .en: "Comparison View…"],
        "menu.exportLog": [.zhHans: "导出日志…", .zhHant: "導出日誌…", .en: "Export Log…"],
        "menu.quit": [.zhHans: "退出", .zhHant: "退出", .en: "Quit"],
        "card.copied": [.zhHans: "已复制", .zhHant: "已複製", .en: "Copied"],
        "card.favorited": [.zhHans: "已收藏", .zhHant: "已收藏", .en: "Favorited"],
        "card.unfavorited": [.zhHans: "已取消收藏", .zhHant: "已取消收藏", .en: "Unfavorited"],
        "card.pinned": [.zhHans: "已钉住", .zhHant: "已釘住", .en: "Pinned"],
        "card.unpinned": [.zhHans: "已取消钉住", .zhHant: "已取消釘住", .en: "Unpinned"],
        "lang.auto": [.zhHans: "自动检测", .zhHant: "自動檢測", .en: "Auto Detect"],
        "lang.source": [.zhHans: "源语言", .zhHant: "來源語言", .en: "Source Language"],
        "lang.target": [.zhHans: "目标语言", .zhHant: "目標語言", .en: "Target Language"],
    ]

    static func t(_ key: String, lang: Language? = nil) -> String {
        let active = lang ?? currentLanguage
        if let dict = strings[key], let val = dict[active] {
            return val
        }
        // 回退到简体中文或 key 本身
        return strings[key]?[.zhHans] ?? key
    }
}
