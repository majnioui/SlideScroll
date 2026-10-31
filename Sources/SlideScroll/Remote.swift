import AppKit

/// Running actions from outside: `slidescroll://focus-left` URLs, for
/// Raycast, Alfred, Shortcuts and the like, and `slidescroll focus-left` in
/// a terminal, which opens the same URL.
///
/// An action's name is its config name, with `-` or `_` between words. On top
/// of the shortcut actions there are `pause`, `resume`, `toggle-pause` and
/// `settings`.
enum Remote {
    static let scheme = "slidescroll"

    private static let appActions = ["pause", "resume", "toggle_pause", "settings"]

    /// Every name a URL or the command line takes, in config spelling.
    static var names: [String] { actions.map(\.name) + appActions }

    /// The names as URLs and the command line show them: `focus-left`.
    static var dashedNames: [String] { names.map { $0.replacingOccurrences(of: "_", with: "-") } }

    /// `focus-left` → `focus_left`.
    static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    /// Run the action a `slidescroll://` URL names. Main thread.
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == scheme else { return }
        // `slidescroll://focus-left`, or `slidescroll:focus-left` without slashes.
        let raw = url.host ?? url.absoluteString.dropFirst(scheme.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = normalized(raw)
        Log.debug("url \(url.absoluteString) -> \(name)")
        let model = AppModel.shared
        switch name {
        case "settings":
            SettingsWindow.show()
            return
        case "pause", "resume", "toggle_pause":
            guard model.status == .running else { return }
            let pause = name == "toggle_pause" ? !model.paused : name == "pause"
            AppDelegate.shared?.setPaused(pause)
        default:
            guard let action = actions.first(where: { $0.name == name }) else {
                Log.info("\(url.absoluteString): no action called \(raw); try one of \(dashedNames.joined(separator: ", "))")
                return
            }
            // Like the shortcuts, actions wait while paused.
            guard model.status == .running, !model.paused, let engine = Engine.shared else { return }
            engine.send(action.command)
        }
        stepAside()
    }

    /// Opening a URL can bring SlideScroll to the front, which would take
    /// focus away from the window the action is about. Hand it back, unless
    /// the Settings window is what the user is looking at.
    private static func stepAside() {
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0 is SettingsWindow && $0.isVisible }) else { return }
        NSApp.hide(nil)
    }

    /// `slidescroll <action>`: hand the action to the running app (starting it
    /// if need be) and exit. Returns false if the arguments aren't an action.
    static func runFromCommandLine(_ args: [String]) -> Bool {
        guard args.count == 2, !args[1].hasPrefix("-") else { return false }
        let name = normalized(args[1])
        guard names.contains(name) else {
            FileHandle.standardError.write(Data("slidescroll: no action called \(args[1])\nactions: \(dashedNames.joined(separator: " "))\n".utf8))
            exit(2)
        }
        let url = URL(string: "\(scheme)://\(name.replacingOccurrences(of: "_", with: "-"))")!
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure {
            FileHandle.standardError.write(Data("slidescroll: couldn't reach SlideScroll.app: \(failure.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
