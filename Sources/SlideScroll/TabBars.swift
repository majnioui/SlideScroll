import AppKit
import SlideScrollCore

/// Height of a tab bar, not counting the gap below it.
let tabBarHeight = 28.0
private let radius = 8.0
/// Space between the bar's edge and the highlighted tab.
private let inset = 3.0
private let fontSize = 12.0

/// One tabbed column's bar, as the engine wants it on screen.
struct TabBar: Equatable {
    struct Tab: Equatable {
        let window: CGWindowID
        let title: String
        init(_ pair: (CGWindowID, String)) { (window, title) = pair }
    }

    /// Identifies the column from one update to the next: its first window.
    var key: CGWindowID
    /// The visible part of the bar, in Accessibility (top-left origin) coordinates.
    var frame: Rect
    /// How far into the bar the visible part starts, when it's cut off on the left.
    var offset: Double
    /// Width of the whole bar, cut off or not.
    var fullWidth: Double
    var tabs: [Tab]
    var active: Int
}

/// The tab bars over tabbed columns and the highlight where a dragged window
/// would be stacked. The engine hands over plain data from its own queue;
/// the panels are only touched on the main thread.
enum TabBars {
    private static let lock = NSLock()
    /// Bars waiting to be applied. Only the latest set matters, so a busy
    /// main thread skips frames instead of falling behind.
    private static var pending: [TabBar]?
    private static var shown: [CGWindowID: (panel: NSPanel, glass: NSVisualEffectView, view: TabBarView)] = [:]
    private static var hint: NSPanel?

    /// Show exactly these tab bars. Callable from any thread.
    static func show(_ bars: [TabBar]) {
        let alreadyQueued = lock.withLock { () -> Bool in
            defer { pending = bars }
            return pending != nil
        }
        guard !alreadyQueued else { return }
        DispatchQueue.main.async {
            if let bars = lock.withLock({ () -> [TabBar]? in defer { pending = nil }; return pending }) {
                apply(bars)
            }
        }
    }

    /// Highlight where a dragged window will land, or hide the highlight.
    /// Callable from any thread.
    static func showDropHint(_ rect: Rect?) {
        DispatchQueue.main.async { applyDropHint(rect) }
    }

    /// AppKit's bottom-left-origin frame for an Accessibility (top-left-origin) rect.
    static func appKitFrame(_ r: Rect) -> NSRect? {
        guard let primaryH = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: r.x, y: primaryH - r.y - r.h, width: r.w, height: r.h)
    }

    /// A borderless, transparent, non-activating panel: clicking it must not
    /// take focus away from the window the user is working in.
    static func makePanel(_ rect: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Panels hide when their app is inactive, and this app never is active.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        return panel
    }

    /// Frosted glass like a menu's, rounded. It always looks active: this app
    /// never is, and inactive glass would look grey.
    static func makeGlass(_ size: NSSize, material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = material
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = radius
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        return glass
    }

    /// Round only the bar's real ends: where it's cut off, it carries on out of sight.
    private static func roundEnds(_ glass: NSVisualEffectView, cutLeft: Bool, cutRight: Bool) {
        var corners: CACornerMask = []
        if !cutLeft { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if !cutRight { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        if glass.layer?.maskedCorners != corners { glass.layer?.maskedCorners = corners }
    }

    private static func apply(_ bars: [TabBar]) {
        let keys = Set(bars.map(\.key))
        for (key, bar) in shown where !keys.contains(key) {
            bar.panel.orderOut(nil)
            shown[key] = nil
        }
        for b in bars {
            guard let rect = appKitFrame(b.frame) else { continue }
            let (cutLeft, cutRight) = (b.offset > 0.5, b.offset + b.frame.w < b.fullWidth - 0.5)
            if let bar = shown[b.key] {
                if bar.panel.frame != rect { bar.panel.setFrame(rect, display: false) }
                roundEnds(bar.glass, cutLeft: cutLeft, cutRight: cutRight)
                bar.view.update(b)
            } else {
                let panel = makePanel(rect)
                let glass = makeGlass(rect.size, material: .menu)
                let view = TabBarView(frame: NSRect(origin: .zero, size: rect.size), bar: b)
                view.autoresizingMask = [.width, .height]
                glass.addSubview(view)
                panel.contentView = glass
                roundEnds(glass, cutLeft: cutLeft, cutRight: cutRight)
                panel.orderFrontRegardless()
                shown[b.key] = (panel, glass, view)
            }
        }
    }

    private static func applyDropHint(_ rect: Rect?) {
        guard let rect, let frame = appKitFrame(rect) else {
            hint?.orderOut(nil)
            return
        }
        let panel = hint ?? {
            let panel = makePanel(frame)
            // Above the window being dragged, and invisible to the mouse so
            // the drag carries on underneath it.
            panel.level = .floating
            panel.ignoresMouseEvents = true
            let glass = makeGlass(frame.size, material: .hudWindow)
            let view = DropHintView(frame: NSRect(origin: .zero, size: frame.size))
            view.autoresizingMask = [.width, .height]
            glass.addSubview(view)
            panel.contentView = glass
            hint = panel
            return panel
        }()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

/// A rounded outline over the glass, with one tab per window; the active tab
/// is filled with the accent colour. Colours are the system's, so it follows
/// dark mode. Clicking a tab focuses its window.
private final class TabBarView: NSView {
    private var bar: TabBar

    init(frame: NSRect, bar: TabBar) {
        self.bar = bar
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The first click on an inactive app's window counts as a click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tabWidth: Double { bar.fullWidth / Double(max(bar.tabs.count, 1)) }

    func update(_ new: TabBar) {
        // Same content, so no need to redraw: the frame is the panel's business.
        let changed = new.tabs != bar.tabs || new.active != bar.active || new.offset != bar.offset
            || new.fullWidth != bar.fullWidth
        bar = new
        if changed { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard !bar.tabs.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        let i = min(Int(max((p.x + bar.offset) / tabWidth, 0)), bar.tabs.count - 1)
        Engine.shared?.send(.focusWindow(bar.tabs[i].window))
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let x0 = -bar.offset
        let tabW = tabWidth

        let outline = NSBezierPath(roundedRect: NSRect(x: x0 + 0.5, y: 0.5, width: bar.fullWidth - 1, height: h - 1),
                                   xRadius: radius, yRadius: radius)
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let font = NSFont.systemFont(ofSize: fontSize)
        let lineH = font.ascender - font.descender
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail

        for (i, tab) in bar.tabs.enumerated() {
            let active = i == bar.active
            let r = NSRect(x: x0 + Double(i) * tabW + inset, y: inset, width: tabW - 2 * inset, height: h - 2 * inset)
            if active {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: radius - inset, yRadius: radius - inset).fill()
            } else if i > 0 && i - 1 != bar.active {
                // A divider between two inactive tabs.
                NSColor.separatorColor.setFill()
                NSRect(x: r.minX - inset - 0.5, y: h * 0.3, width: 1, height: h * 0.4).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: active ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ]
            let text = NSRect(x: r.minX + 6, y: r.minY + (r.height - lineH) / 2, width: r.width - 12, height: lineH)
            (tab.title as NSString).draw(in: text, withAttributes: attrs)
        }
    }
}

/// A rounded rectangle tinted with the accent colour over frosted glass,
/// like macOS's own tiling preview.
private final class DropHintView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
