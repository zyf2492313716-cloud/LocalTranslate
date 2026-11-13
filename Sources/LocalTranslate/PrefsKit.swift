import AppKit

/// 偏好窗里反复用到的表单构造器。九个面板共用一套，样式才统一。
enum PrefsKit {

    static let rowGap: CGFloat = 10
    static let labelWidth: CGFloat = 132

    /// 分区标题（小一号、次要色），和 Bob 的分组标题一致
    static func sectionTitle(_ text: String, note: String? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        let title = NSTextField(labelWithString: text)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)

        if let note {
            let hint = NSTextField(wrappingLabelWithString: note)
            hint.font = NSFont.systemFont(ofSize: 11)
            hint.textColor = .tertiaryLabelColor
            hint.isSelectable = false
            stack.addArrangedSubview(hint)
        }
        return stack
    }

    /// 一行：左标签右控件。控件被撑满剩余宽度，和 Bob 的表单一致。
    static func row(_ label: String, _ control: NSView, note: String? = nil, indent: CGFloat = 0) -> NSView {
        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.alignment = .right
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [titleLabel, control])
        line.orientation = .horizontal
        line.spacing = 10
        line.alignment = .firstBaseline

        guard let note else { return inset(line, indent) }

        let hint = NSTextField(wrappingLabelWithString: note)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.isSelectable = false

        let stack = NSStackView(views: [line, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return inset(stack, indent)
    }

    private static func inset(_ view: NSView, _ amount: CGFloat) -> NSView {
        guard amount > 0 else { return view }
        let wrapper = NSStackView()
        wrapper.orientation = .horizontal
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: amount).isActive = true
        wrapper.addArrangedSubview(spacer)
        wrapper.addArrangedSubview(view)
        wrapper.addArrangedSubview(NSView())
        return wrapper
    }

    /// 开关一行：文字在左，开关紧跟其后，说明再往下
    static func toggleRow(_ title: String, isOn: Bool, note: String? = nil,
                          target: AnyObject, action: Selector) -> (NSView, NSButton) {
        let check = NSButton(checkboxWithTitle: title, target: target, action: action)
        check.state = isOn ? .on : .off
        check.controlSize = .regular

        guard let note else { return (check, check) }

        let hint = NSTextField(wrappingLabelWithString: note)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.isSelectable = false

        let stack = NSStackView(views: [check, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return (stack, check)
    }

    /// 一行右对齐的按钮组
    static func buttonRow(_ buttons: [NSButton], trailing: Bool = true) -> NSView {
        let stack = NSStackView(views: trailing ? buttons + [NSView()] : [NSView()] + buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    /// 圆角卡片容器，用来框住一组设置（Bob 的每组设置都有个底）
    static func card(_ views: [NSView], spacing: CGFloat = 12, inset: CGFloat = 14) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
        ])
        return box
    }

    static func pushButton(_ title: String, target: AnyObject, _ action: Selector,
                           emphasized: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        if emphasized { button.keyEquivalent = "\r" }
        return button
    }

    static func textControl(_ value: String, placeholder: String = "", secure: Bool = false) -> NSControl {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.stringValue = value
        field.placeholderString = placeholder
        field.isEditable = true
        field.isSelectable = true
        field.font = NSFont.systemFont(ofSize: 12)
        field.controlSize = .small
        // 给个下限，别让短值把输入框缩没了
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return field
    }

    static func popup(_ items: [String], selected: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: items)
        if items.indices.contains(selected) { popup.selectItem(at: selected) }
        popup.controlSize = .small
        return popup
    }

    /// 状态圆点 + 文案，给权限页用
    static func statusLine(symbol: String, color: NSColor, text: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.isSelectable = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        return stack
    }
}
