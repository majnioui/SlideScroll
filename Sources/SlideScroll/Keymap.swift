import Carbon.HIToolbox
import Foundation

// Which shortcut runs which action, and the `[keys]` part of config.toml.
//
// Shortcuts name physical keys by where they sit on a US keyboard
// (`ctrl+alt+h`), so they keep working on any layout; the Settings window
// shows them the way the user's own keyboard labels them. The config file
// only lists what differs from the defaults, so actions added later get
// their default shortcuts without the user doing anything.

/// Modifier bits, the same in CGEventFlags and NSEvent.ModifierFlags.
enum Mod {
    static let shift: UInt64 = 0x0002_0000
    static let ctrl: UInt64 = 0x0004_0000
    static let alt: UInt64 = 0x0008_0000
    static let cmd: UInt64 = 0x0010_0000
    static let all: UInt64 = shift | ctrl | alt | cmd
}

struct Shortcut: Hashable {
    /// Some of `Mod.all`.
    var mods: UInt64
    /// Virtual key code: a physical key, whatever the layout.
    var key: UInt16

    /// Config names for physical keys, by their US-layout label.
    static let keys: [(String, UInt16)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
        ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
        ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("return", 36), ("l", 37),
        ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46),
        (".", 47), ("tab", 48), ("space", 49), ("`", 50), ("delete", 51), ("escape", 53), ("f5", 96), ("f6", 97),
        ("f7", 98), ("f3", 99), ("f8", 100), ("f9", 101), ("f11", 103), ("f10", 109), ("f12", 111), ("home", 115),
        ("pageup", 116), ("forwarddelete", 117), ("f4", 118), ("end", 119), ("f2", 120), ("pagedown", 121),
        ("f1", 122), ("left", 123), ("right", 124), ("down", 125), ("up", 126),
    ]

    /// How keys that don't type a character are shown.
    static let symbols: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥", "space": "Space",
        "delete": "⌫", "forwarddelete": "⌦", "escape": "⎋", "home": "↖", "end": "↘", "pageup": "⇞",
        "pagedown": "⇟", "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6", "f7": "F7",
        "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    ]

    static func code(_ name: String) -> UInt16? { keys.first { $0.0 == name }?.1 }
    static func name(_ code: UInt16) -> String? { keys.first { $0.1 == code }?.0 }

    /// From the config form, e.g. `ctrl+alt+shift+left`.
    init(parsing s: String) throws {
        let parts = s.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { throw ConfigProblem("empty shortcut") }
        var mods: UInt64 = 0
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "ctrl", "control": mods |= Mod.ctrl
            case "alt", "opt", "option": mods |= Mod.alt
            case "shift": mods |= Mod.shift
            case "cmd", "command": mods |= Mod.cmd
            default: throw ConfigProblem("unknown modifier \"\(m)\" in \"\(s)\"")
            }
        }
        guard let key = Shortcut.code(keyName.lowercased()) else { throw ConfigProblem("unknown key \"\(keyName)\" in \"\(s)\"") }
        self.init(mods: mods, key: key)
        guard isValid else { throw ConfigProblem("\"\(s)\" needs ctrl, alt or cmd") }
    }

    init(mods: UInt64, key: UInt16) {
        self.mods = mods
        self.key = key
    }

    /// The config form: modifiers in a fixed order, then the key.
    var configText: String {
        let names = [(Mod.ctrl, "ctrl"), (Mod.alt, "alt"), (Mod.shift, "shift"), (Mod.cmd, "cmd")]
        return names.filter { mods & $0.0 != 0 }.map { $0.1 + "+" }.joined() + (Shortcut.name(key) ?? "?")
    }

    /// Plain keys and shift-only combinations would take over typing.
    var isValid: Bool {
        mods & (Mod.ctrl | Mod.alt | Mod.cmd) != 0 && Shortcut.name(key) != nil
    }

    /// As macOS menus show it, e.g. `⌃⌥⇧H`, with the character the key types
    /// on the current keyboard layout.
    func label(_ charFor: (UInt16) -> String? = Keyboard.character) -> String {
        let symbols = [(Mod.ctrl, "⌃"), (Mod.alt, "⌥"), (Mod.shift, "⇧"), (Mod.cmd, "⌘")]
        let prefix = symbols.filter { mods & $0.0 != 0 }.map(\.1).joined()
        if let name = Shortcut.name(key), let symbol = Shortcut.symbols[name] {
            return prefix + symbol
        }
        return prefix + (charFor(key) ?? Shortcut.name(key) ?? "").uppercased()
    }
}

struct ConfigProblem: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Action {
    /// The name in the config file.
    let name: String
    /// What the Settings window calls it.
    let label: String
    let group: String
    let defaults: [String]
    let command: Command
}

/// Every action, in the order the Settings window lists them.
let actions: [Action] = {
    func a(_ name: String, _ label: String, _ group: String, _ keys: [String], _ command: Command) -> Action {
        Action(name: name, label: label, group: group, defaults: keys, command: command)
    }
    var list = [
        a("focus_left", "Focus left", "Focus", ["ctrl+alt+h", "ctrl+alt+left"], .focusLeft),
        a("focus_right", "Focus right", "Focus", ["ctrl+alt+l", "ctrl+alt+right"], .focusRight),
        a("focus_first", "Focus first window", "Focus", ["ctrl+alt+cmd+left"], .focusFirst),
        a("focus_last", "Focus last window", "Focus", ["ctrl+alt+cmd+right"], .focusLast),
        a("focus_up", "Focus up in a stack", "Focus", ["ctrl+alt+k", "ctrl+alt+up"], .focusUp),
        a("focus_down", "Focus down in a stack", "Focus", ["ctrl+alt+j", "ctrl+alt+down"], .focusDown),
    ]
    for i in 1...9 {
        list.append(a("focus_window_\(i)", "Jump to window \(i)", "Focus", ["ctrl+alt+\(i)"], .focusIndex(i - 1)))
    }
    list += [
        a("focus_next_display", "Focus next display", "Focus", ["ctrl+alt+n"], .focusNextDisplay),
        a("move_left", "Move column left", "Move", ["ctrl+alt+shift+h", "ctrl+alt+shift+left"], .moveLeft),
        a("move_right", "Move column right", "Move", ["ctrl+alt+shift+l", "ctrl+alt+shift+right"], .moveRight),
        a("move_up", "Move up in a stack", "Move", ["ctrl+alt+shift+k", "ctrl+alt+shift+up"], .moveUp),
        a("move_down", "Move down in a stack", "Move", ["ctrl+alt+shift+j", "ctrl+alt+shift+down"], .moveDown),
        a("send_to_next_display", "Move to next display", "Move", ["ctrl+alt+shift+n"], .sendToNextDisplay),
        a("pin_left", "Pin to left edge", "Move", ["ctrl+alt+p"], .pinLeft),
        a("pin_right", "Pin to right edge", "Move", ["ctrl+alt+shift+p"], .pinRight),
        a("toggle_float", "Float / unfloat", "Move", ["ctrl+alt+t"], .toggleFloat),
        a("cycle_width", "Cycle width", "Size", ["ctrl+alt+r"], .cycleWidth),
        a("full_width", "Full width", "Size", ["ctrl+alt+f"], .fullWidth),
        a("centre", "Centre column", "Size", ["ctrl+alt+c"], .centre),
        a("wider", "Wider", "Size", ["ctrl+alt+="], .wider),
        a("narrower", "Narrower", "Size", ["ctrl+alt+-"], .narrower),
        a("taller", "Taller in a stack", "Size", ["ctrl+alt+shift+="], .taller),
        a("shorter", "Shorter in a stack", "Size", ["ctrl+alt+shift+-"], .shorter),
        a("equalize_heights", "Equal heights", "Size", ["ctrl+alt+0"], .equalizeHeights),
        a("stack_left", "Stack into left column", "Stacks and tabs", ["ctrl+alt+["], .stackLeft),
        a("stack_right", "Stack into right column", "Stacks and tabs", ["ctrl+alt+]"], .stackRight),
        a("pop_left", "Pop out to the left", "Stacks and tabs", ["ctrl+alt+shift+["], .popLeft),
        a("pop_right", "Pop out to the right", "Stacks and tabs", ["ctrl+alt+shift+]"], .popRight),
        a("toggle_tabbed", "Tabbed column", "Stacks and tabs", ["ctrl+alt+shift+t"], .toggleTabbed),
        a("quit", "Quit SlideScroll", "App", ["ctrl+alt+q"], .quit),
    ]
    return list
}()

struct Keymap: Equatable {
    /// Shortcut slots per action in the Settings window.
    static let slots = 2

    /// Shortcuts per action, indexed like `actions`.
    var bindings: [[Shortcut]]

    static func defaultBindings(_ action: Int) -> [Shortcut] {
        actions[action].defaults.map { try! Shortcut(parsing: $0) }
    }

    static var defaults: Keymap {
        Keymap(bindings: actions.indices.map(defaultBindings))
    }

    func command(for mods: UInt64, key: UInt16) -> Command? {
        let pressed = Shortcut(mods: mods & Mod.all, key: key)
        return bindings.firstIndex { $0.contains(pressed) }.map { actions[$0].command }
    }

    func isDefault(_ action: Int) -> Bool {
        bindings[action] == Keymap.defaultBindings(action)
    }

    /// Put `shortcut` in `slot` of `action` (or clear the slot with nil).
    /// A shortcut can only do one thing, so any other action using it loses it.
    mutating func set(_ action: Int, slot: Int, _ shortcut: Shortcut?) {
        guard let sc = shortcut else {
            if slot < bindings[action].count { bindings[action].remove(at: slot) }
            return
        }
        let at = min(slot, bindings[action].count)
        if at < bindings[action].count {
            bindings[action][at] = sc
        } else {
            bindings[action].append(sc)
        }
        takeFromOthers(action, at: at, sc)
    }

    /// Give `action` its default shortcuts back, taking them from any other
    /// action that has them.
    mutating func reset(_ action: Int) {
        bindings[action] = Keymap.defaultBindings(action)
        for (at, sc) in bindings[action].enumerated() {
            takeFromOthers(action, at: at, sc)
        }
    }

    /// Remove `sc` everywhere except slot `at` of `action`.
    private mutating func takeFromOthers(_ action: Int, at: Int, _ sc: Shortcut) {
        for a in bindings.indices {
            bindings[a] = bindings[a].enumerated().filter { $0.element != sc || (a == action && $0.offset == at) }.map(\.element)
        }
    }

    /// Defaults, overridden by `[keys]`. Problems are returned, not fatal:
    /// whatever can be read still applies.
    static func from(_ tables: Config.Tables) -> (Keymap, [String]) {
        var keymap = Keymap.defaults
        var problems: [String] = []
        for (name, value) in (tables["keys"] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let i = actions.firstIndex(where: { $0.name == name }) else {
                problems.append("config.toml: no action called \"\(name)\"")
                continue
            }
            guard case .strings(let list) = value else {
                problems.append("config.toml: \(name) should be a list of shortcuts")
                continue
            }
            keymap.bindings[i] = []
            for s in list {
                do {
                    keymap.set(i, slot: keymap.bindings[i].count, try Shortcut(parsing: s))
                } catch {
                    problems.append("config.toml: \(name): \(error)")
                }
            }
        }
        return (keymap, problems)
    }

    /// The config file's first part: a header, then only the actions that
    /// differ from their defaults.
    func configText() -> String {
        var out = """
        # SlideScroll settings. Settings… in the menu bar edits this file too.
        #
        # Each action takes a list of shortcuts, e.g. focus_left = ["ctrl+alt+h", "ctrl+alt+left"].
        # Keys are named by where they are on a US keyboard; [] turns an action off.
        # Actions that aren't listed keep their default shortcuts.

        [keys]

        """
        for i in actions.indices where !isDefault(i) {
            let list = bindings[i].map { Config.quote($0.configText) }.joined(separator: ", ")
            out += "\(actions[i].name) = [\(list)]\n"
        }
        return out
    }

    /// One line per action with a shortcut, for the log.
    var help: String {
        actions.indices.filter { !bindings[$0].isEmpty }.map { i in
            let keys = bindings[i].map { $0.label { _ in nil } }.joined(separator: " / ")
            return "  " + keys.padding(toLength: 22, withPad: " ", startingAt: 0) + " " + actions[i].label
        }.joined(separator: "\n")
    }

    // The keymap in use, read by the event tap on every key press.
    private static let lock = NSLock()
    private static var _current = Keymap.defaults

    static var current: Keymap {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }

    /// Use a changed keymap right away and save it.
    static func change(_ update: (inout Keymap) -> Void) {
        var keymap = current
        update(&keymap)
        current = keymap
        Config.save(keymap: keymap, prefs: Prefs.current)
    }
}

/// What each physical key types on the current keyboard layout, so shortcuts
/// are shown as the user's own keyboard labels them.
enum Keyboard {
    /// The character `code` types with no modifiers on the current layout, e.g.
    /// "a" for key 12 on AZERTY. Nil for keys that don't type anything visible.
    static func character(_ code: UInt16) -> String? {
        // Input methods like Japanese have no key layout of their own; fall
        // back to the ASCII-capable layout they type through.
        let sources = [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource]
        for copy in sources {
            guard let source = copy()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { buf in
                UCKeyTranslate(buf.bindMemory(to: UCKeyboardLayout.self).baseAddress, code,
                               UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            }
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            let visible = !s.trimmingCharacters(in: .whitespaces).isEmpty
                && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            return visible ? s : nil
        }
        return nil
    }
}
