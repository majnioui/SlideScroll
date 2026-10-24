import AppKit

/// Something about this Mac's setup that gets in SlideScroll's way.
struct Warning: Equatable, Identifiable {
    var id: String { title }
    /// Short, for the menu.
    var title: String
    /// What happens and how to fix it, for the log and Settings.
    var detail: String
    /// The System Settings pane that fixes it, if there is one.
    var settings: String?
}

/// macOS settings and other apps that fight a window manager.
enum Checks {
    static let trackpadSettings = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    static let desktopSettings = "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    static let pointerSettings = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
    static let accessibilitySettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// macOS 15+ tiling options that are on, as named in System Settings →
    /// Desktop & Dock → Windows. Unset means the default, which is on.
    static var macosTiling: [String] {
        [
            ("EnableTilingByEdgeDrag", "Drag windows to screen edges to tile"),
            ("EnableTopTilingByEdgeDrag", "Drag windows to menu bar to fill screen"),
            ("EnableTilingOptionAccelerator", "Hold ⌥ key while dragging windows to tile"),
        ].filter { pref(domain: "com.apple.WindowManager", key: $0.0) != 0 }.map(\.1)
    }

    /// Stage Manager moves and resizes windows itself. Unset means off.
    static var stageManagerOn: Bool {
        (pref(domain: "com.apple.WindowManager", key: "GloballyEnabled") ?? 0) != 0
    }

    /// Window managers and snapping apps that would move windows under us.
    private static let windowManagers = [
        "com.knollsoft.Rectangle": "Rectangle", "com.knollsoft.Hookshot": "Rectangle Pro",
        "com.crowdcafe.windowmagnet": "Magnet", "com.MrKai77.Loop": "Loop",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool", "com.manytricks.Moom": "Moom",
        "com.divisiblebyzero.Spectacle": "Spectacle", "com.amethyst.Amethyst": "Amethyst",
        "bobko.aerospace": "AeroSpace", "com.mizage.Divvy": "Divvy", "com.mizage.direct.Divvy": "Divvy",
    ]

    /// Names of the running window managers.
    static var otherWindowManagers: [String] {
        let names = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap { windowManagers[$0] } }
        return Array(Set(names)).sorted()
    }

    /// Everything worth warning about, given how many trackpads were found.
    static func warnings(trackpads: Int) -> [Warning] {
        var out: [Warning] = []
        let f = Touch.fingers
        if trackpads == 0 {
            out.append(Warning(
                title: "No trackpad: swipes are off",
                detail: "Swipes need a built-in trackpad or a Magic Trackpad (a mouse can't send them). The shortcuts still work."))
        } else if let gesture = Touch.macosConflict(f) {
            // A fast four-finger swipe lands as three fingers first, so the
            // only setting that never fights a four-finger strip is Off.
            let fix = f == 4
                ? "set \"Swipe between full-screen applications\" to Off, and switch with ⌃← / ⌃→ or Mission Control"
                : gesture == "Swipe between pages"
                ? "set \"Swipe between pages\" to \"Scroll Left or Right with Two Fingers\""
                : "set \"Swipe between full-screen applications\" to \"Swipe Left or Right with Four Fingers\" or Off"
            out.append(Warning(
                title: "macOS also uses \(f)-finger swipes",
                detail: "macOS also acts on sideways swipes for \"\(gesture)\", so a swipe can scroll the strip and switch at the same time. In Trackpad → More Gestures, \(fix). If macOS still switches afterwards, log out and back in: trackpad changes sometimes only apply then.",
                settings: trackpadSettings))
        }
        if trackpads > 0 && f == 3 && Touch.threeFingerDragOn {
            out.append(Warning(
                title: "Three Finger Drag is on",
                detail: "A 3-finger swipe also drags the window under it. Turn it off in Accessibility → Pointer Control → Trackpad Options, or use 4 fingers for SlideScroll.",
                settings: pointerSettings))
        }
        let tiling = macosTiling
        if !tiling.isEmpty {
            out.append(Warning(
                title: "macOS window tiling is on",
                detail: "Dropping a window near a screen edge makes macOS snap it into a tile; SlideScroll puts it back, but you'll see it jump. Turn these off in Desktop & Dock → Windows: \(tiling.map { "\"\($0)\"" }.joined(separator: ", ")).",
                settings: desktopSettings))
        }
        if stageManagerOn {
            out.append(Warning(
                title: "Stage Manager is on",
                detail: "Stage Manager moves and resizes windows itself, so the two will fight. Turn it off in Desktop & Dock, or in Control Centre.",
                settings: desktopSettings))
        }
        let others = otherWindowManagers
        if !others.isEmpty {
            let names = others.joined(separator: ", ")
            out.append(Warning(
                title: "\(names) is running",
                detail: "\(names) also moves windows and will fight SlideScroll over them. Quit it while SlideScroll runs."))
        }
        return out
    }
}
