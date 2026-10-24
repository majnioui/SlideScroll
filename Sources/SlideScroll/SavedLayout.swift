import Foundation

/// The strips as last saved, `~/Library/Application Support/slidescroll/layout.json`,
/// so column order, widths and stacks survive restarts.
struct SavedLayout: Codable {
    var columns: [SavedColumn] = []

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/slidescroll/layout.json")
    }

    static func load() -> SavedLayout {
        guard let data = try? Data(contentsOf: url),
              let saved = try? decoder.decode(SavedLayout.self, from: data) else { return SavedLayout() }
        return saved
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: SavedLayout.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic: a crash mid-write never leaves a broken file.
            try SavedLayout.encoder.encode(self).write(to: SavedLayout.url, options: .atomic)
        } catch {
            Log.info("could not save layout: \(error)")
        }
    }

    /// Position in the saved strip of the column this window belonged to:
    /// by window ID, or by app and title after a relaunch or reboot.
    func find(id: UInt32, app: String, title: String) -> Int? {
        columns.firstIndex { $0.id == id && $0.app == app }
            ?? columns.firstIndex { $0.app == app && $0.title == title && !title.isEmpty }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

struct SavedColumn: Codable {
    /// CGWindowID: stable while the app keeps running.
    var id: UInt32
    /// App and window title: the fallback after an app relaunch or reboot.
    var app: String
    var title: String
    var width: Double
    var restoreWidth: Double?
    /// In the same column (stack) as the entry before it.
    var stacked = false
    /// Relative height within its stack.
    var weight = 1.0
    /// The column is tabbed (set on the column's first entry).
    var tabbed = false
    /// SlideScroll made it tabbed because its windows didn't fit as a stack.
    var autoTabbed = false
    /// CGDirectDisplayID of the display whose strip it was on.
    var display: UInt32 = 0
    /// A lone window's own height, as a fraction of the full height.
    var height: Double?
    /// In a stack: the width the window had as a column of its own.
    var ownWidth: Double?

    init(id: UInt32, app: String, title: String, width: Double, restoreWidth: Double?, stacked: Bool,
         weight: Double, tabbed: Bool, autoTabbed: Bool, display: UInt32, height: Double?, ownWidth: Double?) {
        self.id = id
        self.app = app
        self.title = title
        self.width = width
        self.restoreWidth = restoreWidth
        self.stacked = stacked
        self.weight = weight
        self.tabbed = tabbed
        self.autoTabbed = autoTabbed
        self.display = display
        self.height = height
        self.ownWidth = ownWidth
    }

    // Entries written by older versions lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt32.self, forKey: .id)
        app = try c.decode(String.self, forKey: .app)
        title = try c.decode(String.self, forKey: .title)
        width = try c.decode(Double.self, forKey: .width)
        restoreWidth = try c.decodeIfPresent(Double.self, forKey: .restoreWidth)
        stacked = try c.decodeIfPresent(Bool.self, forKey: .stacked) ?? false
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1
        tabbed = try c.decodeIfPresent(Bool.self, forKey: .tabbed) ?? false
        autoTabbed = try c.decodeIfPresent(Bool.self, forKey: .autoTabbed) ?? false
        display = try c.decodeIfPresent(UInt32.self, forKey: .display) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height)
        ownWidth = try c.decodeIfPresent(Double.self, forKey: .ownWidth)
    }
}
