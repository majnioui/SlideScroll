import CoreGraphics
import Foundation

/// Global shortcuts via a CGEventTap. Key presses that match the keymap are
/// swallowed and handed to the engine.
enum Hotkeys {
    /// The event tap. Created once and kept for the life of the app.
    private static var tap: CFMachPort?
    /// Off while SlideScroll is paused: every key goes to the app as usual.
    static var enabled = true
    /// On while the Settings window records a new shortcut, which must reach it.
    static var recording = false

    /// Turn the tap back on, in case macOS turned it off (e.g. across sleep).
    static func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Install the tap on the main run loop.
    static func install() throws {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // macOS disables taps that are slow to respond; turn it back on.
                Hotkeys.reenable()
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, Hotkeys.enabled, !Hotkeys.recording else {
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags.rawValue
            let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let command = Keymap.current.command(for: flags, key: key)
            guard let command, let engine = Engine.shared else { return Unmanaged.passUnretained(event) }
            // Only shortcuts are logged: anything else is the user typing.
            Log.debug("shortcut \(Shortcut(mods: flags & Mod.all, key: key).configText) -> \(command)")
            engine.send(command)
            return nil // swallow the key press
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            throw ConfigProblem("could not create event tap (is Accessibility permission granted?)")
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }
}
