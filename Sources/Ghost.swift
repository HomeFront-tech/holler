import AppKit

private final class GhostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class Ghost {
    private let panel = GhostPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(wrappingLabelWithString: "")
    private var target = CaretTarget(pid: 0)
    private var bubble = false
    private var pulse: Timer?
    private var revision = 0
    init() {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        label.isSelectable = false; label.maximumNumberOfLines = 0
        panel.contentView?.wantsLayer = true
        panel.contentView?.addSubview(label)
    }
    func show(at target: CaretTarget, forceBubble: Bool = false) {
        revision += 1; self.target = target; bubble = forceBubble || target.caret == nil
        panel.alphaValue = 1; update("")
        panel.orderFrontRegardless()
        pulse?.invalidate()
        pulse = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            guard let self else { return }
            let text = NSMutableAttributedString(attributedString: self.label.attributedStringValue)
            if text.length > 0 {
                let range = NSRange(location: text.length - 1, length: 1)
                let old = text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? NSColor
                let alpha: CGFloat = (old?.alphaComponent ?? 1) > 0.5 ? 0.3 : 0.9
                text.addAttribute(.foregroundColor, value: (self.label.textColor ?? .gray).withAlphaComponent(alpha), range: range)
                self.label.attributedStringValue = text
            }
        }
    }
    func update(_ text: String) {
        let anchor = target.caret.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? target.frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let line = target.caret?.height ?? 20
        let font = NSFont.systemFont(ofSize: bubble ? 14 : min(26, max(11, line * 0.78)))
        let x = bubble ? (target.frame?.minX ?? visible.midX - 200) : (target.caret?.minX ?? visible.midX)
        let maxWidth = bubble ? 420.0 : max(120, min(600, (target.frame?.maxX ?? visible.maxX) - x))
        label.font = font
        label.textColor = bubble ? NSColor.white.withAlphaComponent(0.72) : NSColor.labelColor.withAlphaComponent(0.45)
        label.stringValue = text.isEmpty ? "●" : text + "  ●"
        let rect = (label.stringValue as NSString).boundingRect(with: NSSize(width: maxWidth - 20, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let width = min(maxWidth, max(40, ceil(rect.width) + 20)), height = max(line, ceil(rect.height)) + (bubble ? 16 : 4)
        let top = bubble ? (target.frame?.minY ?? visible.minY + 110) - 6 : (target.caret?.midY ?? visible.midY) + line / 2
        let frame = CGRect(x: min(max(x, visible.minX), visible.maxX - width), y: max(visible.minY, top - height), width: width, height: height)
        panel.setFrame(frame, display: true)
        panel.contentView?.layer?.backgroundColor = bubble ? NSColor.black.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
        panel.contentView?.layer?.cornerRadius = bubble ? 10 : 0
        label.frame = CGRect(x: bubble ? 10 : 0, y: bubble ? 8 : 2, width: width - (bubble ? 20 : 0), height: height - (bubble ? 16 : 4))
    }
    func hide(fade: Bool = false) {
        revision += 1; let rev = revision
        pulse?.invalidate(); pulse = nil; label.alphaValue = 1
        if fade {
            NSAnimationContext.runAnimationGroup({ context in context.duration = 0.15; self.panel.animator().alphaValue = 0 }) {
                if self.revision == rev { self.panel.orderOut(nil) }
            }
        } else { panel.orderOut(nil) }
    }
    func failed(at target: CaretTarget) {
        show(at: target, forceBubble: true); pulse?.invalidate(); pulse = nil
        update("Couldn't type here. Cmd+Ctrl+V pastes it.")
        let rev = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.revision == rev { self.hide() } }
    }
}
