import AppKit
import QuartzCore

/// Animation frames in step with the display: a display link on the main
/// thread sends the engine `Command.frame` once per refresh, with the time
/// that frame will be on screen. The engine then moves windows once per frame
/// the display really shows, at its own rate (60 Hz on most external
/// displays, up to 120 Hz with ProMotion), and steps its springs by the real
/// time between frames, so motion has no beat against the refresh.
///
/// Display links on NSScreen are new in macOS 14; on macOS 13 the engine
/// keeps its own timer.
enum FrameClock {
    static let available: Bool = {
        if #available(macOS 14, *) { return true }
        return false
    }()

    /// The link and the display it follows. Main thread only.
    private static var link: (display: CGDirectDisplayID, link: AnyObject)?

    private final class Target: NSObject {
        @available(macOS 14, *)
        @objc func tick(_ link: CADisplayLink) {
            Engine.shared?.send(.frame(at: link.targetTimestamp))
        }
    }

    /// Send frames timed to this display, or stop sending them. Callable from any thread.
    static func run(on display: CGDirectDisplayID?) {
        guard #available(macOS 14, *) else { return }
        DispatchQueue.main.async {
            let current = link?.link as? CADisplayLink
            switch display {
            case nil:
                current?.isPaused = true
            case let id? where link?.display == id:
                current?.isPaused = false
            case let id?:
                current?.invalidate()
                link = makeLink(id).map { (id, $0) }
            }
        }
    }

    /// Drop the link: its display may be gone or changed. Main thread only;
    /// the engine asks for a new one when it next animates.
    static func forget() {
        if #available(macOS 14, *) { (link?.link as? CADisplayLink)?.invalidate() }
        link = nil
    }

    @available(macOS 14, *)
    private static func makeLink(_ display: CGDirectDisplayID) -> CADisplayLink? {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return nil }
        let link = screen.displayLink(target: Target(), selector: #selector(Target.tick(_:)))
        // Ask ProMotion displays for their full rate rather than whatever they idle at.
        let max = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(max, 60), maximum: max, preferred: max)
        link.add(to: .main, forMode: .common)
        Log.debug("frames follow display \(display) at up to \(Int(max)) Hz")
        return link
    }
}
