import AppKit
import Combine
import ServiceManagement

/// What the menu and the Settings window show. Main thread only; SwiftUI
/// redraws whatever reads a property when it changes.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Status: Equatable {
        /// Waiting for the user to allow Accessibility.
        case needsPermission
        case running
        /// It couldn't start; the reason is in the menu and the log.
        case failed(String)
    }

    @Published var status = Status.needsPermission { didSet { AppDelegate.shared?.refreshIcon() } }
    @Published var paused = false { didSet { AppDelegate.shared?.refreshIcon() } }
    @Published var update = Update.State.idle
    @Published var warnings: [Warning] = []
    /// Trackpads found at startup, for the setup checks.
    var trackpads = 0
    @Published var prefs = Prefs.current
    @Published var keymap = Keymap.current
    /// The shortcut slot waiting for new keys: (action, slot).
    @Published var recording: (action: Int, slot: Int)? {
        // While recording, global shortcuts stand aside so the keys reach Settings.
        didSet { Hotkeys.recording = recording != nil }
    }
    @Published var verbose = Log.verbose { didSet { Log.verbose = verbose } }
    @Published var launchAtLogin = false

    var statusText: String {
        switch status {
        case .running: paused ? "SlideScroll is paused" : "SlideScroll is running"
        case .needsPermission: "Waiting for Accessibility permission"
        case .failed(let why): "Couldn't start: \(why)"
        }
    }

    /// Running as SlideScroll.app rather than a bare binary: needed for login items.
    var bundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Check the Mac's setup again: the user may have just fixed something.
    func refreshWarnings() {
        warnings = Checks.warnings(trackpads: trackpads)
        launchAtLogin = bundled && SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            Log.info("couldn't change Launch at Login: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = service.status == .enabled
    }

    func changePrefs(_ update: (inout Prefs) -> Void) {
        Prefs.change(update)
        prefs = Prefs.current
    }

    func changeKeymap(_ update: (inout Keymap) -> Void) {
        Keymap.change(update)
        keymap = Keymap.current
    }
}
