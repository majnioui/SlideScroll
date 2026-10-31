import Foundation

/// Preferences other than shortcuts: swipes, the gap between windows, the
/// apps that always float, and the widths some apps' windows open at. They live in config.toml beside `[keys]`.
struct Prefs: Equatable {
    /// Gap sizes offered in Settings, in points.
    static let gaps: [Double] = [0, 4, 8, 12, 16, 24]
    static let maxGap = 32.0
    /// Widths an app's new windows can open at, as fractions of the screen,
    /// with their config spelling. The same presets `⌃⌥R` cycles through.
    static let widths: [(String, Double)] = [
        ("1/4", 0.25), ("1/3", 1.0 / 3), ("1/2", 0.5), ("2/3", 2.0 / 3), ("3/4", 0.75), ("full", 1),
    ]

    /// Fingers for a strip swipe: 3 or 4.
    var fingers = Prefs.defaultFingers
    /// The strip moves with the fingers, like scrolling a page. Off, it moves
    /// the other way, like moving a viewport over it.
    var natural = true
    /// Space between windows and around the strip, in points.
    var gap = 8.0
    /// Apps, by name, whose windows never join the strip.
    var floatApps: [String] = []
    /// Apps, by name, whose new windows open at this fraction of the screen
    /// instead of half. Windows from the saved layout keep their own width.
    var appWidths: [String: Double] = [:]

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
        for (app, v) in tables["apps.width"] ?? [:] {
            if let f = Prefs.widthFraction(v) {
                p.appWidths[app] = f
            } else {
                problems.append("config.toml: [apps.width] \(Config.quote(app)) should be one of \(widths.map { "\"\($0.0)\"" }.joined(separator: ", ")), or a number between 0 and 1")
            }
        }
        return (p.sanitized(), problems)
    }

    /// `"1/3"`, `"full"` or a plain fraction such as `0.4`.
    static func widthFraction(_ v: Config.Value) -> Double? {
        switch v {
        case .string(let s): widths.first { $0.0 == s.lowercased().replacingOccurrences(of: " ", with: "") }?.1
        case .number(let n) where n > 0 && n <= 1: n
        default: nil
        }
    }

    /// How a width is written in config.toml and shown in Settings.
    static func widthName(_ f: Double) -> String {
        widths.first { abs($0.1 - f) < 0.001 }?.0 ?? f.formatted()
    }

    func sanitized() -> Prefs {
        var p = self
        if p.fingers != 3 { p.fingers = 4 }
        p.gap = p.gap.isFinite ? min(max(p.gap, 0), Prefs.maxGap) : 8
        var seen = Set<String>()
        p.floatApps = p.floatApps.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
        p.appWidths = p.appWidths.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && $0.value > 0 && $0.value <= 1 }
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
        if appWidths != d.appWidths {
            out += "\n[apps.width]\n"
            for app in appWidths.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                let f = appWidths[app]!
                let value = Prefs.widths.contains { abs($0.1 - f) < 0.001 } ? Config.quote(Prefs.widthName(f)) : "\(f)"
                out += "\(Config.quote(app)) = \(value)\n"
            }
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
