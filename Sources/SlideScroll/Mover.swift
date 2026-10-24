import CoreGraphics
import Foundation

/// Applies window positions and sizes on one serial queue per app.
///
/// Each Accessibility call blocks until the target app answers, and some apps
/// (Electron, Chrome, Xcode) take several milliseconds. Doing every move from
/// the engine would let the slowest app set the frame rate for every window.
/// Instead the engine posts the latest position, and each app's queue applies
/// it when it can: a slow app skips frames, everything else stays smooth.
/// Resizes go the same way, and each one reports back the size the app
/// actually took as `Command.resized`.
final class Mover {
    /// Longest `flush` waits for an app that's slow to take its last move.
    private static let flushTimeout: DispatchTimeInterval = .seconds(1)
    /// How often an app's queue asks it whether AXEnhancedUserInterface is on.
    /// Asking every frame would double the calls a slow app has to answer.
    private static let enhancedUICheck: TimeInterval = 1
    /// In verbose mode, batches slower than this are logged.
    private static let slowBatch: TimeInterval = 0.012

    private final class App {
        let pid: pid_t
        let queue: DispatchQueue
        let lock = NSLock()
        /// Latest requested position and size per window; older ones are replaced.
        var moves: [CGWindowID: (Window, Double, Double)] = [:]
        var sizes: [CGWindowID: (Window, Double, Double)] = [:]
        /// A drain is queued or running: new requests just join it.
        var scheduled = false
        var enhanced: (checked: Date, on: Bool)?

        init(pid: pid_t) {
            self.pid = pid
            queue = DispatchQueue(label: "mover-\(pid)", qos: .userInteractive)
        }

        func post(_ update: (App) -> Void) {
            let start = lock.withLock { () -> Bool in
                update(self)
                defer { scheduled = true }
                return !scheduled
            }
            if start { queue.async(execute: drain) }
        }

        /// Apply everything waiting, resizes first, until nothing is left.
        func drain() {
            while true {
                let (sizes, moves) = lock.withLock { () -> ([(Window, Double, Double)], [(Window, Double, Double)]) in
                    defer { self.sizes = [:]; self.moves = [:] }
                    if self.sizes.isEmpty && self.moves.isEmpty { scheduled = false }
                    return (Array(self.sizes.values), Array(self.moves.values))
                }
                if sizes.isEmpty && moves.isEmpty { return }
                apply(sizes: sizes, moves: moves)
            }
        }

        private func apply(sizes: [(Window, Double, Double)], moves: [(Window, Double, Double)]) {
            if enhanced.map({ Date().timeIntervalSince($0.checked) >= Mover.enhancedUICheck }) ?? true {
                enhanced = (Date(), AX.enhancedUI(pid))
            }
            let enhancedOn = enhanced?.on ?? false
            if enhancedOn { AX.setEnhancedUI(pid, false) }
            let start = Date()
            for (win, w, h) in sizes {
                win.setSize(w, h)
                let got = win.size ?? CGSize(width: w, height: h)
                Engine.shared?.send(.resized(win.id, want: CGSize(width: w, height: h), got: got))
            }
            for (win, x, y) in moves {
                win.setPosition(x, y)
                if Log.verbose, let p = win.position, abs(p.x - x) > 2 || abs(p.y - y) > 2 {
                    // A window macOS won't put where it's asked gets corrected every frame, which shows as lag.
                    Log.debug("window \(win.id) asked to (\(Int(x)), \(Int(y))), is at (\(Int(p.x)), \(Int(p.y)))")
                }
            }
            if enhancedOn { AX.setEnhancedUI(pid, true) }
            let took = Date().timeIntervalSince(start)
            if took > Mover.slowBatch {
                Log.debug("app \(pid) took \(Int(took * 1000)) ms to move or resize \(sizes.count + moves.count) window(s)")
            }
        }
    }

    private var apps: [pid_t: App] = [:]

    private func app(_ pid: pid_t) -> App {
        if let app = apps[pid] { return app }
        let app = App(pid: pid)
        apps[pid] = app
        return app
    }

    func setPosition(_ win: Window, _ x: Double, _ y: Double) {
        app(win.pid).post { $0.moves[win.id] = (win, x, y) }
    }

    /// Resize a window; the size it really took comes back as `Command.resized`.
    func setSize(_ win: Window, _ w: Double, _ h: Double) {
        app(win.pid).post { $0.sizes[win.id] = (win, w, h) }
    }

    /// Drop every move and resize not yet applied and wait for those being
    /// applied to land, so moves made right after this aren't undone by older ones.
    func flush() {
        for app in apps.values {
            app.lock.withLock {
                app.moves = [:]
                app.sizes = [:]
            }
            let done = DispatchSemaphore(value: 0)
            app.queue.async { done.signal() }
            _ = done.wait(timeout: .now() + Mover.flushTimeout)
        }
    }

    /// Forget the queues of apps that no longer have managed windows.
    func retain(pids: Set<pid_t>) {
        apps = apps.filter { pids.contains($0.key) }
    }
}

/// Focuses windows on a queue of its own. Bringing an app to the front waits
/// for it to answer, and a slow one (Electron, Chrome) can take a tenth of a
/// second: done on the engine's queue, that would hold up the animation the
/// focus change just started. Each focus reports back as `Command.focused`.
///
/// It also keeps pinned windows on top. Columns scroll underneath them, but
/// macOS stacks windows by when they were last focused, so a column that
/// passed under a pin would otherwise cover it.
final class Focuser {
    private let queue = DispatchQueue(label: "focuser", qos: .userInteractive)
    private let lock = NSLock()
    /// The window to focus next; a newer request replaces one not yet started.
    private var focus: Window?
    /// Pinned windows to raise afterwards.
    private var raise: [Window]?
    private var scheduled = false

    /// Focus a window, then raise the pinned ones above it.
    func focus(_ win: Window, pins: [Window]) {
        post { $0.focus = win; $0.raise = pins }
    }

    /// Raise the pinned windows, e.g. after the user clicked another window.
    func raise(_ pins: [Window]) {
        guard !pins.isEmpty else { return }
        post { $0.raise = pins }
    }

    private func post(_ update: (Focuser) -> Void) {
        let start = lock.withLock { () -> Bool in
            update(self)
            defer { scheduled = true }
            return !scheduled
        }
        guard start else { return }
        queue.async { [self] in
            while true {
                let job = lock.withLock { () -> (Window?, [Window]?) in
                    defer { focus = nil; raise = nil }
                    if focus == nil && raise == nil { scheduled = false }
                    return (focus, raise)
                }
                guard job.0 != nil || job.1 != nil else { return }
                job.0?.focus()
                // Raising doesn't activate the app, so focus stays where it is.
                job.1?.forEach { $0.raise() }
                if let win = job.0 { Engine.shared?.send(.focused(win.id)) }
            }
        }
    }
}
