import AppKit
import SlideScrollCore

/// The outline around the focused window, and the row of app icons shown
/// for a moment while moving along the strip. Like the tab bars, the engine
/// hands over plain data from its own queue; panels are only touched on the
/// main thread.
enum Overlays {
    /// The focused window and where it is now, in Accessibility coordinates.
    struct Border: Equatable {
        let window: CGWindowID
        let frame: Rect
    }

    /// One column in the strip indicator: the window it shows.
    struct Column: Equatable {
        let window: CGWindowID
        let pid: pid_t
        let focused: Bool
    }

    struct Indicator: Equatable {
        let columns: [Column]
        /// The display's usable area, in Accessibility coordinates.
        let viewport: Rect
    }

    private static let border = Latest<Border?> { applyBorder($0) }
    private static let strip = Latest<Indicator> { applyStrip($0) }

    /// Outline this window, or none. Callable from any thread.
    static func showBorder(_ b: Border?) { border.send(b) }

    /// Show the strip indicator for a moment. Callable from any thread.
    static func showStrip(_ s: Indicator) { strip.send(s) }

    private static let lock = NSLock()
    /// Where the indicator is while it's on screen, in Accessibility coordinates.
    private static var indicatorFrame: Rect?

    /// The indicator is on screen at this point. Callable from any thread.
    static func indicatorCovers(_ p: CGPoint) -> Bool {
        guard let r = lock.withLock({ indicatorFrame }) else { return false }
        return Double(p.x) >= r.x && Double(p.x) < r.x + r.w && Double(p.y) >= r.y && Double(p.y) < r.y + r.h
    }

    // MARK: - Focus border

    private static var borderPanel: NSPanel?
    private static var borderWindow: CGWindowID?

    private static func applyBorder(_ b: Border?) {
        guard let b, let frame = TabBars.appKitFrame(b.frame) else {
            borderPanel?.orderOut(nil)
            borderWindow = nil
            return
        }
        let rect = frame.insetBy(dx: -BorderView.width, dy: -BorderView.width)
        let panel = borderPanel ?? {
            let panel = TabBars.makePanel(rect)
            panel.ignoresMouseEvents = true
            panel.contentView = BorderView(frame: NSRect(origin: .zero, size: rect.size))
            panel.contentView?.autoresizingMask = [.width, .height]
            borderPanel = panel
            return panel
        }()
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        // In front of the windows it sits between; the focused window, and
        // any pins, are raised above it as focus lands.
        if borderWindow != b.window || !panel.isVisible {
            borderWindow = b.window
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Strip indicator

    /// How long the indicator stays after the last move, in seconds.
    private static let linger = 1.0
    private static var stripPanel: NSPanel?
    private static var stripView: IndicatorView?
    private static var hideTimer: Timer?

    private static func applyStrip(_ s: Indicator) {
        guard s.columns.count > 1 else { return hide() }
        let vp = s.viewport
        let size = IndicatorView.size(for: s.columns.count, maxWidth: vp.w - 80)
        let (w, h) = (Double(size.width), Double(size.height))
        let r = Rect(x: vp.x + (vp.w - w) / 2, y: vp.y + vp.h - h - 24, w: w, h: h)
        guard let frame = TabBars.appKitFrame(r) else { return }
        lock.withLock { indicatorFrame = r }
        if let panel = stripPanel {
            panel.setFrame(frame, display: false)
        } else {
            let panel = TabBars.makePanel(frame)
            // Above the windows, which move underneath it.
            panel.level = .floating
            let glass = TabBars.makeGlass(frame.size, material: .hudWindow)
            glass.autoresizingMask = [.width, .height]
            let view = IndicatorView(frame: NSRect(origin: .zero, size: frame.size))
            view.autoresizingMask = [.width, .height]
            view.hovering = { inside in inside ? keep() : hideLater() }
            glass.addSubview(view)
            panel.contentView = glass
            stripPanel = panel
            stripView = view
        }
        stripView?.columns = s.columns
        stripPanel?.alphaValue = 1
        stripPanel?.orderFrontRegardless()
        if stripView?.inside != true { hideLater() }
    }

    /// The pointer is over the indicator: keep it, even if it had begun to fade.
    private static func keep() {
        hideTimer?.invalidate()
        guard let panel = stripPanel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
    }

    private static func hideLater() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: linger, repeats: false) { _ in hide() }
    }

    private static func hide() {
        hideTimer?.invalidate()
        guard let panel = stripPanel, panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Shown again while fading out: leave it.
            if panel.alphaValue == 0 {
                panel.orderOut(nil)
                lock.withLock { indicatorFrame = nil }
            }
        })
    }
}

/// Hands the latest value to the main thread. Only the latest matters, so a
/// busy main thread skips values instead of falling behind.
private final class Latest<T> {
    private let lock = NSLock()
    private var latest: T?
    private var queued = false
    private let apply: (T) -> Void

    init(_ apply: @escaping (T) -> Void) { self.apply = apply }

    func send(_ value: T) {
        let alreadyQueued = lock.withLock { () -> Bool in
            defer { latest = value; queued = true }
            return queued
        }
        guard !alreadyQueued else { return }
        DispatchQueue.main.async { [self] in
            let value = lock.withLock { () -> T in
                queued = false
                return latest!
            }
            apply(value)
        }
    }
}

/// An accent-coloured ring just outside the window, rounded like its corners.
private final class BorderView: NSView {
    static let width = 3.0
    private static let windowRadius: Double = { if #available(macOS 26, *) { 16 } else { 10 } }()

    override func draw(_ dirtyRect: NSRect) {
        let w = BorderView.width
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: w / 2, dy: w / 2),
                                xRadius: BorderView.windowRadius + w / 2, yRadius: BorderView.windowRadius + w / 2)
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = w
        path.stroke()
    }
}

/// App icons in strip order, the focused column's on a highlight. Clicking
/// one focuses its window; while the pointer is over it, it stays.
private final class IndicatorView: NSView {
    private static let icon = 40.0, spacing = 8.0, padding = 10.0

    /// Width and height for `n` icons, shrinking them to fit `maxWidth`.
    static func size(for n: Int, maxWidth: Double) -> NSSize {
        let full = Double(n) * (icon + spacing) - spacing + 2 * padding
        let scale = min(1, maxWidth / full)
        return NSSize(width: full * scale, height: (icon + 2 * padding) * scale)
    }

    var columns: [Overlays.Column] = [] { didSet { if columns != oldValue { needsDisplay = true } } }
    var hovering: ((Bool) -> Void)?
    private(set) var inside = false
    private var icons: [pid_t: NSImage] = [:]

    private var scale: Double { Double(bounds.height) / (IndicatorView.icon + 2 * IndicatorView.padding) }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { inside = true; hovering?(true) }
    override func mouseExited(with event: NSEvent) { inside = false; hovering?(false) }

    private func slot(_ i: Int) -> NSRect {
        let s = scale
        return NSRect(x: (IndicatorView.padding + Double(i) * (IndicatorView.icon + IndicatorView.spacing)) * s,
                      y: IndicatorView.padding * s, width: IndicatorView.icon * s, height: IndicatorView.icon * s)
    }

    /// Taken, so the click is ours; it counts when the button comes up.
    override func mouseDown(with event: NSEvent) {}

    /// Anywhere on the indicator picks the icon in that column, gaps and
    /// padding included. On release, like a button: the strip scrolling
    /// while the button is still down would look like the user dragging
    /// the focused window, and drop it somewhere.
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !columns.isEmpty, bounds.contains(p) else { return }
        let x = Double(p.x) / scale - IndicatorView.padding + IndicatorView.spacing / 2
        let i = min(max(Int(x / (IndicatorView.icon + IndicatorView.spacing)), 0), columns.count - 1)
        Engine.shared?.send(.focusWindow(columns[i].window))
    }

    override func draw(_ dirtyRect: NSRect) {
        // macOS passes clicks on fully transparent pixels to the window
        // below, and the glass behind counts as transparent. A wash too
        // faint to see keeps every click on the indicator.
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()
        for (i, c) in columns.enumerated() {
            let r = slot(i)
            if c.focused {
                NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
                let h = r.insetBy(dx: -5 * scale, dy: -5 * scale)
                NSBezierPath(roundedRect: h, xRadius: 9 * scale, yRadius: 9 * scale).fill()
            }
            // This view is flipped; the icon must not be.
            image(c.pid)?.draw(in: r, from: .zero, operation: .sourceOver, fraction: c.focused ? 1 : 0.75,
                               respectFlipped: true, hints: nil)
        }
    }

    private func image(_ pid: pid_t) -> NSImage? {
        if let i = icons[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = i
        return i
    }
}
