import AppKit

/// 并排对照窗口：几个服务同时翻同一段文字，译法差异一眼可见。
///
/// 没做进卡片里，是因为卡片布局已经验收过（自动高度、工具栏、提示条都靠它），
/// 把它改成多列会连带影响那些行为。对照属于「偶尔看一次」的场景，独立窗口更稳。
final class CompareWindow: NSObject, NSWindowDelegate {

    static let shared = CompareWindow()

    private var window: NSWindow?
    private var scroll: NSScrollView?
    private var sourceLabel: NSTextField?

    private override init() {}

    struct Column {
        var title: String
        var text: String
        /// 失败时整列标红
        var failed: Bool = false
    }

    func show(source: String, columns: [Column]) {
        DispatchQueue.main.async {
            self.ensureWindow()
            self.render(source: source, columns: columns)
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "对照"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.minSize = NSSize(width: 520, height: 360)

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel = label

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = NSView()
        self.scroll = scroll

        let container = NSView()
        container.addSubview(label)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        window.contentView = container
        self.window = window
    }

    /// 每列：标题 + 译文。列宽自适应内容，最少 260。
    private func render(source: String, columns: [Column]) {
        sourceLabel?.stringValue = "原文：" + source.replacingOccurrences(of: "\n", with: " ")

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let size = CGFloat(Config.shared.fontSize)
        for column in columns {
            let title = NSTextField(labelWithString: column.title)
            title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            title.textColor = column.failed ? .systemRed : .secondaryLabelColor
            title.lineBreakMode = .byTruncatingTail

            let text = NSTextView()
            text.isEditable = false
            text.isRichText = true
            text.textContainerInset = NSSize(width: 6, height: 6)
            if column.failed {
                text.string = column.text
                text.font = NSFont.systemFont(ofSize: size - 1)
                text.textColor = .systemRed
            } else if Config.shared.renderMarkdown {
                text.textStorage?.setAttributedString(
                    MarkdownLite.attributed(column.text, fontSize: size,
                                            color: .labelColor, secondaryColor: .secondaryLabelColor))
            } else {
                text.string = column.text
                text.font = NSFont.systemFont(ofSize: size)
            }

            let scroll = NSScrollView()
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 380).isActive = true

            let stack = NSStackView(views: [title, scroll])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            row.addArrangedSubview(stack)
        }

        let doc = NSView()
        doc.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            row.topAnchor.constraint(equalTo: doc.topAnchor),
            row.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll?.documentView = doc
    }

    // MARK: - 自测入口

    func columnCountForTesting() -> Int {
        guard let doc = scroll?.documentView else { return 0 }
        var count = 0
        func walk(_ v: NSView) {
            if v is NSTextView { count += 1 }
            for sub in v.subviews { walk(sub) }
        }
        walk(doc)
        return count
    }

    func visibleTextSnapshot() -> [String] {
        guard let content = window?.contentView else { return [] }
        var bag: [String] = [window?.title ?? ""]
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, !f.stringValue.isEmpty { bag.append(f.stringValue) }
            if let t = v as? NSTextView, !t.string.isEmpty { bag.append(t.string) }
            for sub in v.subviews { walk(sub) }
        }
        walk(content)
        return bag
    }
}
