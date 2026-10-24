import AppKit

// Both views opt in to window-background dragging so move mode can grab the
// pill anywhere, including on the text itself.
private final class PillView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class PillLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Borderless, always-on-top, click-through panel showing the current line as
/// a rounded dark pill. Anchored on a persisted center point so lines of
/// different width stay visually centered where the user placed it.
final class OverlayWindow {
    var onMoved: ((CGPoint) -> Void)?

    private let panel: NSPanel
    private let pill = PillView()
    private let label: NSTextField
    private var center: CGPoint
    private var moveObserver: NSObjectProtocol?

    private static let hPad: CGFloat = 16
    private static let vPad: CGFloat = 8
    private static let bottomOffset: CGFloat = 120

    init(savedCenter: CGPoint?) {
        center = savedCenter ?? Self.defaultCenter()

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pill.layer?.cornerRadius = 12

        let label = PillLabel(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 4
        label.shadow = shadow
        self.label = label

        pill.addSubview(label)
        panel.contentView = pill
    }

    func setText(_ text: String) {
        guard text != label.stringValue else { return }
        label.stringValue = text
        layoutToFit()
    }

    func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Text size and pill darkness, from Settings; the pill re-fits around
    /// its anchored center so the current line doesn't jump.
    func setStyle(fontSize: CGFloat, opacity: CGFloat) {
        label.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(opacity).cgColor
        layoutToFit()
    }

    /// Back to the default bottom-center spot (persisted like a drag would be).
    func resetPosition() {
        center = Self.defaultCenter()
        onMoved?(center)
        layoutToFit()
    }

    /// Debug (`--snapshot-pill`): render the pill to a PNG with transparency.
    func snapshot(to path: String) {
        guard let rep = pill.bitmapImageRepForCachingDisplay(in: pill.bounds) else { return }
        pill.cacheDisplay(in: pill.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    /// While move mode is on, the panel accepts mouse drags and the controller
    /// stops pushing line updates, so every didMove is a user drag.
    func setMoveMode(_ enabled: Bool) {
        if enabled {
            panel.ignoresMouseEvents = false
            panel.isMovableByWindowBackground = true
            pill.layer?.borderWidth = 2
            pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            if label.stringValue.isEmpty {
                setText("♫ drag me ♫")
            }
            show()
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let frame = self.panel.frame
                self.center = CGPoint(x: frame.midX, y: frame.midY)
                self.onMoved?(self.center)
            }
        } else {
            if let moveObserver {
                NotificationCenter.default.removeObserver(moveObserver)
                self.moveObserver = nil
            }
            panel.ignoresMouseEvents = true
            panel.isMovableByWindowBackground = false
            pill.layer?.borderWidth = 0
        }
    }

    private func layoutToFit() {
        guard let screen = targetScreen() else { return }
        let visible = screen.visibleFrame
        // Size from the cell's own metric: NSAttributedString.size() (and even
        // intrinsicContentSize) come up a few px short of what the cell needs,
        // and any shortfall makes byTruncatingTail ellipsize every line.
        let unbounded = NSRect(x: 0, y: 0, width: 100_000, height: 1000)
        var textSize = label.cell?.cellSize(forBounds: unbounded)
            ?? label.attributedStringValue.size()
        textSize.width = min(ceil(textSize.width) + 1, visible.width * 0.8 - 2 * Self.hPad)
        textSize.height = ceil(textSize.height)

        let size = NSSize(width: textSize.width + 2 * Self.hPad,
                          height: textSize.height + 2 * Self.vPad)
        label.frame = NSRect(x: Self.hPad, y: Self.vPad,
                             width: textSize.width, height: textSize.height)

        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        // Clamp so a stale/off-screen saved position is pulled back on-screen.
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The screen holding the saved center — falls back to the main screen so
    /// an unplugged monitor cannot strand the overlay off-screen.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func defaultCenter() -> CGPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return CGPoint(x: 800, y: 200)
        }
        let visible = screen.visibleFrame
        return CGPoint(x: visible.midX, y: visible.minY + bottomOffset)
    }
}
