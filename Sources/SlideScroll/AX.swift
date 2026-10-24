import AppKit
import ApplicationServices

// Wrappers over the Accessibility API for finding, moving and focusing other
// apps' windows. Every call goes through `AXUIElement`, which is thread-safe:
// the engine and the per-app movers call it from their own threads.

/// The CGWindowID behind a window element. Private, but stable for a decade
/// and used by yabai, AeroSpace, Rectangle and others.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The IDs of the windows matching `option`, without their descriptions.
/// Swift marks it unavailable, but it's public CoreGraphics API.
@_silgen_name("CGWindowListCreate")
private func _CGWindowListCreate(_ option: CGWindowListOption, _ relativeTo: CGWindowID) -> Unmanaged<CFArray>?

enum AX {
    /// Messaging timeout per AX call. Unresponsive apps would otherwise stall us for 6s.
    static let timeout: Float = 0.25

    /// Make every Accessibility call give up after `timeout`. Set on the
    /// system-wide element, this applies to all elements, including the window
    /// elements apps hand back, which don't inherit their app's own timeout.
    static func setGlobalTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }

    /// Ask macOS whether we're trusted for Accessibility, showing the system prompt if not.
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }

    /// Run `body` with the app's AXEnhancedUserInterface off, if it was on, and
    /// turn it back on afterwards. Apps with it on (Chrome and Electron apps
    /// while a screen reader runs) animate every move themselves, which fights
    /// our animation, but switching it off for good would break their
    /// accessibility for the screen reader.
    @discardableResult
    static func withoutEnhancedUI<R>(_ pid: pid_t, _ body: () -> R) -> R {
        let on = enhancedUI(pid)
        if on { setEnhancedUI(pid, false) }
        defer { if on { setEnhancedUI(pid, true) } }
        return body()
    }

    static func enhancedUI(_ pid: pid_t) -> Bool {
        app(pid).bool("AXEnhancedUserInterface")
    }

    static func setEnhancedUI(_ pid: pid_t, _ on: Bool) {
        AXUIElementSetAttributeValue(app(pid), "AXEnhancedUserInterface" as CFString, on as CFBoolean)
    }

    /// The app's display name, e.g. "Terminal".
    static func appName(_ pid: pid_t) -> String? {
        app(pid).string(kAXTitleAttribute)
    }

    /// The window an app considers focused. Asking the app directly is more
    /// reliable than the system-wide query, which often fails on recent macOS.
    static func focusedWindow(of pid: pid_t) -> CGWindowID? {
        app(pid).element(kAXFocusedWindowAttribute)?.windowID
    }

    /// Whether the app is the active (frontmost) one.
    static func isFrontmost(_ pid: pid_t) -> Bool {
        app(pid).bool(kAXFrontmostAttribute)
    }

    /// ID of the window that currently has keyboard focus, if any.
    static func focusedWindowID() -> CGWindowID? {
        let system = AXUIElementCreateSystemWide()
        if let id = system.element(kAXFocusedApplicationAttribute)?.element(kAXFocusedWindowAttribute)?.windowID {
            return id
        }
        // The system-wide query often fails on recent macOS. Ask the active app
        // instead, looking for it in front-to-back window order so it's usually
        // the first one asked. An active app with no windows has no focused one.
        var asked = Set<pid_t>()
        for (_, pid) in onScreenWindows() where asked.insert(pid).inserted {
            if isFrontmost(pid) { return focusedWindow(of: pid) }
        }
        return nil
    }

    /// The process is still there. Signal 0 only checks; EPERM means it
    /// exists but belongs to someone else.
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// IDs and owner PIDs of normal (layer 0) windows currently visible on screen.
    static func onScreenWindows() -> [(CGWindowID, pid_t)] {
        let ownPid = getpid()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid else { return nil }
            return (id, pid)
        }
    }

    /// PIDs of apps that own at least one normal window on screen.
    static func onScreenPIDs() -> [pid_t] {
        Array(Set(onScreenWindows().map(\.1))).sorted()
    }

    /// IDs of the windows on screen on the current Space. Only the IDs, which is
    /// much cheaper than the full window descriptions: it's called mid-swipe.
    static func onScreenIDs() -> Set<CGWindowID> {
        guard let list = _CGWindowListCreate([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)?
            .takeRetainedValue() else { return [] }
        // The array's values are the window IDs themselves, not objects.
        return Set((0..<CFArrayGetCount(list)).map { CGWindowID(UInt(bitPattern: CFArrayGetValueAtIndex(list, $0))) })
    }

    struct Listing {
        /// Standard windows on screen on the current Space.
        var windows: [Window] = []
        /// Apps that didn't answer: their windows are unknown, not gone.
        var unanswered: [pid_t] = []
        /// Known windows that still exist but are on another Space.
        var elsewhere: [CGWindowID] = []
    }

    /// Standard windows of one app, or nil if the app didn't answer (busy
    /// apps time out, and that must not be mistaken for their windows closing).
    /// With `only` set, keep just those window IDs; known windows filtered out
    /// that way but not minimised are on another Space and go in `elsewhere`.
    /// Windows in `known` skip the standard-window check, so a timeout on that
    /// call can't drop them either.
    static func appWindows(_ pid: pid_t, only: Set<CGWindowID>?, known: Set<CGWindowID>,
                           elsewhere: inout [CGWindowID]) -> [Window]? {
        let app = app(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return nil }
        var out: [Window] = []
        // Asked at most once: a hidden app's windows aren't on another Space.
        var hidden: Bool?
        for el in elements {
            guard let id = el.windowID else { continue }
            if let only, !only.contains(id) {
                if known.contains(id) && !el.bool(kAXMinimizedAttribute) {
                    if hidden == nil { hidden = app.bool(kAXHiddenAttribute) }
                    if hidden == false { elsewhere.append(id) }
                }
                continue
            }
            if known.contains(id) || el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole {
                out.append(Window(id: id, pid: pid, element: el))
            }
        }
        return out
    }

    /// List windows. `knownPIDs` are also asked even if none of their windows
    /// is on screen, so known windows on another Space are noticed, not lost.
    static func listWindows(known: Set<CGWindowID>, knownPIDs: [pid_t]) -> Listing {
        let onScreen = onScreenWindows()
        let ids = Set(onScreen.map(\.0))
        let pids = Set(onScreen.map(\.1)).union(knownPIDs).sorted()
        var listing = Listing()
        for pid in pids {
            if let w = appWindows(pid, only: ids, known: known, elsewhere: &listing.elsewhere) {
                listing.windows += w
            } else if isRunning(pid) {
                listing.unanswered.append(pid)
            }
            // An app that quit fails the same way as a slow one, but its
            // windows are gone for good.
        }
        return listing
    }

    /// Whether the left mouse button is held, i.e. the user is dragging or resizing.
    static var mouseDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    /// Where the mouse pointer is, in global top-left-origin coordinates.
    static var mouseLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

extension AXUIElement {
    func value(_ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attr as CFString, &out) == .success ? out : nil
    }

    func element(_ attr: String) -> AXUIElement? {
        guard let v = value(attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func bool(_ attr: String) -> Bool {
        (value(attr) as? Bool) ?? false
    }

    func string(_ attr: String) -> String? {
        value(attr) as? String
    }

    func setBool(_ attr: String, _ on: Bool) {
        AXUIElementSetAttributeValue(self, attr as CFString, on as CFBoolean)
    }

    /// Window ID behind a window element, e.g. one handed to an AXObserver callback.
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    /// PID of the app an element belongs to.
    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }
}

/// Another app's window, by its CGWindowID, its app and its AX element.
struct Window {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement

    private func point(_ attr: String) -> CGPoint? {
        guard let v = element.value(attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    var position: CGPoint? { point(kAXPositionAttribute) }

    var size: CGSize? {
        guard let v = element.value(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Fixed-size windows (e.g. some utility panels) can't join the strip.
    var isResizable: Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    @discardableResult
    func setPosition(_ x: Double, _ y: Double) -> Bool {
        var p = CGPoint(x: x, y: y)
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    func setSize(_ w: Double, _ h: Double) -> Bool {
        var s = CGSize(width: w, height: h)
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    var title: String? { element.string(kAXTitleAttribute) }

    /// Bring the window above others without making its app frontmost.
    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Raise the window and make its app frontmost so it gets keyboard focus.
    func focus() {
        AX.app(pid).setBool(kAXFrontmostAttribute, true)
        element.setBool(kAXMainAttribute, true)
        raise()
    }
}
