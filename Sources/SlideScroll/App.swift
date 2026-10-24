import AppKit

/// Starting, quitting and the odd jobs the menu and Settings share.
enum App {
    /// Start managing windows once Accessibility is allowed: at once if it
    /// is, or as soon as the user switches it on.
    static func startWhenTrusted() {
        if Permission.request() {
            start()
            return
        }
        // macOS shows its prompt; start as soon as the user says yes.
        Log.info("waiting for Accessibility permission: allow SlideScroll (or your terminal app) in System Settings → Privacy & Security → Accessibility")
        AppModel.shared.status = .needsPermission
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if AX.isTrusted(prompt: false) {
                timer.invalidate()
                start()
            }
        }
    }

    /// Start managing windows. Needs Accessibility permission. Main thread.
    private static func start() {
        let model = AppModel.shared
        let displays = Display.all()
        guard !displays.isEmpty else {
            Log.info("no displays found")
            model.status = .failed("no displays found")
            return
        }
        do {
            // The event tap is delivered through the main run loop.
            try Hotkeys.install()
        } catch {
            Log.info("\(error)")
            model.status = .failed("\(error)")
            return
        }
        do {
            model.trackpads = try Touch.install()
        } catch {
            Log.info("trackpad swipes unavailable: \(error)")
        }
        model.refreshWarnings()
        for w in model.warnings { Log.info("⚠  \(w.title): \(w.detail)") }
        let engine = Engine(displays: displays)
        engine.start()
        engine.send(.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        Observer.start()
        Log.info("running on \(displays.count) display(s), \(model.trackpads) trackpad(s), \(Touch.fingers)-finger swipes")
        model.status = .running
    }

    /// Quit the way the menu does: the engine, if it runs, puts every window
    /// back on screen and then exits the process.
    static func quit() {
        if AppModel.shared.status == .running, let engine = Engine.shared {
            engine.send(.quit)
        } else {
            exit(0)
        }
    }

    /// Install the downloaded update and restart into it.
    static func installUpdate() {
        do {
            try Update.installAndRelaunch()
            quit()
        } catch {
            Log.info("couldn't install the update: \(error)")
        }
    }

    static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    static func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.url])
    }
}
