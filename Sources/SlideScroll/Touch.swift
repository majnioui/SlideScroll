import Foundation

/// Horizontal swipes from the private MultitouchSupport framework, which
/// reports raw finger positions for every trackpad at ~100 Hz. Loaded with
/// dlopen, as private frameworks aren't in the SDK.
enum Touch {
    private static let framework = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    /// Horizontal travel (as a fraction of trackpad width) before a swipe is recognised.
    private static let startThreshold = 0.015

    // Settings, read on the trackpad's own thread.
    private static let lock = NSLock()
    private static var _fingers = 4
    private static var _natural = true

    /// Fingers for a swipe, 3 or 4.
    static var fingers: Int {
        get { lock.withLock { _fingers } }
        set { lock.withLock { _fingers = newValue } }
    }

    /// Off, the strip moves against the fingers instead of with them.
    static var natural: Bool {
        get { lock.withLock { _natural } }
        set { lock.withLock { _natural = newValue } }
    }

    private struct Gesture {
        /// Average finger position and timestamp from the previous frame.
        var prev: (x: Double, y: Double, t: Double)?
        /// Movement before the swipe direction is decided.
        var pending = (x: 0.0, y: 0.0)
        var swiping = false
        /// Smoothed horizontal speed in trackpad widths per second.
        var velocity = 0.0
    }

    /// Gesture state per trackpad (built-in and Magic Trackpad can both be present).
    private static var gestures: [UnsafeMutableRawPointer: Gesture] = [:]

    // One finger, as the framework reports it: 96 bytes, of which only the
    // normalised position (two floats at offset 32) matters here.
    private static let fingerSize = 96
    private static let positionOffset = 32

    private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

    private static let onFrame: ContactCallback = { device, fingers, count, timestamp, _ in
        guard let device else { return 0 }
        Touch.lock.lock()
        defer { Touch.lock.unlock() }
        var g = Touch.gestures[device] ?? Gesture()
        defer { Touch.gestures[device] = g }

        guard Int(count) == Touch._fingers, let fingers else {
            if g.swiping { Engine.shared?.send(.swipeEnd(g.velocity)) }
            g = Gesture()
            return 0
        }
        var x = 0.0, y = 0.0
        for i in 0..<Int(count) {
            let base = fingers.advanced(by: i * Touch.fingerSize + Touch.positionOffset)
            x += Double(base.loadUnaligned(as: Float.self))
            y += Double(base.loadUnaligned(fromByteOffset: 4, as: Float.self))
        }
        x /= Double(count)
        y /= Double(count)

        if let prev = g.prev {
            let sign = Touch._natural ? 1.0 : -1.0
            let (dx, dy) = (sign * (x - prev.x), y - prev.y)
            if g.swiping {
                Engine.shared?.send(.swipe(dx))
                let dt = max(timestamp - prev.t, 1e-3)
                g.velocity = 0.7 * g.velocity + 0.3 * (dx / dt)
            } else {
                g.pending.x += dx
                g.pending.y += dy
                let (ax, ay) = (abs(g.pending.x), abs(g.pending.y))
                if ax > Touch.startThreshold && ax > 2 * ay {
                    g.swiping = true
                    Engine.shared?.send(.swipe(g.pending.x))
                }
            }
        }
        g.prev = (x, y, timestamp)
        return 0
    }

    /// Start listening on every trackpad. Fails softly: swipes are optional.
    /// Returns the number of trackpads.
    static func install() throws -> Int {
        guard let lib = dlopen(framework, RTLD_NOW) else { throw ConfigProblem("MultitouchSupport framework not found") }
        guard let createList = dlsym(lib, "MTDeviceCreateList"),
              let register = dlsym(lib, "MTRegisterContactFrameCallback"),
              let start = dlsym(lib, "MTDeviceStart") else { throw ConfigProblem("MultitouchSupport symbols missing") }
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        // The list and its devices are intentionally never released: they must
        // stay alive for callbacks to keep coming.
        guard let devices = unsafeBitCast(createList, to: CreateList.self)()?.takeRetainedValue() else { return 0 }
        let n = CFArrayGetCount(devices)
        for i in 0..<n {
            guard let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(devices, i)) else { continue }
            unsafeBitCast(register, to: Register.self)(dev, onFrame)
            unsafeBitCast(start, to: Start.self)(dev, 0)
        }
        retained = devices
        return n
    }

    private static var retained: CFArray?

    /// Built-in trackpad and Magic Trackpad keep separate copies of their settings.
    private static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    /// Three Finger Drag, which turns three-finger swipes into window drags.
    static var threeFingerDragOn: Bool {
        trackpadDomains.contains { (pref(domain: $0, key: "TrackpadThreeFingerDrag") ?? 0) != 0 }
    }

    /// The macOS trackpad gesture that also uses `fingers`-finger horizontal
    /// swipes, if any, as it's named in System Settings.
    static func macosConflict(_ fingers: Int) -> String? {
        for domain in trackpadDomains {
            let three = pref(domain: domain, key: "TrackpadThreeFingerHorizSwipeGesture") ?? 0
            let four = pref(domain: domain, key: "TrackpadFourFingerHorizSwipeGesture") ?? 0
            if let c = gestureConflict(fingers: fingers, three: three, four: four) { return c }
        }
        return nil
    }

    /// What the two horizontal-swipe preferences mean for `fingers`. The
    /// three-finger one is 1 for Swipe between pages and 2 for Swipe between
    /// full-screen apps on three fingers; the four-finger one is 2 for
    /// full-screen apps on four fingers.
    ///
    /// For a four-finger strip, full-screen apps on either count conflict: macOS
    /// leaves the four-finger value at 2 when the user picks three fingers and
    /// keeps acting on it, and a fast four-finger swipe lands as three fingers
    /// first, which the three-finger gesture takes.
    static func gestureConflict(fingers: Int, three: Int, four: Int) -> String? {
        switch fingers {
        case 3 where three == 2: return "Swipe between full-screen applications"
        case 3 where three != 0: return "Swipe between pages"
        case 4 where four == 2 || three == 2: return "Swipe between full-screen applications"
        default: return nil
        }
    }
}

/// A number or boolean from another app's preferences, as `defaults read` shows it.
/// Read fresh: macOS caches another app's preferences in this process, so
/// without syncing first a setting the user just changed would read as before.
func pref(domain: String, key: String) -> Int? {
    CFPreferencesAppSynchronize(domain as CFString)
    let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    if let b = v as? Bool { return b ? 1 : 0 }
    return (v as? NSNumber)?.intValue
}
