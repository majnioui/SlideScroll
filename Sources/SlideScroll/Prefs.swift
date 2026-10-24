import Foundation

/// Preferences other than shortcuts: swipes, the gap between windows, and the
/// apps that always float. They live in config.toml beside `[keys]`.
struct Prefs: Equatable {
    /// Gap sizes offered in Settings, in points.
    static let gaps: [Double] = [0, 4, 8, 12, 16, 24]
    static let maxGap = 32.0

    /// Fingers for a strip swipe: 3 or 4.
    var fingers = Prefs.defaultFingers
    /// The strip moves with the fingers, like scrolling a page. Off, it moves
    /// the other way, like moving a viewport over it.
    var natural = true
    /// Space between windows and around the strip, in points.
    var gap = 8.0
    /// Apps, by name, whose windows never join the strip.
    var floatApps: [String] = []

    /// SLIDESCROLL_FINGERS was the only way to choose before Settings could.
    static var defaultFingers: Int {
        ProcessInfo.processInfo.environment["SLIDESCROLL_FINGERS"] == "3" ? 3 : 4
    }

    /// Read from config.toml's tables, ignoring `[keys]`. Values of the wrong
    /// type are reported, never fatal: what can be read still applies.
    static func from(_ tables: Config.Tables) -> (Prefs, [String]) {
        var p = Prefs()
        var problems: [String] = []
        func get<T>(_ table: String, _ key: String, _ read: (Config.Value) -> T?) -> T? {
            guard let v = tables[table]?[key] else { return nil }
            if let t = read(v) { return t }
            problems.append("config.toml: [\(table)] \(key) has the wrong type")
            return nil
        }
        if let n = get("swipe", "fingers", { if case .number(let n) = $0 { n } else { nil } }) { p.fingers = Int(n) }
        if let b = get("swipe", "natural", { if case .bool(let b) = $0 { b } else { nil } }) { p.natural = b }
        if let n = get("layout", "gap", { if case .number(let n) = $0 { n } else { nil } }) { p.gap = n }
        if let l = get("apps", "float", { if case .strings(let l) = $0 { l } else { nil } }) { p.floatApps = l }
        return (p.sanitized(), problems)
    }

    func sanitized() -> Prefs {
        var p = self
        if p.fingers != 3 { p.fingers = 4 }
        p.gap = p.gap.isFinite ? min(max(p.gap, 0), Prefs.maxGap) : 8
        var seen = Set<String>()
        p.floatApps = p.floatApps.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
        return p
    }

    /// This part of config.toml: only the sections that differ from the defaults.
    func configText() -> String {
        let d = Prefs()
        var out = ""
        if fingers != d.fingers || natural != d.natural {
            out += "\n[swipe]\nfingers = \(fingers)\nnatural = \(natural)\n"
        }
        if gap != d.gap {
            out += "\n[layout]\ngap = \(gap)\n"
        }
        if floatApps != d.floatApps {
            out += "\n[apps]\nfloat = [\(floatApps.map(Config.quote).joined(separator: ", "))]\n"
        }
        return out
    }

    private static let lock = NSLock()
    private static var _current = Prefs()

    static var current: Prefs {
        get { lock.withLock { _current } }
        set {
            lock.withLock { _current = newValue }
            Touch.fingers = newValue.fingers
            Touch.natural = newValue.natural
        }
    }

    /// Change the preferences: apply them at once, tell the engine, and save.
    static func change(_ update: (inout Prefs) -> Void) {
        let old = current
        var new = old
        update(&new)
        new = new.sanitized()
        guard new != old else { return }
        current = new
        if new.gap != old.gap { Engine.shared?.send(.setGap(new.gap)) }
        if new.floatApps != old.floatApps { Engine.shared?.send(.setFloatApps(new.floatApps)) }
        Config.save(keymap: Keymap.current, prefs: new)
    }
}
