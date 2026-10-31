import CryptoKit
import Foundation

/// Updates from GitHub Releases, the same way `site/install.sh` installs:
/// find the latest release, download its zip, check it against the release's
/// SHA256SUMS and unpack it beside the running app. Once it's ready, the menu
/// and Settings offer to restart into it; the swap happens then, never while
/// SlideScroll is moving windows.
enum Update {
    static let repo = "majnioui/SlideScroll"
    private static let appName = "SlideScroll.app"
    /// Gives the Mac time to settle after login before the first check.
    private static let firstCheckAfter: UInt64 = 30
    private static let checkEvery: UInt64 = 6 * 60 * 60
    /// Where an update is unpacked: beside the app, so the swap is a rename on
    /// the same volume.
    private static let staging = ".SlideScroll-update"

    enum State: Equatable {
        /// Not checked yet.
        case idle
        case checking
        case upToDate
        case downloading(String)
        /// Downloaded, verified and unpacked; restarting installs it.
        case ready(String)
        case installing
        case failed(String)
        /// SlideScroll can't update itself here; the reason, for Settings.
        case unavailable(String)
    }

    /// The installed app and its identifier, once the updater is running.
    private static var app: (url: URL, id: String)?
    private static var checker: Task<Void, Never>?

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.2"
    }

    /// Show the state in the menu and Settings.
    private static func set(_ state: State) {
        DispatchQueue.main.async { AppModel.shared.update = state }
    }

    private static var state: State {
        get async { await MainActor.run { AppModel.shared.update } }
    }

    /// Whether to check on a schedule. On unless the user turned it off.
    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "CheckForUpdates") == nil || UserDefaults.standard.bool(forKey: "CheckForUpdates") }
        set {
            UserDefaults.standard.set(newValue, forKey: "CheckForUpdates")
            if newValue { checkNow() }
        }
    }

    /// Start checking in the background. Call once, at startup.
    static func start() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", let id = Bundle.main.bundleIdentifier else {
            set(.unavailable("Updates work when SlideScroll runs as an app."))
            return
        }
        // Homebrew keeps track of what it installed; replacing it here would
        // leave Homebrew thinking the old version is still there.
        if isHomebrew(url) {
            set(.unavailable("Installed with Homebrew: update with brew upgrade slidescroll."))
            return
        }
        app = (url, id)
        schedule(after: firstCheckAfter, asked: false)
    }

    /// Check now, from the menu or Settings.
    static func checkNow() {
        guard app != nil else { return }
        schedule(after: 0, asked: true)
    }

    private static func schedule(after seconds: UInt64, asked: Bool) {
        checker?.cancel()
        checker = Task.detached(priority: .utility) {
            var wait = seconds
            var asked = asked
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                if Task.isCancelled { return }
                switch await state {
                case .ready, .installing: break
                default: if asked || autoCheck { await check() }
                }
                asked = false
                wait = checkEvery
            }
        }
    }

    private static func check() async {
        guard let app else { return }
        set(.checking)
        do {
            let latest = try await latestVersion()
            guard isNewer(latest, than: version) else {
                Log.debug("update check: \(latest) is the latest, running \(version)")
                return set(.upToDate)
            }
            Log.info("SlideScroll \(latest) is available; downloading it")
            set(.downloading(latest))
            try await stage(app: app.url, id: app.id, version: latest)
            Log.info("SlideScroll \(latest) is downloaded, verified and ready to install")
            set(.ready(latest))
        } catch {
            Log.info("update check failed: \(error)")
            set(.failed("\(error)"))
        }
    }

    /// Whether the app sits in a Homebrew Cellar (or its `opt` link).
    static func isHomebrew(_ url: URL) -> Bool {
        [url, url.resolvingSymlinksInPath()].contains { $0.pathComponents.contains("Cellar") }
    }

    /// The latest release's version: its page redirects to `.../tag/v<version>`.
    private static func latestVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let url = response.url?.absoluteString, let v = versionFromTagURL(url) else {
            throw ConfigProblem("unexpected release address \(response.url?.absoluteString ?? "none")")
        }
        return v
    }

    static func versionFromTagURL(_ url: String) -> String? {
        guard let range = url.range(of: "/v", options: .backwards) else { return nil }
        let v = String(url[range.upperBound...])
        return !v.isEmpty && v.contains(".") && v.allSatisfy({ $0.isNumber || $0 == "." }) ? v : nil
    }

    /// Whether `a` is a later version than `b`, comparing dotted numbers.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let parts = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        return parts(b).lexicographicallyPrecedes(parts(a))
    }

    /// The checksum SHA256SUMS lists for `file`.
    static func expectedSum(_ sums: String, file: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == file { return parts[0].lowercased() }
        }
        return nil
    }

    private static func stagingDir(_ app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(staging)
    }

    private static func download(_ url: URL, to dest: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConfigProblem("download failed: \(url.lastPathComponent)") }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Download, verify and unpack `version` into the staging folder.
    private static func stage(app: URL, id: String, version: String) async throws {
        let fm = FileManager.default
        let dir = stagingDir(app)
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ConfigProblem("can't write beside the app in \(dir.path): \(error.localizedDescription)")
        }
        let base = "https://github.com/\(repo)/releases/download/v\(version)"
        let zipName = "SlideScroll-\(version).zip"
        let zip = dir.appendingPathComponent(zipName), sums = dir.appendingPathComponent("SHA256SUMS")
        try await download(URL(string: "\(base)/\(zipName)")!, to: zip)
        try await download(URL(string: "\(base)/SHA256SUMS")!, to: sums)
        guard let expected = expectedSum(try String(contentsOf: sums, encoding: .utf8), file: zipName) else {
            throw ConfigProblem("SHA256SUMS has no entry for \(zipName)")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            try? fm.removeItem(at: dir)
            throw ConfigProblem("the download doesn't match its checksum")
        }
        let unpacked = dir.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let info = NSDictionary(contentsOf: unpacked.appendingPathComponent("\(appName)/Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == id else { throw ConfigProblem("the download isn't SlideScroll") }
        guard info?["CFBundleShortVersionString"] as? String == version else { throw ConfigProblem("the download isn't version \(version)") }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ConfigProblem("\(tool) failed") }
    }

    /// Swap the staged update in and start it once this process has quit.
    /// The caller then quits the way the menu does, so windows go back on screen.
    static func installAndRelaunch() throws {
        guard case .ready(let version) = AppModel.shared.update else { throw ConfigProblem("no update is ready") }
        guard let app else { throw ConfigProblem("not running as an app") }
        let fm = FileManager.default
        let dir = stagingDir(app.url)
        let newApp = dir.appendingPathComponent("unpacked/\(appName)")
        let oldApp = dir.appendingPathComponent("previous.app")
        AppModel.shared.update = .installing
        do {
            try fm.moveItem(at: app.url, to: oldApp)
            do {
                try fm.moveItem(at: newApp, to: app.url)
            } catch {
                try? fm.moveItem(at: oldApp, to: app.url)
                throw ConfigProblem("can't put the new app in place: \(error.localizedDescription)")
            }
        } catch {
            AppModel.shared.update = .failed("\(error)")
            throw error
        }
        Log.info("installed SlideScroll \(version); restarting into it")
        // Wait for this process to exit, clear the staging folder (the old app
        // included) and open the new app. Detached, so it outlives us.
        let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; rm -rf "$2"; open "$3""#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "(\(script)) &", "sh", "\(getpid())", dir.path, app.url.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
