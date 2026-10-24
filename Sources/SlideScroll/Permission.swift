import CryptoKit
import Foundation

/// Getting the Accessibility permission back after an update or reinstall.
///
/// macOS grants the permission to one particular build: an ad-hoc signed app
/// is identified by the hash of its code. A new build finds SlideScroll in
/// Privacy & Security → Accessibility, still switched on, but that entry is
/// the old build's and turning it on does nothing for this one. So the first
/// time a build isn't trusted, the old entry is removed before macOS is asked,
/// and the list then shows one that works.
enum Permission {
    /// Ask for the permission, showing macOS's prompt. Returns whether we have it.
    static func request() -> Bool {
        if AX.isTrusted(prompt: false) { return true }
        forgetOlderBuilds()
        return AX.isTrusted(prompt: true)
    }

    /// Remove SlideScroll's Accessibility entry, once per build, so a stale one
    /// from an earlier build can't stand in for this one.
    private static func forgetOlderBuilds() {
        guard let bundleID = Bundle.main.bundleIdentifier, let build = buildHash else { return }
        let key = "AccessibilityResetForBuild"
        if UserDefaults.standard.string(forKey: key) == build { return }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", bundleID]
        let err = Pipe()
        tccutil.standardError = err
        do {
            try tccutil.run()
            tccutil.waitUntilExit()
            if tccutil.terminationStatus == 0 {
                Log.info("cleared the Accessibility entry left by an earlier build")
            } else {
                let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                Log.info("tccutil reset failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            Log.info("can't run tccutil: \(error)")
        }
        // Once per build: a second reset would remove the entry the user is
        // about to switch on for this one.
        UserDefaults.standard.set(build, forKey: key)
    }

    /// The executable's SHA-256, which changes with every build.
    private static var buildHash: String? {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
