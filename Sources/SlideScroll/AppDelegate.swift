import AppKit

/// The app itself: the menu bar item, quitting, and the system notifications
/// that pause the engine (sleep, locking, user switching) or change it
/// (displays, Reduce Motion).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    /// Keeps App Nap off for as long as it's held.
    private var activity: NSObjectProtocol?
    /// Why window management is suspended; it resumes when none holds.
    private var asleep = false, screensAsleep = false, locked = false, switchedAway = false
    private var suspended = false
    private var model: AppModel { AppModel.shared }
    /// The notification observers, kept for the life of the app.
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // A menu bar app with no windows of its own gets App Nap, which bunches
        // up its timers: the animation would run in uneven bursts. The Mac can
        // still go to sleep while this is held.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Animating windows")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "SlideScroll") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "SlideScroll"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        observe()
        sendReduceMotion()
        Update.start()
        App.startWhenTrusted()
    }

    /// Logging out or shutting down: put every window back on screen first.
    /// The engine exits the process once it has.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.status == .running, let engine = Engine.shared else { return .terminateNow }
        engine.send(.quit)
        return .terminateLater
    }

    /// The menu bar icon is dimmed whenever windows aren't being managed.
    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let active = model.status == .running && !model.paused
        button.appearsDisabled = !active
        button.toolTip = switch model.status {
        case .running: model.paused ? "SlideScroll is paused" : "SlideScroll"
        case .needsPermission: "SlideScroll needs Accessibility permission"
        case .failed(let why): "SlideScroll couldn't start: \(why)"
        }
    }

    /// Built fresh each time it opens, so it's never stale. Kept short:
    /// setup checks, logging and everything else are in Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = action != nil
            return item
        }
        menu.addItem(item(model.statusText, nil))
        if case .ready(let version) = model.update {
            menu.addItem(item("Restart to Update to \(version)", #selector(installUpdate)))
        }
        switch model.status {
        case .needsPermission: menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        case .running: menu.addItem(item(model.paused ? "Resume" : "Pause", #selector(togglePause)))
        case .failed: break
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit SlideScroll", #selector(quit), "q"))
    }

    @objc private func togglePause() { setPaused(!model.paused) }

    /// Stop or go back to managing windows, as the menu's Pause and Resume do.
    func setPaused(_ paused: Bool) {
        guard paused != model.paused else { return }
        model.paused = paused
        Hotkeys.enabled = !paused
        Engine.shared?.send(paused ? .pause : .resume)
    }

    /// `slidescroll://` URLs, from Raycast, Shortcuts, the command line and so on.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Remote.handle(url) }
    }

    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func openAccessibility() { App.open(Checks.accessibilitySettings) }
    @objc private func quit() { App.quit() }
    @objc private func installUpdate() { App.installUpdate() }

    /// Hear about sleep, wake, locking, user switching, displays and Reduce Motion.
    private func observe() {
        let ws = NSWorkspace.shared.notificationCenter
        let on = { [unowned self] (name: Notification.Name, center: NotificationCenter, body: @escaping () -> Void) in
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in body() })
        }
        on(NSWorkspace.willSleepNotification, ws) { [unowned self] in setSuspend { $0.asleep = true } }
        on(NSWorkspace.didWakeNotification, ws) { [unowned self] in setSuspend { $0.asleep = false } }
        on(NSWorkspace.screensDidSleepNotification, ws) { [unowned self] in setSuspend { $0.screensAsleep = true } }
        on(NSWorkspace.screensDidWakeNotification, ws) { [unowned self] in setSuspend { $0.screensAsleep = false } }
        on(NSWorkspace.sessionDidResignActiveNotification, ws) { [unowned self] in setSuspend { $0.switchedAway = true } }
        on(NSWorkspace.sessionDidBecomeActiveNotification, ws) { [unowned self] in setSuspend { $0.switchedAway = false } }
        on(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, ws) { [unowned self] in sendReduceMotion() }
        let distributed = DistributedNotificationCenter.default()
        on(.init("com.apple.screenIsLocked"), distributed) { [unowned self] in setSuspend { $0.locked = true } }
        on(.init("com.apple.screenIsUnlocked"), distributed) { [unowned self] in setSuspend { $0.locked = false } }
        // Displays connected, removed, rearranged or resized, or the Dock moved.
        on(NSApplication.didChangeScreenParametersNotification, .default) {
            FrameClock.forget()
            Engine.shared?.send(.displaysChanged(Display.all()))
        }
    }

    /// Suspend the engine while asleep, locked or switched away, and wake it
    /// once none of those holds, with the displays as they are by then.
    private func setSuspend(_ update: (AppDelegate) -> Void) {
        update(self)
        let now = asleep || screensAsleep || locked || switchedAway
        guard now != suspended else { return }
        suspended = now
        if now {
            Engine.shared?.send(.suspend)
        } else {
            // macOS can turn event taps off across sleep.
            Hotkeys.reenable()
            Engine.shared?.send(.wake(Display.all()))
        }
    }

    /// Tell the engine whether Accessibility's "Reduce motion" is on.
    private func sendReduceMotion() {
        Engine.shared?.send(.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    }
}
