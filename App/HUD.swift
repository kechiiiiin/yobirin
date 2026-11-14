import AppKit

/// 一瞬だけ出す小さな通知
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, duration: TimeInterval = 1.6) {
        let text = message.isEmpty ? "完了" : message
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        let size = label.intrinsicContentSize
        let width = min(max(size.width + 40, 160), 600)
        let height: CGFloat = 40

        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        label.frame = NSRect(x: 20, y: (height - size.height) / 2, width: width - 40, height: size.height)
        effect.addSubview(label)
        p.contentView = effect

        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: vf.midX - width / 2, y: vf.minY + vf.height * 0.18, width: width, height: height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
