import ApplicationServices
import Foundation

/// Window lifecycle events via AXObserver, so closing, opening or dragging a
/// window is handled at once instead of on the next poll.
///
/// Observers deliver through a run loop, so they live on a thread of their
/// own, which also attaches observers to newly launched apps.
final class Observer: Thread {
    /// Notifications registered on the app element.
    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    /// Notifications registered on each window element.
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    private final class AppObserver {
        let pid: pid_t
        let observer: AXObserver
        let app: AXUIElement
        var watched = Set<CGWindowID>()

        init?(pid: pid_t) {
            var observer: AXObserver?
            guard AXObserverCreate(pid, Observer.callback, &observer) == .success, let observer else { return nil }
            self.pid = pid
            self.observer = observer
            app = AXUIElementCreateApplication(pid)
            for n in Observer.appNotifications {
                AXObserverAddNotification(observer, app, n as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }

        /// Register per-window notifications on windows we haven't seen yet.
        func refreshWindows() {
            var elsewhere: [CGWindowID] = []
            guard let windows = AX.appWindows(pid, only: nil, known: [], elsewhere: &elsewhere) else { return }
            for w in windows where watched.insert(w.id).inserted {
                for n in Observer.windowNotifications {
                    AXObserverAddNotification(observer, w.element, n as CFString, nil)
                }
            }
            watched.formIntersection(windows.map(\.id))
        }

        func remove() {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    private static let callback: AXObserverCallback = { _, element, notification, _ in
        let command: Command
        switch notification as String {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let id = element.windowID else { return }
            // Mouse-driven moves are the user dragging; anything else is our
            // own animation or something like macOS tiling, which the engine sorts out.
            command = AX.mouseDown ? .windowDragged(id) : .windowMoved(id)
        case kAXFocusedWindowChangedNotification:
            // Here the element is the newly focused window.
            command = .focusChanged(element.windowID)
        case kAXApplicationActivatedNotification:
            // Dock click, Cmd-Tab, clicking a window: the app's own focused window
            // doesn't change, so ask the app which one it is.
            command = .focusChanged(element.pid.flatMap(AX.focusedWindow(of:)))
        default:
            command = .windowsChanged
        }
        Engine.shared?.send(command)
    }

    override func main() {
        var apps: [pid_t: AppObserver] = [:]
        var tick = 0
        while true {
            tick &+= 1
            // Apps stay watched until they quit, so showing a hidden app
            // or a minimised window is still heard about at once.
            for pid in apps.keys where !AX.isRunning(pid) {
                apps.removeValue(forKey: pid)?.remove()
            }
            // New windows of known apps are announced by AXWindowCreated;
            // this once-a-second pass only catches what was missed.
            if tick % 4 == 0 {
                apps.values.forEach { $0.refreshWindows() }
            }
            var newApp = false
            for pid in AX.onScreenPIDs() where apps[pid] == nil {
                if let obs = AppObserver(pid: pid) {
                    obs.refreshWindows()
                    apps[pid] = obs
                    newApp = true
                }
            }
            if newApp {
                Engine.shared?.send(.windowsChanged)
            }
            // Deliver notifications for a quarter second, then look for newly launched apps.
            if CFRunLoopRunInMode(.defaultMode, 0.25, false) == .finished {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    static func start() {
        let thread = Observer()
        thread.name = "observer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
