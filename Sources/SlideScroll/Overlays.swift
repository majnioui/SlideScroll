import AppKit
import SlideScrollCore

/// The row of app icons shown for a moment while moving along the strip.
/// Like the tab bars, the engine hands over plain data from its own queue;
/// panels are only touched on the main thread.
enum Overlays {
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

    private static let strip = Latest<Indicator> { applyStrip($0) }

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

    // MARK: - Strip indicator

    /// How long the indicator stays after the last move, in seconds.
    private static let linger = 1.0
    private static var stripPanel: NSPanel?
    private static var stripView: IndicatorView?
    /// What the indicator shows now, to skip updates that change nothing.
    private static var shownStrip: Indicator?
    /// The indicator is on screen. Kept here because asking the window
    /// (`isVisible`) waits for a round trip to the window server.
    private static var showing = false
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
            // Already showing just this: only its time on screen starts over.
            if s == shownStrip && showing && panel.alphaValue == 1 {
                if stripView?.inside != true { hideLater() }
                return
            }
            if panel.frame != frame { panel.setFrame(frame, display: false) }
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
        shownStrip = s
        stripView?.columns = s.columns
        if let panel = stripPanel, !showing || panel.alphaValue < 1 {
            // Stops a fade-out under way, too.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.orderFrontRegardless()
            showing = true
        }
        if stripView?.inside != true { hideLater() }
    }

    /// The pointer is over the indicator: keep it, even if it had begun to fade.
    private static func keep() {
        hideTimer?.invalidate()
        guard let panel = stripPanel, showing else { return }
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
        guard let panel = stripPanel, showing else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Shown again while fading out: leave it.
            if panel.alphaValue == 0 {
                panel.orderOut(nil)
                showing = false
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

    /// The app's icon, scaled once to the size it's drawn at. Scaling the
    /// full-size icon on every redraw cost more than the rest of a shortcut.
    private func image(_ pid: pid_t) -> NSImage? {
        if let i = icons[pid] { return i }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        let side = Int(IndicatorView.icon * (window?.backingScaleFactor ?? 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: NSSize(width: IndicatorView.icon, height: IndicatorView.icon))
        small.addRepresentation(rep)
        icons[pid] = small
        return small
    }
}
