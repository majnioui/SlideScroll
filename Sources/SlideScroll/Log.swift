import Foundation

/// The log file, `~/Library/Logs/SlideScroll/slidescroll.log`. Every line also
/// goes to stderr, so running from a terminal still shows everything.
///
/// `Log.info` is for things worth keeping; `Log.debug` only writes in verbose
/// mode (`SLIDESCROLL_DEBUG` set, or turned on in Settings).
enum Log {
    /// Past this size the log is moved to `slidescroll.old.log` on startup.
    private static let maxSize = 2 * 1024 * 1024
    private static let queue = DispatchQueue(label: "slidescroll.log")
    private static var file: FileHandle?
    private static let lock = NSLock()
    private static var _verbose = false

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SlideScroll/slidescroll.log")
    }

    /// Start logging to stderr and the log file. Logging still goes to stderr
    /// if the file can't be opened.
    static func start() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxSize {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            file = try FileHandle(forWritingTo: url)
            file?.seekToEndOfFile()
        } catch {
            FileHandle.standardError.write(Data("slidescroll: can't open the log file: \(error)\n".utf8))
        }
        verbose = ProcessInfo.processInfo.environment["SLIDESCROLL_DEBUG"] != nil
    }

    static var verbose: Bool {
        get { lock.withLock { _verbose } }
        set { lock.withLock { _verbose = newValue } }
    }

    static func info(_ message: @autoclosure () -> String) {
        write("INFO", message())
    }

    static func debug(_ message: @autoclosure () -> String) {
        if verbose { write("DEBUG", message()) }
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Written in order on a queue of its own, so logging never blocks a frame.
    private static func write(_ level: String, _ message: String) {
        let date = Date()
        queue.async {
            let line = Data("\(stamp.string(from: date)) [\(level)] \(message)\n".utf8)
            FileHandle.standardError.write(line)
            file?.write(line)
        }
    }
}
