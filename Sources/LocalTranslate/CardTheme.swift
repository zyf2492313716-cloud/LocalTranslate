import AppKit

/// 卡片的尺寸、颜色、字体和图标按钮的统一出处。
/// 颜色一律用语义色，明暗主题自动跟随系统，不写死数值。
enum CardTheme {
    static let cornerRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10
    /// 卡片左右外边距（Bob 的窗口留白较大）
    static let hPadOuter: CGFloat = 14
    /// 卡片内部各块之间的垂直间距
    static let vGap: CGFloat = 8
    static let hPadding: CGFloat = 20
    static let toolbarHeight: CGFloat = 34
    static let dividerHeight: CGFloat = 1
    static let hintBarHeight: CGFloat = 30
    static let hintBarWidthInset: CGFloat = 12
    static let minCardWidth: CGFloat = 440
    static let maxCardWidth: CGFloat = 660
    static let minBodyHeight: CGFloat = 44
    static let maxBodyHeight: CGFloat = 460

    static let sourceFont = NSFont.systemFont(ofSize: 15)
    static let resultFont = NSFont.systemFont(ofSize: 15)

    /// 字号由设置里的滑块决定，别写死
    static func sourceFont(withSize size: Double) -> NSFont { NSFont.systemFont(ofSize: CGFloat(size)) }
    static func resultFont(withSize size: Double) -> NSFont { NSFont.systemFont(ofSize: CGFloat(size)) }
    static let metaFont = NSFont.systemFont(ofSize: 11)
    static let hintFont = NSFont.systemFont(ofSize: 11)

    static var text: NSColor { .labelColor }
    static var secondary: NSColor { .secondaryLabelColor }
    static var tertiary: NSColor { .tertiaryLabelColor }
    static var cardBackground: NSColor { .windowBackgroundColor }
    static var sectionBackground: NSColor {
        NSColor.windowBackgroundColor.blended(withFraction: 0.035, of: .labelColor) ?? .controlBackgroundColor
    }
    static var cardBorder: NSColor {
        NSColor.separatorColor.withAlphaComponent(0.45)
    }
    static var hintBarBackground: NSColor {
        NSColor.windowBackgroundColor.blended(withFraction: 0.06, of: .labelColor) ?? .underPageBackgroundColor
    }
    static var separator: NSColor { .separatorColor }
    static var accent: NSColor { .controlAccentColor }

    /// 服务卡片左上角的小品牌图标（对齐 Bob 每家服务带自己 logo 的做法）。
    /// 用系统符号近似品牌色，不引入任何图片资源。
    static func serviceBadge(for modelID: String, name: String) -> NSView {
        let lower = name.lowercased()
        let symbol: String
        let tint: NSColor
        if lower.contains("apple") {
            symbol = "apple.logo"
            tint = .labelColor
        } else if lower.contains("google") || lower.contains("谷歌") {
            symbol = "globe"
            tint = .systemBlue
        } else if lower.contains("mymemory") {
            symbol = "character.bubble"
            tint = .systemTeal
        } else if lower.contains("deepseek") {
            symbol = "water.waves"
            tint = .systemIndigo
        } else if lower.contains("openai") || lower.contains("gpt") {
            symbol = "sparkles"
            tint = .systemGreen
        } else if lower.contains("火山") || lower.contains("volc") {
            symbol = "flame"
            tint = .systemOrange
        } else if lower.contains("deepl") {
            symbol = "character.book.closed"
            tint = .systemPurple
        } else if lower.contains("百度") || lower.contains("baidu") {
            symbol = "pawprint"
            tint = .systemRed
        } else if lower.contains("有道") || lower.contains("youdao") {
            symbol = "y.circle"
            tint = .systemRed
        } else if lower.contains("腾讯") || lower.contains("tencent") {
            symbol = "cloud"
            tint = .systemBlue
        } else {
            symbol = "globe.asia.australia"
            tint = .secondaryLabelColor
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        let view = NSImageView()
        view.image = image
        view.contentTintColor = tint
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 14),
            view.heightAnchor.constraint(equalToConstant: 14),
        ])
        return view
    }

    /// 工具条图标按钮
    static func iconButton(_ symbol: String, help: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.image?.isTemplate = true
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.toolTip = help
        button.target = target
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        return button
    }

    /// 量一段 attributed string 在给定宽度下要多高。
    /// 走真实的 NSTextStorage/NSLayoutManager 排版，不用系数估。
    static func measure(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 1 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return ceil(max(used, 1))
    }
}

extension NSColor {
    /// 把一个颜色和另一个按比例混合，语义色在深浅模式下都能用
    func blended(withFraction fraction: CGFloat, of other: NSColor) -> NSColor? {
        guard let from = usingColorSpace(.deviceRGB),
              let to = other.usingColorSpace(.deviceRGB) else { return nil }
        let r = from.redComponent + (to.redComponent - from.redComponent) * fraction
        let g = from.greenComponent + (to.greenComponent - from.greenComponent) * fraction
        let b = from.blueComponent + (to.blueComponent - from.blueComponent) * fraction
        let a = from.alphaComponent + (to.alphaComponent - from.alphaComponent) * fraction
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }
}
