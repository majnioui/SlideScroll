import AppKit
import SlideScrollCore

/// A connected display, in the top-left-origin coordinates the Accessibility API uses.
struct Display: Equatable {
    /// CGDirectDisplayID: stable for a given monitor while it stays connected.
    var id: CGDirectDisplayID
    /// The whole display.
    var frame: Rect
    /// The part windows can use: minus the menu bar and the Dock.
    var visible: Rect

    func contains(_ x: Double, _ y: Double) -> Bool {
        x >= frame.x && x < frame.x + frame.w && y >= frame.y && y < frame.y + frame.h
    }

    /// Every display, left to right (then top to bottom). Main thread only.
    static func all() -> [Display] {
        let screens = NSScreen.screens
        // The first screen is the one with the menu bar; its bottom-left corner
        // is the origin of AppKit's coordinates and its top-left that of ours.
        guard let primaryH = screens.first?.frame.height else { return [] }
        let flip = { (r: NSRect) in Rect(x: r.minX, y: primaryH - r.maxY, w: r.width, h: r.height) }
        return screens
            .map { Display(id: $0.displayID, frame: flip($0.frame), visible: flip($0.visibleFrame)) }
            .sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Area where two rectangles overlap.
func overlap(_ a: Rect, _ b: Rect) -> Double {
    let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
    let h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
    return max(w, 0) * max(h, 0)
}

/// The part of `a` inside `b`, if any.
func intersect(_ a: Rect, _ b: Rect) -> Rect? {
    let x = max(a.x, b.x)
    let y = max(a.y, b.y)
    let w = min(a.x + a.w, b.x + b.w) - x
    let h = min(a.y + a.h, b.y + b.h) - y
    return w >= 1 && h >= 1 ? Rect(x: x, y: y, w: w, h: h) : nil
}
