import AppKit

/// 一闪而过的小药丸提示。静默翻译不弹卡片，总得给用户一个反馈，
/// 否则按了快捷键屏幕毫无反应，只会让人以为程序坏了。
enum HUD {

    private static var window: NSWindow?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, seconds: TimeInterval = 1.8) {
        DispatchQueue.main.async {
            let label = NSTextField(labelWithString: message)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.sizeToFit()

            let padding: CGFloat = 12
            let width = max(120, label.frame.width + padding * 2)
            let height = label.frame.height + 14

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .statusBar
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

            let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            content.wantsLayer = true
            content.layer?.cornerRadius = height / 2
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor

            label.frame.origin = NSPoint(x: (width - label.frame.width) / 2, y: (height - label.frame.height) / 2)
            content.addSubview(label)
            window.contentView = content

            // 放屏幕中下方，不挡视线也不容易被忽略
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let origin = NSPoint(
                    x: visible.midX - width / 2,
                    y: visible.minY + visible.height * 0.12
                )
                window.setFrameOrigin(origin)
            }

            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }

            hideWork?.cancel()
            let work = DispatchWorkItem {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    window.animator().alphaValue = 0
                }, completionHandler: {
                    window.orderOut(nil)
                })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
            self.window = window
        }
    }
}
