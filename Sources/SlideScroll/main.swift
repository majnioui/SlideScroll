import AppKit

// SlideScroll: a scrolling window manager for macOS. Windows live on an
// endless horizontal strip per display, and opening one never squeezes
// the others.

AX.setGlobalTimeout()

/// `--list`: print what SlideScroll sees without moving anything.
if CommandLine.arguments.contains("--list") {
    if !AX.isTrusted(prompt: false) { print("not trusted for Accessibility; window list will be empty") }
    for d in Display.all() {
        let v = d.visible
        print("display \(d.id): usable \(Int(v.w))x\(Int(v.h)) at (\(Int(v.x)), \(Int(v.y)))")
    }
    print("focused window: \(AX.focusedWindowID().map(String.init) ?? "none")")
    print("trackpads: \((try? Touch.install()) ?? 0)")
    for f in [3, 4] { print("macOS \(f)-finger swipe conflict: \(Touch.macosConflict(f) ?? "none")") }
    print("three finger drag: \(Touch.threeFingerDragOn)")
    print("macOS tiling: \(Checks.macosTiling)")
    print("stage manager: \(Checks.stageManagerOn)")
    print("other window managers: \(Checks.otherWindowManagers)")
    for w in AX.listWindows(known: [], knownPIDs: []).windows {
        let p = w.position ?? .zero, s = w.size ?? .zero
        print("  window \(w.id) pid \(w.pid)  \(Int(s.width))x\(Int(s.height)) at (\(Int(p.x)), \(Int(p.y)))")
    }
    exit(0)
}

/// `slidescroll focus-left` and the like: hand it to the running app and exit.
_ = Remote.runFromCommandLine(CommandLine.arguments)

Log.start()
Log.info("SlideScroll \(Update.version) starting")

// Ctrl-C in a terminal quits the same way the menu does, so windows go back
// on screen. Before the engine runs nothing is managed yet, so it just exits.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { App.quit() }
interrupt.resume()

// Read before Settings can open, so nothing saved from it drops what's there.
let (tables, configProblems) = Config.read()
let (keymap, keyProblems) = Keymap.from(tables)
let (prefs, prefProblems) = Prefs.from(tables)
for p in configProblems + keyProblems + prefProblems { Log.info(p) }
Keymap.current = keymap
Prefs.current = prefs
AppModel.shared.keymap = keymap
AppModel.shared.prefs = prefs
Log.debug("shortcuts:\n\(keymap.help)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
