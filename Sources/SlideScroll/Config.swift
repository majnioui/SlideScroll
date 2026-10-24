import Foundation

/// `~/Library/Application Support/slidescroll/config.toml`: `[keys]` for
/// shortcuts, then `[swipe]`, `[layout]` and `[apps]`. Only what differs from
/// the defaults is written, so settings added later get their defaults.
///
/// The file only ever holds tables of strings, numbers, booleans and lists of
/// strings, so this reads and writes that much of TOML and nothing more.
enum Config {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/slidescroll/config.toml")
    }

    enum Value: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case strings([String])
    }

    typealias Tables = [String: [String: Value]]

    struct ParseError: Error, CustomStringConvertible {
        let line: Int
        let message: String
        var description: String { "config.toml: line \(line): \(message)" }
    }

    static func parse(_ text: String) throws -> Tables {
        var tables: Tables = [:]
        var table = ""
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError(line: i + 1, message: "unclosed table name") }
                table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                tables[table, default: [:]] = tables[table] ?? [:]
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw ParseError(line: i + 1, message: "expected key = value")
            }
            var key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 { key = String(key.dropFirst().dropLast()) }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            tables[table, default: [:]][key] = try parseValue(value, line: i + 1)
        }
        return tables
    }

    /// The line up to a `#` that isn't inside a string.
    private static func stripComment(_ line: String) -> Substring {
        var inString = false
        var escaped = false
        for i in line.indices {
            let c = line[i]
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == "#" && !inString { return line[..<i] }
        }
        return Substring(line)
    }

    private static func parseValue(_ s: String, line: Int) throws -> Value {
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if s.hasPrefix("\"") { return .string(try parseString(s, line: line)) }
        if s.hasPrefix("[") {
            guard s.hasSuffix("]") else { throw ParseError(line: line, message: "unclosed list") }
            let inner = s.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .strings([]) }
            return .strings(try splitList(inner, line: line).map { try parseString($0, line: line) })
        }
        if let n = Double(s.replacingOccurrences(of: "_", with: "")) { return .number(n) }
        throw ParseError(line: line, message: "can't read the value \(s)")
    }

    private static func splitList(_ s: String, line: Int) throws -> [String] {
        var items: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && inString { current.append(c); escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == "," && !inString {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { items.append(last) }
        return items
    }

    private static func parseString(_ s: String, line: Int) throws -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else {
            throw ParseError(line: line, message: "expected a quoted string, found \(s)")
        }
        var out = ""
        var escaped = false
        for c in s.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func read() -> (Tables, [String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([:], []) }
        do {
            return (try parse(text), [])
        } catch {
            return ([:], ["\(error)"])
        }
    }

    /// Write the whole file: shortcuts, then preferences. Write then rename,
    /// so a crash mid-write never leaves a broken file.
    static func save(keymap: Keymap, prefs: Prefs) {
        let text = keymap.configText() + prefs.configText()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            Log.info("couldn't save config.toml: \(error)")
        }
    }
}
