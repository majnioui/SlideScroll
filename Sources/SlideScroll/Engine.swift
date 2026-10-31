import CoreGraphics
import Foundation
import SlideScrollCore

/// Seconds since boot: a monotonic clock for timing frames and grace periods.
private func now() -> Double { ProcessInfo.processInfo.systemUptime }

private let peek = 8.0
private let minWidth = 200.0
/// Time between frames when the display doesn't time them (macOS 13).
private let frameTime = 1.0 / 120
/// Longest wait for a frame from the display before stepping without one,
/// e.g. while the display is asleep.
private let frameTimeout = 0.040
/// How often to check which window has focus when idle (a fallback for missed events).
private let focusPoll = 0.300
/// How often to rescan all windows when idle (a fallback for missed events).
private let rescanEvery = 2.0
/// How often to check for mouse release while the user is dragging.
private let dragPoll = 0.030
/// Strip points scrolled per full trackpad width swiped, as a multiple of the viewport width.
private let swipeSpeed = 1.5
/// How far a released swipe coasts, in seconds of its final speed.
private let swipeMomentum = 0.15
/// How long a column's slot is held for a tab of the same app to arrive.
private let tabSwitchWindow = 1.5
/// Longest a focus we asked for is waited on before macOS's own idea of
/// the focused window counts again.
private let focusLandsWithin = 1.0
/// Moves reported this soon after we moved a window are taken to be ours.
private let ownMoveGrace = 0.5
/// Dropping a window with the pointer in this top or bottom fraction of
/// another window stacks it above or below that window.
private let stackZone = 0.25
/// Windows are dragged by their title bar, so a drag along the top of the
/// screen keeps the pointer this close to the top of every window it
/// passes. The "stack above" zone starts below it, or every sideways drag
/// would stack.
private let titleBand = 60.0
/// After a drag, how long a dropped window must stay still before it's
/// placed, how long to wait at least (macOS tiling starts its snap a moment
/// after the mouse lets go), and at most.
private let settleStill = 0.060
private let settleMin = 0.120
private let settleMax = 0.800
/// During a swipe, check this often that the Space hasn't changed.
private let spaceCheckEvery = 0.100
/// Saved entries kept for windows that aren't open right now.
private let maxSaved = 100

typealias WID = CGWindowID

/// A window's springs and what we last did to it.
private struct Anim {
    var x: Spring
    var y: Spring
    /// Last position sent to the window, rounded to whole points.
    var applied: CGPoint
    /// Its size as last read back from the app.
    var appliedSize: CGSize
    /// A size asked for that the app hasn't reported back yet.
    var resizing: CGSize?
    /// The size the app last answered for: asking for it again would only
    /// get the same answer.
    var answered: CGSize?
    /// When we last moved or resized this window ourselves.
    var lastSet = now()
    /// Checked where it really ended up since we last moved it.
    var verified = true
    /// macOS gave it a smaller size than asked while it was still on its way
    /// to a new spot; ask again once it has landed.
    var resizeAgain = false
    /// The shortest its app will make it, once it has refused to go shorter.
    var minHeight = 0.0

    init(at p: CGPoint, size: CGSize) {
        x = Spring(p.x)
        y = Spring(p.y)
        applied = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        appliedSize = size
    }

    /// The window is this size now, whatever we last asked for.
    mutating func hasSize(_ s: CGSize) {
        appliedSize = s
        resizing = nil
        answered = nil
    }

    mutating func jump(to p: CGPoint) {
        x = Spring(p.x)
        y = Spring(p.y)
    }

    /// Aim at a new spot, keeping current velocity so motion stays continuous.
    mutating func aim(_ x: Double, _ y: Double, stiffness: Double) {
        self.x.target = x
        self.y.target = y
        self.x.stiffness = stiffness
        self.y.stiffness = stiffness
    }

    var needsFrame: Bool {
        !x.isSettled || !y.isSettled || applied != CGPoint(x: x.target.rounded(), y: y.target.rounded())
    }
}

/// A dragged window as the mouse let go of it.
private struct Release {
    /// Its frame and the pointer at that moment: where the user dropped it,
    /// whatever macOS does with it afterwards.
    var p: CGPoint
    var s: CGSize
    var mouse: CGPoint
    /// Its frame at the last look, and since when it hasn't changed.
    var seen: CGRect
    var stillSince: Double
}

/// One display and its strip.
private struct Monitor {
    var display: Display
    var strip: Strip<WID>
    /// None of this strip's windows is on screen: the display shows another
    /// Space or a full-screen app. The strip is left alone until it's back.
    var away = false

    init(_ display: Display, gap: Double) {
        self.display = display
        strip = Strip(gap: gap, peek: peek)
        setGap(gap)
    }

    mutating func setGap(_ gap: Double) {
        strip.gap = gap
        strip.tabBar = tabBarHeight + gap
        clampWidths()
    }

    var viewport: Rect { display.visible }

    /// Width of a new window: half of the space between the pinned columns.
    var halfWidth: Double { strip.presetWidth(0.5, strip.inner(viewport).w) }

    var fullWidth: Double { strip.presetWidth(1, viewport.w) }

    var windowIDs: [WID] { strip.allColumns.flatMap(\.windows) }

    /// Keep every column narrower than the display, e.g. after it got smaller.
    mutating func clampWidths() {
        let full = fullWidth
        for i in strip.columns.indices { strip.columns[i].width = min(strip.columns[i].width, full) }
        for s in 0..<2 {
            if let w = strip.pinned[s]?.width { strip.pinned[s]?.width = min(w, full) }
        }
    }
}

/// What a saved layout records about one window, rounded so that tiny
/// changes don't count.
private struct SignatureEntry: Equatable {
    let display: UInt32, window: WID, column: Int, width: Int, weight: Int, tabbed: Bool, height: Int?
}

/// A window found by a rescan, with where the saved layout puts it.
private struct Found {
    let order: Int
    let x: Double
    let saved: Int?
    let window: Window
}

/// Owns one strip per display and the windows on them, and drives the
/// animation. Everything runs on its own serial queue, so slow Accessibility
/// calls never block the event tap or the UI.
final class Engine {
    static var shared: Engine?

    private let queue = DispatchQueue(label: "engine", qos: .userInteractive)
    private let timer: DispatchSourceTimer

    /// Left to right; never empty.
    private var monitors: [Monitor]
    /// The monitor shortcuts act on: the one with the focused window.
    private var active = 0
    private var windows: [WID: Window] = [:]
    private var anims: [WID: Anim] = [:]
    private let mover = Mover()
    private let focuser = Focuser()
    /// The window we last asked to focus, and when, until it has focus:
    /// meanwhile macOS still reports the previous window as focused, which
    /// mustn't count as the user focusing it.
    private var focusing: (id: WID, at: Double)?
    /// Windows the user is moving with the mouse; left alone until release.
    private var dragging = Set<WID>()
    /// Dragged windows the mouse has let go of, still left alone while macOS
    /// may be moving them (e.g. tiling snaps one dropped near a screen edge);
    /// placing them at once would fight that animation and shake the window.
    private var released: [WID: Release] = [:]
    /// When the mouse let go, if dragged windows are waiting to be placed.
    private var releasedAt: Double?
    /// Whether the current swipe is ours (decided when it starts).
    private var swipeOK: Bool?
    /// The monitor the current swipe scrolls: the one under the pointer when it started.
    private var swipeMonitor = 0
    /// Scroll offset when the current swipe started, to undo it if aborted.
    private var swipeStartScroll = 0.0
    /// When the current swipe last checked that its Space is still on screen.
    private var swipeChecked = now()
    /// When we last undid an outside move of a window, and where it had gone.
    private var externalFixes: [WID: (at: Double, p: CGPoint)] = [:]
    /// Lone windows narrower than their column at the last check, and how wide.
    private var tooNarrow: [WID: Double] = [:]
    /// Columns that just lost their window: a window from the same app
    /// appearing moments later takes the slot back.
    private var recentGone: [(display: UInt32, pid: pid_t, index: Int, width: Double, at: Double)] = []
    /// A focus change arrived while the mouse was down; handle it on release
    /// so clicking a window to drag it doesn't scroll it away under the cursor.
    private var focusPending = false
    /// The window that focus moved to while the mouse was down, if known.
    private var pendingFocusID: WID?
    /// Windows the user floated with ⌃⌥T; they stay put and aren't in the strip.
    private var floating = Set<WID>()
    /// Layout from the last run, plus anything saved since.
    private var saved = SavedLayout.load()
    /// Space between windows and around the strip.
    private var gap: Double
    /// Apps, by name, whose windows always float.
    private var floatApps: Set<String>
    /// Windows go straight to their new places instead of gliding there.
    private var reduceMotion = false
    /// App name per window, looked up once.
    private var appNames: [WID: String] = [:]
    /// Window titles, for tab bars and the menu, refreshed on every rescan.
    private var titles: [WID: String] = [:]
    /// Order and widths as of the last save, to know when to save again.
    private var savedSignature: [SignatureEntry] = []
    /// The tab bars last handed to the UI.
    private var shownBars: [TabBar] = []
    /// The focus border last handed to the UI.
    private var shownBorder: Overlays.Border?
    /// The strip's windows last handed to the menu.
    private var shownWindows: [StripWindow] = []
    /// Every strip's arrangement before each layout change, newest last,
    /// and the ones undone since, to redo.
    private var undoHistory: [[UInt32: Arrangement<WID>]] = []
    private var redoHistory: [[UInt32: Arrangement<WID>]] = []
    /// The focused window as of the last event, and the one before it.
    private var lastFocus: WID?
    private var previousFocus: WID?
    /// The first scan has happened: windows found from now on are new.
    private var scanned = false
    /// The drop highlight last handed to the UI.
    private var dropHint: Rect?
    /// Paused from the menu: windows are left alone.
    private var paused = false
    /// Asleep, locked or switched away: everything waits for `wake`.
    private var suspended = false
    /// Columns of displays that were disconnected, by display, to put back
    /// if the display comes back.
    private var exiled: [UInt32: [Column<WID>]] = [:]

    // The clock: when the last animation step ran, the display frames come
    // from while animating, and when the last one is shown.
    private var lastFrame = now()
    private var lastRescan = now()
    private var clock: CGDirectDisplayID?
    private var shownAt: Double?
    /// State as of the end of the last event, which decides what a timer firing means.
    private var wasAnimating = false
    private var wasWaitingForRelease = false

    init(displays: [Display]) {
        precondition(!displays.isEmpty, "no displays")
        let prefs = Prefs.current
        gap = prefs.gap
        floatApps = Set(prefs.floatApps)
        monitors = displays.map { Monitor($0, gap: prefs.gap) }
        timer = DispatchSource.makeTimerSource(queue: queue)
        updateParking()
    }

    /// Start managing windows.
    func start() {
        Engine.shared = self
        timer.setEventHandler { [unowned self] in timerFired() }
        timer.resume()
        queue.async { [self] in
            rescan()
            syncFocus()
            retarget()
            finish()
        }
    }

    /// Handle `command` on the engine's queue. Callable from any thread.
    func send(_ command: Command) {
        queue.async { [self] in
            receive(command)
            finish()
        }
    }

    // MARK: - The clock

    private var isAnimating: Bool {
        if paused || suspended { return false }
        return anims.contains { !dragging.contains($0.key) && $0.value.needsFrame }
    }

    /// The display whose frames time the animation: the one being swiped, or the active one.
    private var animatedDisplay: CGDirectDisplayID {
        let mi = swipeOK == true ? swipeMonitor : active
        return (monitors.indices.contains(mi) ? monitors[mi] : monitors[0]).display.id
    }

    private func receive(_ command: Command) {
        switch command {
        case .frame(let at):
            if clock != nil && isAnimating {
                let since = shownAt.map { at - $0 } ?? now() - lastFrame
                shownAt = at
                step(min(max(since, 0), 1.0 / 30))
                lastFrame = now()
            }
        case .displaysChanged:
            // The display link went with the old displays.
            clock = nil
            handle(command)
        default:
            handle(command)
        }
    }

    private func timerFired() {
        if wasWaitingForRelease {
            let down = AX.mouseDown
            if releasedAt != nil {
                // Pressed again before they settled: place them now.
                if down || dropsSettled() { finishDrags() }
            } else if !down {
                releaseDrags()
            } else {
                showDropHint()
            }
        } else if !wasAnimating && !paused && !suspended && !AX.mouseDown {
            idleCheck()
        }
        finish()
    }

    /// The quiet-time checks: settled windows are where we put them, sizes
    /// cut short get asked again, focus is in sync, windows are rescanned
    /// now and then, and the layout is saved when it changed.
    private func idleCheck() {
        // Once a window has settled, check it really is where we put it:
        // macOS tiling can move it while our own moves are still landing.
        let t = now()
        var settled: [WID] = []
        for (id, a) in anims where !a.verified && t - a.lastSet >= ownMoveGrace {
            anims[id]?.verified = true
            settled.append(id)
        }
        settled.forEach(checkExternalMove)
        var askAgain = false
        for (id, a) in anims where a.resizeAgain && t - a.lastSet >= ownMoveGrace {
            anims[id]?.resizeAgain = false
            anims[id]?.answered = nil
            askAgain = true
        }
        if askAgain { retarget() }
        var changed = syncFocus()
        if t - lastRescan >= rescanEvery {
            changed = rescan() || changed
            changed = fitNarrowColumns() || changed
            lastRescan = now()
        }
        if changed {
            retarget()
        } else if signature() != savedSignature {
            saveLayout()
        }
    }

    /// After every event: step the animation if a frame is due, show tab bars
    /// where they are now, and set the timer for whatever comes next.
    private func finish() {
        if isAnimating {
            if !wasAnimating {
                // Just started: the first step is one frame, not the time spent idle.
                lastFrame = now() - frameTime
            }
            let due = clock != nil && shownAt != nil ? frameTimeout : frameTime
            if now() - lastFrame >= due {
                step(min(now() - lastFrame, 1.0 / 30))
                lastFrame = now()
                shownAt = nil
            }
        } else {
            lastFrame = now()
        }
        publishTabBars()
        trackFocus()
        publishWindows()
        publishFocusBorder()

        let animating = isAnimating
        let wantClock = animating && FrameClock.available ? animatedDisplay : nil
        if wantClock != clock {
            FrameClock.run(on: wantClock)
            clock = wantClock
            shownAt = nil
        }
        // Until the display's frames come in, or if they stop, keep time ourselves.
        let due = clock != nil && shownAt != nil ? frameTimeout : frameTime
        let waitingForRelease = !dragging.isEmpty || focusPending
        let wait = animating ? max(due - (now() - lastFrame), 0) : waitingForRelease ? dragPoll : focusPoll
        wasAnimating = animating
        wasWaitingForRelease = waitingForRelease
        timer.schedule(deadline: .now() + wait, leeway: .milliseconds(animating ? 1 : 10))
    }

    private func step(_ dt: Double) {
        let t = now()
        for id in anims.keys where !dragging.contains(id) {
            anims[id]!.x.step(dt)
            anims[id]!.y.step(dt)
            let a = anims[id]!
            let p = CGPoint(x: a.x.value.rounded(), y: a.y.value.rounded())
            if p != a.applied {
                if let win = windows[id] { mover.setPosition(win, p.x, p.y) }
                anims[id]!.applied = p
                anims[id]!.lastSet = t
                anims[id]!.verified = false
            }
        }
    }

    // MARK: - Displays

    /// Where columns that scroll off each side of each display are parked.
    /// Beside the display, most of a parked window would be on the
    /// neighbouring display (and with separate Spaces macOS moves it there),
    /// so on a side with a neighbour they drop below the bottom edge instead,
    /// whichever overlaps the other displays less.
    private func updateParking() {
        let frames = monitors.map(\.display.frame)
        for i in monitors.indices {
            let onOthers = { (r: Rect) in frames.enumerated().filter { $0.offset != i }.reduce(0) { $0 + overlap(r, $1.element) } }
            let vp = monitors[i].viewport
            let f = monitors[i].display.frame
            let below = f.y + f.h - peek
            for side in [LEFT, RIGHT] {
                // A full-width window is the worst case.
                let x = side == LEFT ? vp.x + peek - vp.w : vp.x + vp.w - peek
                let beside = Rect(x: x, y: vp.y, w: vp.w, h: vp.h)
                let under = Rect(x: x, y: below, w: vp.w, h: vp.h)
                monitors[i].strip.parkY[side] = onOthers(under) < onOthers(beside) ? below : nil
            }
        }
    }

    /// Take a new set of displays. Strips stay with their display; the
    /// columns of a display that's gone join the end of the first one.
    private func setDisplays(_ displays: [Display]) {
        // Every display asleep or mid-reconfiguration: keep what we have.
        guard !displays.isEmpty else { return }
        let activeID = monitors[active].display.id
        var old = monitors
        // What undo would put back may be on a display that's gone.
        if Set(displays.map(\.id)) != Set(old.map(\.display.id)) {
            undoHistory = []
            redoHistory = []
        }
        monitors = displays.map { d in
            if let i = old.firstIndex(where: { $0.display.id == d.id }) {
                var m = old.remove(at: i)
                m.display = d
                return m
            }
            return Monitor(d, gap: gap)
        }
        for gone in old {
            Log.debug("display \(gone.display.id) is gone; its columns move to display \(monitors[0].display.id)")
            let columns = gone.strip.allColumns
            exiled[gone.display.id] = columns
            monitors[0].strip.columns += columns
        }
        // A display that's back gets its columns back, minus windows closed since.
        for mi in monitors.indices {
            let id = monitors[mi].display.id
            guard let columns = exiled.removeValue(forKey: id) else { continue }
            Log.debug("display \(id) is back; its columns return to it")
            for var col in columns {
                col.retain { windows[$0] != nil && !floating.contains($0) }
                if col.windows.isEmpty { continue }
                for w in col.windows {
                    if let from = monitorOf(w) { monitors[from].strip.remove(w) }
                }
                monitors[mi].strip.columns.append(col)
            }
        }
        for i in monitors.indices { monitors[i].clampWidths() }
        active = monitors.firstIndex { $0.display.id == activeID } ?? 0
        // A swipe in progress may have been on a display that's gone: sit
        // out the rest of that gesture.
        if swipeOK != nil { swipeOK = false }
        swipeMonitor = min(swipeMonitor, monitors.count - 1)
        updateParking()
    }

    private func monitorOf(_ id: WID) -> Int? {
        monitors.firstIndex { $0.strip.contains(id) }
    }

    /// The monitor showing this point, or the nearest one.
    private func monitorAt(_ x: Double, _ y: Double) -> Int {
        if let i = monitors.firstIndex(where: { $0.display.contains(x, y) }) { return i }
        let dist = { (m: Monitor) -> Double in
            let f = m.display.frame
            return pow(f.x + f.w / 2 - x, 2) + pow(f.y + f.h / 2 - y, 2)
        }
        return monitors.indices.min { dist(monitors[$0]) < dist(monitors[$1]) } ?? 0
    }

    /// The monitor a window joins when it's first seen: the one it was saved
    /// on, if that's connected, or else the one it's on now.
    private func homeMonitor(_ w: Window, saved index: Int?) -> Int {
        if let si = index, let i = monitors.firstIndex(where: { $0.display.id == saved.columns[si].display }) {
            return i
        }
        let p = w.position ?? .zero, s = w.size ?? .zero
        return monitorAt(p.x + s.width / 2, p.y + s.height / 2)
    }

    /// Whether this monitor's strip is on screen right now.
    private func onScreen(_ mi: Int) -> Bool {
        let ids = monitors[mi].windowIDs
        if ids.isEmpty { return true }
        let visible = AX.onScreenIDs()
        return ids.contains { visible.contains($0) }
    }

    // MARK: - Windows

    /// Pick up new windows and forget closed ones. On the first scan windows
    /// keep their current left-to-right order so the layout feels familiar.
    @discardableResult
    private func rescan() -> Bool {
        let known = Set(windows.keys)
        let knownPIDs = windows.values.map(\.pid)
        let listing = AX.listWindows(known: known, knownPIDs: knownPIDs)
        var found = listing.windows
        // An app that timed out still has the windows it had a moment ago.
        for w in windows.values where listing.unanswered.contains(w.pid) && !found.contains(where: { $0.id == w.id }) {
            found.append(w)
        }
        // A strip whose windows still exist but none is on screen: its display
        // shows another Space or a full-screen app. Removing them would wreck
        // the layout, so that strip is left exactly as it is until it's back.
        let onScreenIDs = Set(found.map(\.id))
        for i in monitors.indices {
            let ids = monitors[i].windowIDs
            monitors[i].away = !ids.isEmpty && !ids.contains(where: onScreenIDs.contains)
                && ids.contains(where: listing.elsewhere.contains)
        }
        if monitors.allSatisfy(\.away) { return false }
        let awayIDs = Set(monitors.filter(\.away).flatMap(\.windowIDs))
        for id in awayIDs where !onScreenIDs.contains(id) {
            if let w = windows[id] { found.append(w) }
        }

        for w in found where appNames[w.id] == nil {
            appNames[w.id] = AX.appName(w.pid) ?? ""
        }
        found = found.filter { w in
            !floating.contains(w.id) && !floatApps.contains(appNames[w.id] ?? "")
                && (known.contains(w.id) || w.isResizable)
        }
        // Windows from the saved layout come first, in saved order; the rest
        // follow in their current left-to-right order.
        let keyed = found.map { w -> Found in
            let index = anims[w.id] == nil ? savedIndex(w) : nil
            return Found(order: index ?? .max, x: Double(w.position?.x ?? 0), saved: index, window: w)
        }.sorted { ($0.order, $0.x) < ($1.order, $1.x) }

        // Which monitor each window belongs to. New windows that would land on
        // an away monitor wait until it's back.
        let homes = keyed.map { monitorOf($0.window.id) ?? homeMonitor($0.window, saved: $0.saved) }
        let firstScan = !scanned
        scanned = true
        var changed = false
        var newIDs: [WID] = []
        for mi in monitors.indices where !monitors[mi].away {
            let mine = zip(keyed, homes).filter { $0.1 == mi }.map { $0.0 }
            let ids = mine.map(\.window.id)
            if Log.verbose {
                let gone = monitors[mi].windowIDs.filter { !ids.contains($0) }
                let new = ids.filter { !monitors[mi].strip.contains($0) }
                if !gone.isEmpty || !new.isEmpty {
                    Log.info("rescan display \(monitors[mi].display.id): removed \(gone), added \(new), apps that didn't answer \(listing.unanswered)")
                }
            }
            let tabSwitched = !firstScan && followTabs(mi, ids: ids, mine: mine)
            newIDs += ids.filter { !monitors[mi].strip.contains($0) }
            changed = syncMonitor(mi, ids: ids, mine: mine) || tabSwitched || changed
        }

        // A window just opened by the active app (e.g. launched from the Dock)
        // takes focus, so the strip scrolls to it. Background apps don't steal it.
        let kept = keyed.map(\.window).filter { awayIDs.contains($0.id) || monitorOf($0.id) != nil }
        if !firstScan {
            for w in kept where newIDs.contains(w.id) {
                if AX.isFrontmost(w.pid) && AX.focusedWindow(of: w.pid) == w.id {
                    focusID(w.id)
                }
            }
        }

        windows = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        anims = anims.filter { windows[$0.key] != nil }
        dragging = dragging.filter { windows[$0] != nil }
        mover.retain(pids: Set(windows.values.map(\.pid)))
        for (id, w) in windows where anims[id] == nil {
            anims[id] = Anim(at: w.position ?? .zero, size: w.size ?? .zero)
        }
        refreshTitles()
        return changed
    }

    /// Bring one monitor's strip in line with the windows that belong on it,
    /// restoring saved widths and stacks for windows seen for the first time.
    private func syncMonitor(_ mi: Int, ids: [WID], mine: [Found]) -> Bool {
        let half = monitors[mi].halfWidth, full = monitors[mi].fullWidth
        let clampWidth = { (w: Double) in min(max(w, min(minWidth, full)), full) }
        var strip = monitors[mi].strip
        defer { monitors[mi].strip = strip }
        let fresh = Set(ids.filter { !strip.contains($0) })
        let changed = strip.sync(ids, newWidth: half)

        // New windows of apps with a width of their own open at it.
        let appWidths = Prefs.current.appWidths
        for f in mine where f.saved == nil && fresh.contains(f.window.id) {
            guard let fraction = appWidths[appNames[f.window.id] ?? ""], let ci = strip.index(of: f.window.id) else { continue }
            strip.columns[ci].width = fraction >= 1 ? full : clampWidth(strip.presetWidth(fraction, strip.inner(monitors[mi].viewport).w))
        }

        // Newly seen windows that were in the saved layout get their old width back.
        for f in mine {
            guard let si = f.saved, let ci = strip.index(of: f.window.id) else { continue }
            let s = saved.columns[si]
            strip.columns[ci].width = clampWidth(s.width)
            strip.columns[ci].restoreWidth = s.restoreWidth
            strip.columns[ci].height = s.height
        }
        // Rebuild saved stacks: a column whose window was saved as stacked
        // under the window just before it in the saved layout joins that stack.
        let savedAt = Dictionary(mine.compactMap { f in f.saved.map { (f.window.id, $0) } }, uniquingKeysWith: { a, _ in a })
        if strip.columns.count > 1 {
            for i in stride(from: strip.columns.count - 1, through: 1, by: -1) {
                guard let si = savedAt[strip.columns[i].windows[0]],
                      let prev = savedAt[strip.columns[i - 1].windows.last!] else { continue }
                if saved.columns[si].stacked && prev + 1 == si {
                    strip.mergeIntoPrevious(i)
                }
            }
        }
        for c in strip.columns.indices {
            for row in strip.columns[c].windows.indices {
                guard let si = savedAt[strip.columns[c].windows[row]] else { continue }
                strip.columns[c].weights[row] = saved.columns[si].weight
                if let w = saved.columns[si].ownWidth { strip.columns[c].widths[row] = clampWidth(w) }
            }
            // Tabs the user chose come back; ones an earlier version added
            // because the stack didn't fit don't: such stacks overlap now.
            if let si = savedAt[strip.columns[c].windows[0]], saved.columns[si].tabbed, !saved.columns[si].autoTabbed {
                strip.columns[c].tabbed = true
            }
        }
        return changed
    }

    /// Native macOS tabs are separate windows, and only the selected tab's
    /// window is on screen. Switching, opening or closing a tab therefore
    /// looks like one window of an app leaving and another arriving; the new
    /// one takes the old one's place so the strip doesn't shift. Also records
    /// columns about to disappear, so a tab arriving a moment later still
    /// lands in its slot. Returns true if any window was swapped in.
    private func followTabs(_ mi: Int, ids: [WID], mine: [Found]) -> Bool {
        let pidOfNew = Dictionary(mine.map { ($0.window.id, $0.window.pid) }, uniquingKeysWith: { a, _ in a })
        let displayID = monitors[mi].display.id
        var gone = monitors[mi].windowIDs.filter { !ids.contains($0) }
        let t = now()
        recentGone.removeAll { t - $0.at >= tabSwitchWindow }

        var swapped = false
        for id in ids where !monitors[mi].strip.contains(id) {
            let pid = pidOfNew[id]
            if let i = gone.firstIndex(where: { windows[$0]?.pid == pid }) {
                let old = gone.remove(at: i)
                Log.debug("tab switch: window \(old) -> \(id)")
                monitors[mi].strip.replace(old, with: id)
                swapped = true
            } else if let i = recentGone.firstIndex(where: { $0.display == displayID && $0.pid == pid }) {
                let g = recentGone.remove(at: i)
                Log.debug("tab switch: window \(id) back into column \(g.index)")
                monitors[mi].strip.insertColumn(at: g.index, id, width: g.width)
                swapped = true
            }
        }
        // Whatever is still gone is about to be removed by sync: remember its slot.
        for g in gone {
            guard let w = windows[g], let index = monitors[mi].strip.index(of: g) else { continue }
            let col = monitors[mi].strip.columns[index]
            if col.windows.count == 1 {
                recentGone.append((displayID, w.pid, index, col.width, now()))
            }
        }
        return swapped
    }

    /// Look up the titles shown in tab bars.
    private func refreshTitles() {
        let ids = Set(monitors.flatMap(\.windowIDs))
        titles = titles.filter { ids.contains($0.key) }
        for id in ids {
            if let title = windows[id]?.title { titles[id] = title }
        }
    }

    private func savedIndex(_ w: Window) -> Int? {
        saved.find(id: w.id, app: appNames[w.id] ?? "", title: w.title ?? "")
    }

    // MARK: - Saving

    private func signature() -> [SignatureEntry] {
        monitors.flatMap { m in
            m.strip.allColumns.enumerated().flatMap { i, c in
                zip(c.windows, c.weights).map { w, weight in
                    SignatureEntry(display: m.display.id, window: w, column: i, width: Int(c.width.rounded()),
                                   weight: Int((weight * 100).rounded()), tabbed: c.tabbed,
                                   height: c.height.map { Int(($0 * 1000).rounded()) })
                }
            }
        }
    }

    /// Write the current strips to disk, keeping saved entries for windows
    /// that aren't open right now so they get their width back later.
    private func saveLayout() {
        var columns: [SavedColumn] = []
        for m in monitors {
            for c in m.strip.allColumns {
                for (row, (id, weight)) in zip(c.windows, c.weights).enumerated() {
                    guard let w = windows[id] else { continue }
                    columns.append(SavedColumn(
                        id: id, app: appNames[id] ?? "", title: w.title ?? "", width: c.width,
                        restoreWidth: c.restoreWidth, stacked: row > 0, weight: weight, tabbed: c.tabbed,
                        autoTabbed: false, display: m.display.id, height: c.height,
                        ownWidth: c.windows.count > 1 ? c.widths[row] : nil))
                }
            }
        }
        let current = SavedLayout(columns: columns)
        for old in saved.columns where current.find(id: old.id, app: old.app, title: old.title) == nil && columns.count < maxSaved {
            columns.append(old)
        }
        saved = SavedLayout(columns: columns)
        saved.save()
        savedSignature = signature()
    }

    // MARK: - Focus

    /// Focus `id` on whichever strip holds it, making that monitor active.
    @discardableResult
    private func focusID(_ id: WID) -> Bool {
        guard let mi = monitorOf(id) else { return false }
        let switched = mi != active
        active = mi
        return monitors[mi].strip.focus(id) || switched
    }

    /// Focus the strip on `id`, falling back to asking macOS which window has focus.
    private func focusWindow(_ id: WID?) -> Bool {
        // While a focus we asked for is on its way, macOS can still report
        // the window it's leaving.
        if let want = focusing?.id {
            if id == want {
                focusing = nil
            } else if focusInFlight {
                return false
            }
        }
        if let id { return focusID(id) }
        return syncFocus()
    }

    /// Adopt whatever window the user focused by other means (mouse click, Cmd-Tab).
    @discardableResult
    private func syncFocus() -> Bool {
        if focusInFlight { return false }
        return AX.focusedWindowID().map(focusID) ?? false
    }

    /// A focus we asked for hasn't landed yet. Given up on after a while,
    /// in case its window went away.
    private var focusInFlight: Bool {
        if let f = focusing, now() - f.at >= focusLandsWithin { focusing = nil }
        return focusing != nil
    }

    /// Focus a window without waiting for its app to answer.
    private func requestFocus(_ id: WID) {
        guard let win = windows[id] else { return }
        focuser.focus(win, pins: pinnedWindows(above: id))
        focusing = (id, now())
    }

    private func focusCurrent() {
        if let id = monitors[active].strip.focusedWindow { requestFocus(id) }
    }

    /// The pinned windows to raise above the one that has focus, `focused`:
    /// the visible windows of every pinned column (a tabbed column shows only
    /// its active one), apart from the focused window's own app's. Raising a
    /// window makes it its app's front window, which would take focus away
    /// from `focused` if they're the same app.
    private func pinnedWindows(above focused: WID?) -> [Window] {
        let app = focused.flatMap { windows[$0]?.pid }
        return monitors.filter { !$0.away }
            .flatMap { $0.strip.pinned.compactMap { $0 } }
            .flatMap { $0.tabbed ? [$0.activeWindow] : $0.windows }
            .compactMap { windows[$0] }
            .filter { $0.id != focused && $0.pid != app }
    }

    // MARK: - Layout

    /// Where a monitor's windows go, given what we know of the shortest each
    /// app will make its window: a stack that can't fit overlaps.
    private func frames(_ mi: Int) -> [(WID, Rect)] {
        monitors[mi].strip.frames(monitors[mi].viewport) { [anims] in anims[$0]?.minHeight ?? 0 }
    }

    /// Recompute every on-screen strip and point each window's spring at its new spot.
    private func retarget() {
        for mi in monitors.indices where !monitors[mi].away {
            retargetMonitor(mi)
        }
    }

    private func retargetMonitor(_ mi: Int) {
        // Mid-swipe the fingers decide the scroll; scrolling back to the
        // focused column would yank the strip out from under them.
        let swiping = swipeOK == true && swipeMonitor == mi
        let vp = monitors[mi].viewport
        if !swiping { monitors[mi].strip.ensureFocusedVisible(vp.w) }

        // Resize first. Each app's queue applies the size and reports back
        // what the app really took (see `resized`): apps may refuse sizes
        // below their minimum, and the layout then makes room for that.
        requestSizes(mi)
        if !swiping { monitors[mi].strip.ensureFocusedVisible(vp.w) }

        for (id, frame) in frames(mi) where anims[id] != nil {
            // With Reduce Motion on, only the fingers move windows smoothly.
            if reduceMotion && !swiping {
                anims[id]!.jump(to: CGPoint(x: frame.x, y: frame.y))
            } else {
                anims[id]!.aim(frame.x, frame.y, stiffness: layoutStiffness)
            }
        }
    }

    /// Ask for a new size for every window of a monitor whose size differs
    /// from its frame. Sizes are applied on the app's queue, so a slow app
    /// never holds up the animation.
    private func requestSizes(_ mi: Int) {
        for (id, frame) in frames(mi) where !dragging.contains(id) {
            guard let win = windows[id], let a = anims[id] else { continue }
            let has = a.resizing ?? a.answered ?? a.appliedSize
            if abs(has.width - frame.w) > 0.5 || abs(has.height - frame.h) > 0.5 {
                mover.setSize(win, frame.w, frame.h)
                anims[id]!.resizing = CGSize(width: frame.w, height: frame.h)
                anims[id]!.lastSet = now()
                anims[id]!.verified = false
            }
        }
    }

    /// An app has applied a size we asked for. If it took more than asked
    /// (a minimum width or height), the layout makes room for what it took.
    private func resized(_ id: WID, want: CGSize, got: CGSize) {
        // A newer size is on its way; its answer is the one that counts.
        guard var a = anims[id], a.resizing == want else { return }
        a.hasSize(got)
        a.answered = want
        a.lastSet = now()
        a.verified = false
        // Cut short while it's still away from its new spot: macOS keeps
        // windows on screen, so growing one where it is now can be clamped.
        // Ask again once it lands; if it's already in place, the app's own
        // limit is what stopped it.
        let moving = abs(a.applied.x - a.x.target.rounded()) > 0.5 || abs(a.applied.y - a.y.target.rounded()) > 0.5
        a.resizeAgain = moving && (got.width < want.width - 1 || got.height < want.height - 1)
        if got.height > want.height + 1 { a.minHeight = max(a.minHeight, got.height) }
        anims[id] = a
        guard !paused, !suspended, !dragging.contains(id), let mi = monitorOf(id), !monitors[mi].away else { return }
        let vp = monitors[mi].viewport
        var changed = false
        if got.width > want.width + 1 {
            monitors[mi].strip.withColumn(of: id) { $0.width = got.width }
            changed = true
        }
        // Too tall for its share of a stack: its neighbour makes room. If the
        // shortest heights of the stack's apps can't share the column at all,
        // the layout overlaps them instead, and moving the shared edge would
        // only bounce the windows between their minimums.
        if got.height > want.height + 1, let stack = monitors[mi].strip.column(of: id),
           stack.windows.count > 1, !stack.tabbed {
            let gaps = monitors[mi].strip.gap * Double(stack.windows.count - 1)
            let fullH = vp.h - 2 * monitors[mi].strip.gap
            let mins = stack.windows.reduce(0) { $0 + (anims[$1]?.minHeight ?? 0) }
            if mins + gaps > fullH + 1 || monitors[mi].strip.resizeWindow(id, height: got.height, topEdge: nil, viewport: vp) {
                changed = true
            }
        }
        if changed { retargetMonitor(mi) }
    }

    /// Shrink a lone window's column to fit the window when its app won't
    /// make it as wide as the column (System Settings has a fixed width), so
    /// no gap is left beside it. Apps that are only slow to resize catch up
    /// within a second or two, so a column shrinks only once its window has
    /// stayed at the same narrower width for two checks in a row.
    private func fitNarrowColumns() -> Bool {
        var seen: [WID: Double] = [:]
        var changed = false
        for mi in monitors.indices where !monitors[mi].away {
            for col in monitors[mi].strip.allColumns where col.windows.count == 1 {
                let id = col.windows[0]
                let settling = anims[id].map { $0.resizeAgain || $0.resizing != nil || $0.needsFrame } ?? true
                guard !settling, !dragging.contains(id), let size = windows[id]?.size,
                      size.width < col.width - 1 else { continue }
                if let w = tooNarrow[id], abs(w - size.width) < 1 {
                    Log.info("window \(id) won't go wider than \(Int(size.width)); fitting its column to it")
                    monitors[mi].strip.withColumn(of: id) { $0.width = size.width }
                    anims[id]?.hasSize(size)
                    changed = true
                } else {
                    seen[id] = size.width
                }
            }
        }
        tooNarrow = seen
        return changed
    }

    /// Hand the UI a bar for every tabbed column that's at least partly on
    /// screen. Bars ride along with their column's animation, and are cut
    /// off where the column slides out of view (or under a pinned column).
    private func publishTabBars() {
        if suspended { return }
        var bars: [TabBar] = []
        for m in monitors where !paused {
            if m.away {
                // Its bars are on the Space it's showing; leave them there.
                bars += shownBars.filter { m.strip.contains($0.key) }
                continue
            }
            let vp = m.viewport
            let inner = m.strip.inner(vp)
            let columns = (m.strip.pinned[LEFT].map { [($0, vp)] } ?? []) + m.strip.columns.map { ($0, inner) }
                + (m.strip.pinned[RIGHT].map { [($0, vp)] } ?? [])
            for (col, clip) in columns where col.tabbed {
                guard let a = anims[col.activeWindow] else { continue }
                let bar = Rect(x: a.x.value, y: a.y.value - m.strip.tabBar, w: col.width, h: tabBarHeight)
                guard let visible = intersect(bar, clip) else { continue }
                bars.append(TabBar(key: col.windows[0], frame: visible, offset: visible.x - bar.x, fullWidth: bar.w,
                                   tabs: col.windows.map { ($0, titles[$0] ?? appNames[$0] ?? "") }.map(TabBar.Tab.init),
                                   active: col.active))
            }
        }
        if bars != shownBars {
            TabBars.show(bars)
            shownBars = bars
        }
    }

    // MARK: - Swipes

    /// Chase the fingers with a stiff spring: close enough to feel attached,
    /// soft enough to smooth over uneven trackpad samples and window moves.
    private func swipe(_ dx: Double) {
        let vp = monitors[swipeMonitor].viewport
        // Natural direction: fingers moving left drag the strip left.
        monitors[swipeMonitor].strip.scrollBy(-dx * swipeSpeed * vp.w, vp.w)
        for (id, frame) in frames(swipeMonitor) where anims[id] != nil {
            anims[id]!.aim(frame.x, frame.y, stiffness: followStiffness)
        }
    }

    /// Put the strip back where the swipe started, without focusing anything.
    private func abortSwipe() {
        swipeOK = false
        monitors[swipeMonitor].strip.scroll = swipeStartScroll
        retarget()
    }

    private func swipeEnd(_ velocity: Double) {
        let mi = swipeMonitor
        let w = monitors[mi].viewport.w
        monitors[mi].strip.scrollBy(-velocity * swipeSpeed * w * swipeMomentum, w)
        let before = monitors[mi].strip.focused
        monitors[mi].strip.snap(w)
        let after = monitors[mi].strip.focused
        retarget()
        if after != before || mi != active {
            active = mi
            focusCurrent()
        }
    }

    // MARK: - Outside moves and drags

    /// A managed window moved without the mouse. If it wasn't us, put it
    /// back in its column. If macOS keeps forcing the same spot (e.g. it
    /// won't let a window go that far off screen), accept it rather than loop.
    private func checkExternalMove(_ id: WID) {
        guard !dragging.contains(id), swipeOK == nil, let win = windows[id], var a = anims[id] else { return }
        // Our own animation is still moving it, or its last moves are still
        // being applied and reported back.
        if a.needsFrame || a.resizing != nil || now() - a.lastSet < ownMoveGrace { return }
        guard let p = win.position, let s = win.size else { return }
        let moved = abs(p.x - a.applied.x) > 2 || abs(p.y - a.applied.y) > 2
        let resized = abs(s.width - a.appliedSize.width) > 2 || abs(s.height - a.appliedSize.height) > 2
        guard moved || resized else { return }
        let t = now()
        let forcedAgain = externalFixes[id].map { t - $0.at < 2 && abs($0.p.x - p.x) < 2 && abs($0.p.y - p.y) < 2 } ?? false
        a.jump(to: p)
        a.applied = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        a.hasSize(s)
        anims[id] = a
        if forcedAgain {
            Log.debug("window \(id): macOS keeps it at (\(Int(p.x)), \(Int(p.y))); leaving it")
            return
        }
        Log.debug("window \(id) was moved by something else to (\(Int(p.x)), \(Int(p.y))); putting it back")
        externalFixes[id] = (t, p)
        retarget()
    }

    /// Where a window being dragged would be stacked if dropped now: the
    /// monitor, the window under the pointer, and whether it goes below it.
    /// Only for moves; a drag that changes the window's size is a resize.
    private func stackTarget(_ id: WID, size s: CGSize, pointer p: CGPoint) -> (Int, WID, Bool)? {
        guard let a = anims[id], abs(s.width - a.appliedSize.width) <= 2, abs(s.height - a.appliedSize.height) <= 2 else {
            return nil
        }
        let mi = monitorAt(p.x, p.y)
        let m = monitors[mi]
        if m.away { return nil }
        let vp = m.viewport
        let inner = m.strip.inner(vp)
        let pinned = Set(m.strip.pinned.compactMap { $0 }.flatMap(\.windows))
        // Hit-test the layout rather than the screen: the dragged window is
        // on top of whatever is under the pointer. Scrolling columns only
        // show between the pinned ones, which are on top of them.
        guard let (target, f) = frames(mi).first(where: { w, f in
            let clip = pinned.contains(w) ? vp : inner
            return w != id && p.x >= max(f.x, clip.x) && p.x < min(f.x + f.w, clip.x + clip.w) && p.y >= f.y && p.y < f.y + f.h
        }) else { return nil }
        let rel = (p.y - f.y) / f.h
        if p.y >= f.y + titleBand && rel < stackZone { return (mi, target, false) }
        if rel > 1 - stackZone { return (mi, target, true) }
        return nil
    }

    /// A drag that changed the window's size was a resize: it stays where it
    /// is, its column takes the new width, and the new height is shared with
    /// its neighbour in the stack (or kept, for a lone window). Returns false
    /// if the window wasn't resized.
    private func finishResize(_ id: WID, _ p: CGPoint, _ s: CGSize) -> Bool {
        guard var a = anims[id] else { return false }
        let oldY = a.applied.y, old = a.appliedSize
        let (wChanged, hChanged) = (abs(s.width - old.width) > 2, abs(s.height - old.height) > 2)
        guard wChanged || hChanged else { return false }
        // Start its springs from where the mouse left it.
        a.jump(to: p)
        a.applied = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        a.hasSize(s)
        anims[id] = a
        guard let mi = monitorOf(id) else { return true }
        active = mi
        let vp = monitors[mi].viewport
        let full = monitors[mi].fullWidth
        if wChanged {
            monitors[mi].strip.withColumn(of: id) {
                $0.width = min(max(s.width, min(minWidth, full)), full)
                $0.restoreWidth = nil
            }
        }
        if hChanged {
            // Only dragging the top edge (or a top corner) moves the window's top.
            monitors[mi].strip.resizeWindow(id, height: s.height, topEdge: abs(p.y - oldY) > 2, viewport: vp)
        }
        monitors[mi].strip.focus(id)
        Log.debug("window \(id) resized to \(Int(s.width))x\(Int(s.height))")
        return true
    }

    /// The pointer is on the window's title bar, where windows are dragged from.
    private func pointerOn(_ win: Window) -> Bool {
        guard let p = win.position, let s = win.size else { return false }
        let m = AX.mouseLocation
        return m.x >= p.x && m.x < p.x + s.width && m.y >= p.y && m.y < p.y + s.height
    }

    private func grabbedByTitleBar(_ win: Window) -> Bool {
        guard let p = win.position, let s = win.size else { return false }
        let m = AX.mouseLocation
        return m.x >= p.x && m.x < p.x + s.width && m.y >= p.y && m.y < p.y + min(titleBand, s.height)
    }

    /// While a window is dragged, highlight the half of the window it would
    /// be stacked into if dropped now.
    private func showDropHint() {
        let mouse = AX.mouseLocation
        let hint = dragging.lazy.compactMap { id -> (Int, WID, Bool)? in
            guard let s = self.windows[id]?.size else { return nil }
            return self.stackTarget(id, size: s, pointer: mouse)
        }.first.flatMap { mi, target, below -> Rect? in
            guard let f = frames(mi).first(where: { $0.0 == target })?.1 else { return nil }
            let half = f.h / 2
            return Rect(x: f.x, y: below ? f.y + half : f.y, w: f.w, h: half)
        }
        setDropHint(hint)
    }

    private func setDropHint(_ hint: Rect?) {
        guard hint != dropHint else { return }
        dropHint = hint
        TabBars.showDropHint(hint)
    }

    /// The mouse was released after dragging: note where each window was
    /// dropped, and leave them alone until they've settled.
    private func releaseDrags() {
        setDropHint(nil)
        let mouse = AX.mouseLocation, t = now()
        for id in dragging {
            guard let w = windows[id], let p = w.position, let s = w.size else { continue }
            released[id] = Release(p: p, s: s, mouse: mouse, seen: CGRect(origin: p, size: s), stillSince: t)
        }
        releasedAt = t
    }

    /// Whether every dropped window has stopped moving, or waited long enough.
    private func dropsSettled() -> Bool {
        guard let at = releasedAt, !released.isEmpty else { return true }
        let elapsed = now() - at
        if elapsed >= settleMax { return true }
        var still = true
        for (id, r) in released {
            guard let w = windows[id], let p = w.position, let s = w.size else { continue }
            let seen = CGRect(origin: p, size: s)
            if seen != r.seen {
                released[id]!.seen = seen
                released[id]!.stillSince = now()
            }
            still = still && now() - released[id]!.stillSince >= settleStill
        }
        return still && elapsed >= settleMin
    }

    /// Start the window's springs from where it really is now, so it
    /// animates from there to its new place.
    private func restartFromActual(_ id: WID) {
        guard let w = windows[id], let p = w.position, let s = w.size, anims[id] != nil else { return }
        anims[id]!.jump(to: p)
        anims[id]!.applied = CGPoint(x: p.x.rounded(), y: p.y.rounded())
        anims[id]!.hasSize(s)
    }

    /// Dropped windows have settled: place them. A window dropped on the
    /// top or bottom of another one is stacked with it; otherwise it slots
    /// into the column nearest where it was dropped, keeping any new width.
    /// A window dropped on another display joins that display's strip.
    /// Where it was dropped counts, not where macOS moved it afterwards.
    private func finishDrags() {
        setDropHint(nil)
        if releasedAt == nil { releaseDrags() }
        releasedAt = nil
        // A window grabbed since the mouse let go is still being dragged.
        let before = arrangements
        defer { rememberForUndo(before) }
        let drops = released
        released = [:]
        for (id, r) in drops {
            dragging.remove(id)
            if windows[id] != nil {
                placeDropped(id, r.p, r.s, mouse: r.mouse)
                restartFromActual(id)
            }
        }
        if focusPending {
            focusPending = false
            let id = pendingFocusID
            pendingFocusID = nil
            _ = focusWindow(id)
        }
        retarget()
    }

    private func placeDropped(_ id: WID, _ p: CGPoint, _ s: CGSize, mouse: CGPoint) {
        if finishResize(id, p, s) { return }
        if let (to, target, below) = stackTarget(id, size: s, pointer: mouse) {
            if let from = monitorOf(id), from != to { monitors[from].strip.remove(id) }
            monitors[to].strip.stackOnto(id, target: target, below: below)
            active = to
            Log.debug("window \(id) stacked \(below ? "below" : "above") window \(target)")
            return
        }
        let to = monitorAt(p.x + s.width / 2, p.y + s.height / 2)
        let from = monitorOf(id)
        let vp = monitors[to].viewport
        let centre = p.x - monitors[to].strip.inner(vp).x + monitors[to].strip.scroll + s.width / 2
        let width = min(max(s.width, minWidth), vp.w - 2 * gap)
        if from == to {
            monitors[to].strip.reinsert(id, centre: centre, width: width)
        } else {
            monitors[to].strip.insertDropped(id, centre: centre, width: width)
            if let from { monitors[from].strip.remove(id) }
        }
        active = to
        Log.debug("window \(id) dropped at centre \(Int(centre)) on display \(monitors[to].display.id): now column \(monitors[to].strip.focused)")
    }

    // MARK: - Commands

    private func handle(_ command: Command) {
        switch command {
        case .pause: return pause()
        case .resume: return resume()
        case .suspend:
            Log.info("suspended (sleep, lock or user switch)")
            suspended = true
            swipeOK = nil
            dragging = []
            released = [:]
            releasedAt = nil
            setDropHint(nil)
            return
        case .wake(let displays):
            Log.info("awake again on \(displays.count) display(s)")
            suspended = false
            setDisplays(displays)
            if !paused {
                resyncAnims()
                rescan()
                syncFocus()
                retarget()
            }
            return
        case .displaysChanged(let displays) where suspended:
            Log.debug("displays changed while suspended, ignored: \(displays)")
            return
        case .displaysChanged(let displays) where paused:
            setDisplays(displays)
            return
        case .setGap(let gap):
            self.gap = gap
            for i in monitors.indices { monitors[i].setGap(gap) }
            if !paused && !suspended { retarget() }
            return
        case .setFloatApps(let apps):
            return setFloatApps(apps)
        case .focused(let id):
            if focusing?.id == id { focusing = nil }
            return
        case .setReduceMotion(let on):
            reduceMotion = on
            return
        case .quit:
            break
        case _ where paused || suspended:
            return
        case .swipe(let dx):
            // Swipes in a full-screen app or on another Space aren't ours.
            if swipeOK == nil {
                let p = AX.mouseLocation
                swipeMonitor = monitorAt(p.x, p.y)
                swipeOK = onScreen(swipeMonitor)
                swipeStartScroll = monitors[swipeMonitor].strip.scroll
                swipeChecked = now()
            }
            if swipeOK == true {
                showStripIndicator(swipeMonitor)
                // If macOS also acts on this swipe it switches Space
                // mid-gesture; stop and undo rather than keep moving
                // windows during the transition. Checked by time, not on
                // every event, so the check never holds up a frame for long.
                let check = now() - swipeChecked >= spaceCheckEvery
                if check { swipeChecked = now() }
                if check && !onScreen(swipeMonitor) {
                    abortSwipe()
                } else {
                    swipe(dx)
                }
            }
            return
        case .swipeEnd(let v):
            let ok = swipeOK
            swipeOK = nil
            if ok == true {
                if onScreen(swipeMonitor) {
                    swipeEnd(v)
                } else {
                    abortSwipe()
                    swipeOK = nil
                }
            }
            return
        case .windowDragged(let id):
            // While the mouse is down our own animation may still move other
            // windows; the one the user grabbed has the pointer on its title
            // bar, or has focus and the pointer on it. Grabbing a window that
            // isn't focused moves it before macOS reports it as focused, so
            // the pointer counts first. A click elsewhere (the strip
            // indicator, the Dock, the menu bar) while the strip is still
            // scrolling isn't a drag. Drag events still queued after the mouse
            // was released don't count.
            if let win = windows[id], !dragging.contains(id), AX.mouseDown, !Overlays.indicatorCovers(AX.mouseLocation),
               grabbedByTitleBar(win) || (AX.focusedWindowID() == id && pointerOn(win)) {
                dragging.insert(id)
            }
            if dragging.contains(id) { showDropHint() }
            return
        case .windowMoved(let id):
            return checkExternalMove(id)
        case .resized(let id, let want, let got):
            return resized(id, want: want, got: got)
        case .windowsChanged:
            if rescan() {
                syncFocus()
                retarget()
            }
            return
        case .focusChanged(let id):
            if AX.mouseDown {
                focusPending = true
                pendingFocusID = id ?? pendingFocusID
            } else if focusWindow(id) {
                retarget()
                // The window the user picked came to the front, maybe over a pin.
                focuser.raise(pinnedWindows(above: id))
            }
            return
        case .focusWindow(let id):
            if focusID(id) { retarget() }
            requestFocus(id)
            return
        case .displaysChanged(let displays):
            Log.debug("displays changed: \(displays)")
            setDisplays(displays)
            rescan()
            retarget()
            return
        default:
            break
        }
        if case .quit = command {} else if !onScreen(active) { return }
        syncFocus()
        let before = arrangements
        let focusChanged: Bool
        switch command {
        case .undo: focusChanged = undo()
        case .redo: focusChanged = redo()
        case .focusPrevious: focusChanged = focusPrevious()
        case .toggleFloat:
            toggleFloat()
            focusChanged = false
        case .focusLeft: focusChanged = focusSideways(LEFT)
        case .focusRight: focusChanged = focusSideways(RIGHT)
        case .focusNextDisplay: focusChanged = focusNextDisplay()
        case .sendToNextDisplay: focusChanged = sendToNextDisplay()
        case .quit:
            saveLayout()
            restore()
            exit(0)
        default: focusChanged = stripCommand(command)
        }
        switch command {
        case .undo, .redo: break
        default: rememberForUndo(before)
        }
        retarget()
        showStripIndicator()
        if focusChanged {
            focusCurrent()
        } else {
            // A column just pinned goes on top of the ones it now floats over.
            focuser.raise(pinnedWindows(above: monitors[active].strip.focusedWindow))
        }
    }

    /// Run a shortcut that acts on the active strip. Returns true if focus moved.
    private func stripCommand(_ command: Command) -> Bool {
        let w = monitors[active].viewport.w
        var moved = false
        switch command {
        case .focusFirst: moved = monitors[active].strip.focusIndex(0)
        case .focusLast: moved = monitors[active].strip.focusLast()
        case .focusIndex(let i): moved = monitors[active].strip.focusIndex(i)
        case .moveLeft: moved = monitors[active].strip.moveLeft()
        case .moveRight: moved = monitors[active].strip.moveRight()
        case .cycleWidth: monitors[active].strip.cycleWidth(w)
        case .fullWidth: monitors[active].strip.toggleFullWidth(w)
        case .centre: monitors[active].strip.centreFocused(w)
        case .wider: monitors[active].strip.nudgeWidth(1, w, minWidth: minWidth)
        case .narrower: monitors[active].strip.nudgeWidth(-1, w, minWidth: minWidth)
        case .focusUp: moved = monitors[active].strip.focusVertical(-1)
        case .focusDown: moved = monitors[active].strip.focusVertical(1)
        case .moveUp: moved = monitors[active].strip.moveVertical(-1)
        case .moveDown: moved = monitors[active].strip.moveVertical(1)
        case .stackLeft: moved = monitors[active].strip.stackInto(-1)
        case .stackRight: moved = monitors[active].strip.stackInto(1)
        case .popLeft: moved = monitors[active].strip.popOut(-1)
        case .popRight: moved = monitors[active].strip.popOut(1)
        case .taller: monitors[active].strip.nudgeHeight(1)
        case .shorter: monitors[active].strip.nudgeHeight(-1)
        case .equalizeHeights: monitors[active].strip.equalizeHeights()
        case .pinLeft: monitors[active].strip.togglePin(LEFT)
        case .pinRight: monitors[active].strip.togglePin(RIGHT)
        case .toggleTabbed:
            monitors[active].strip.toggleTabbed()
            refreshTitles()
            // Bring the active tab to the front of the pile.
            moved = true
        default:
            assertionFailure("\(command) isn't a strip command")
        }
        return moved
    }

    /// Focus the next column to that side; from the end of a strip, the
    /// nearest column of the display beyond it, if there is one.
    private func focusSideways(_ side: Int) -> Bool {
        if side == LEFT ? monitors[active].strip.focusLeft() : monitors[active].strip.focusRight() { return true }
        let to = side == LEFT ? active - 1 : active + 1
        guard monitors.indices.contains(to), !monitors[to].away else { return false }
        // Arriving from the left lands on the strip's left end, and the other way round.
        guard monitors[to].strip.focusEnd(side == LEFT ? RIGHT : LEFT) else { return false }
        active = to
        return true
    }

    private var nextMonitor: Int? {
        monitors.count > 1 ? (active + 1) % monitors.count : nil
    }

    private func focusNextDisplay() -> Bool {
        guard let next = nextMonitor else { return false }
        active = next
        return true
    }

    /// Move the focused window to the next display, right of that strip's
    /// focused column, keeping its width if it fits. Focus goes with it.
    private func sendToNextDisplay() -> Bool {
        guard let to = nextMonitor, !monitors[to].away, let id = monitors[active].strip.focusedWindow,
              let width = monitors[active].strip.remove(id) else { return false }
        let full = monitors[to].fullWidth
        let at = monitors[to].strip.columns.isEmpty ? 0 : monitors[to].strip.focused + 1
        monitors[to].strip.insertColumn(at: at, id, width: min(max(width, min(minWidth, full)), full))
        monitors[to].strip.focus(id)
        active = to
        return true
    }

    // MARK: - Undo

    /// Layout changes remembered for undo.
    private static let undoLimit = 50

    private var arrangements: [UInt32: Arrangement<WID>] {
        Dictionary(monitors.map { ($0.display.id, $0.strip.arrangement) }, uniquingKeysWith: { a, _ in a })
    }

    /// Remember `before` for undo if the layout has changed since.
    private func rememberForUndo(_ before: [UInt32: Arrangement<WID>]) {
        let now = arrangements
        guard now.contains(where: { id, a in before[id].map { !$0.sameLayout(a) } ?? false }) else { return }
        undoHistory.append(before)
        if undoHistory.count > Engine.undoLimit { undoHistory.removeFirst() }
        redoHistory = []
    }

    private func undo() -> Bool {
        guard let to = undoHistory.popLast() else { return false }
        redoHistory.append(arrangements)
        Log.debug("undo")
        return arrange(to)
    }

    private func redo() -> Bool {
        guard let to = redoHistory.popLast() else { return false }
        undoHistory.append(arrangements)
        Log.debug("redo")
        return arrange(to)
    }

    /// Put every strip back as `to` has it. Windows that closed or floated
    /// since are left out; windows opened since stay where they are.
    private func arrange(_ to: [UInt32: Arrangement<WID>]) -> Bool {
        let known = Set(to.values.flatMap(\.windows))
        let inStrip = { [self] (id: WID) in
            windows[id] != nil && !floating.contains(id) && !floatApps.contains(appNames[id] ?? "")
        }
        for mi in monitors.indices {
            guard let a = to[monitors[mi].display.id] else { continue }
            monitors[mi].strip.restore(a, exists: inStrip, isNew: { !known.contains($0) })
            monitors[mi].clampWidths()
        }
        refreshTitles()
        return true
    }

    // MARK: - Jumping back

    /// Note when focus moves to another window, to jump back to the one before.
    private func trackFocus() {
        guard monitors.indices.contains(active) else { return }
        let now = monitors[active].strip.focusedWindow
        guard now != lastFocus else { return }
        if let last = lastFocus, windows[last] != nil { previousFocus = last }
        lastFocus = now
    }

    private func focusPrevious() -> Bool {
        guard let id = previousFocus, windows[id] != nil, let mi = monitorOf(id), !monitors[mi].away else { return false }
        active = mi
        return monitors[mi].strip.focus(id)
    }

    // MARK: - Overlays

    /// Outline the focused window as it moves, if Settings asks for it.
    private func publishFocusBorder() {
        var border: Overlays.Border?
        if Prefs.current.focusBorder && !paused && !suspended && monitors.indices.contains(active) && !monitors[active].away,
           let id = monitors[active].strip.focusedWindow, !dragging.contains(id), let a = anims[id] {
            let s = a.resizing ?? a.appliedSize
            border = Overlays.Border(window: id, frame: Rect(x: a.x.value, y: a.y.value, w: s.width, h: s.height))
        }
        guard border != shownBorder else { return }
        shownBorder = border
        Overlays.showBorder(border)
    }

    /// Show the strip's columns for a moment, after a shortcut or during a swipe.
    private func showStripIndicator(_ mi: Int? = nil) {
        let mi = mi ?? active
        guard Prefs.current.stripIndicator, monitors.indices.contains(mi), !monitors[mi].away else { return }
        let m = monitors[mi]
        let focused = mi == active ? m.strip.focusedWindow : nil
        let columns = m.strip.allColumns.compactMap { col -> Overlays.Column? in
            guard let w = windows[col.activeWindow] else { return nil }
            return Overlays.Column(window: w.id, pid: w.pid, focused: focused.map(col.windows.contains) ?? false)
        }
        Overlays.showStrip(Overlays.Indicator(columns: columns, viewport: m.viewport))
    }

    // MARK: - The menu's window list

    /// Hand the strips' windows to the menu when they change.
    private func publishWindows() {
        var list: [StripWindow] = []
        for (mi, m) in monitors.enumerated() {
            let focused = mi == active ? m.strip.focusedWindow : nil
            let pins = Set((m.strip.pinned.compactMap { $0 }).flatMap(\.windows))
            for col in m.strip.allColumns {
                for (row, id) in col.windows.enumerated() {
                    guard let w = windows[id] else { continue }
                    list.append(StripWindow(id: id, pid: w.pid, app: appNames[id] ?? "", title: titles[id] ?? "",
                                            display: mi, stacked: row > 0, pinned: pins.contains(id), focused: id == focused))
                }
            }
        }
        if paused { list = [] }
        guard list != shownWindows else { return }
        shownWindows = list
        DispatchQueue.main.async { AppModel.shared.stripWindows = list }
    }

    /// Stop managing windows and bring every one of them on screen. The
    /// strips are kept, and windows go back into them on `resume`.
    private func pause() {
        guard !paused else { return }
        Log.info("paused")
        saveLayout()
        paused = true
        swipeOK = nil
        dragging = []
        released = [:]
        releasedAt = nil
        setDropHint(nil)
        restore()
    }

    private func resume() {
        guard paused else { return }
        Log.info("resumed")
        paused = false
        resyncAnims()
        rescan()
        syncFocus()
        retarget()
    }

    /// Start every window's spring from where it really is. Windows move
    /// on their own while we're paused or asleep.
    private func resyncAnims() {
        for id in anims.keys {
            guard let w = windows[id], let p = w.position, let s = w.size else { continue }
            anims[id]!.jump(to: p)
            anims[id]!.applied = CGPoint(x: p.x.rounded(), y: p.y.rounded())
            anims[id]!.hasSize(s)
            anims[id]!.verified = true
        }
    }

    private func toggleFloat() {
        guard let id = AX.focusedWindowID() else { return }
        if floating.remove(id) != nil {
            // Rejoins the strip right of the focused column.
            rescan()
            focusID(id)
        } else if let win = windows[id] {
            let vp = monitors[monitorOf(id) ?? active].viewport
            floating.insert(id)
            rescan()
            // Leave it centred on its display, above the strip.
            if let p = win.position, let s = win.size {
                let x = vp.x + max((vp.w - s.width) / 2, 0)
                AX.withoutEnhancedUI(win.pid) { win.setPosition(x, p.y) }
            }
            win.focus()
        }
    }

    /// Float every window of these apps from now on. The ones in a strip
    /// leave it, centred on their display so none is left parked.
    private func setFloatApps(_ apps: [String]) {
        floatApps = Set(apps)
        if paused || suspended { return }
        let leaving = monitors.flatMap { m in m.windowIDs.map { ($0, m.viewport) } }
            .filter { floatApps.contains(appNames[$0.0] ?? "") }
        flushMover()
        for (id, vp) in leaving {
            guard let win = windows[id], let s = win.size else { continue }
            let x = vp.x + max((vp.w - s.width) / 2, 0)
            let y = vp.y + max((vp.h - s.height) / 2, 0)
            AX.withoutEnhancedUI(win.pid) { win.setPosition(x, y) }
        }
        rescan()
        syncFocus()
        retarget()
    }

    /// Drop moves and resizes not yet applied. A dropped resize never
    /// reports back, so none counts as on its way any more.
    private func flushMover() {
        mover.flush()
        for id in anims.keys { anims[id]!.resizing = nil }
    }

    /// Bring every window fully back on its display so nothing is left parked.
    private func restore() {
        // A move still queued for a slow app would otherwise land afterwards
        // and park the window again.
        flushMover()
        for mi in monitors.indices {
            let vp = monitors[mi].viewport
            var cascade = 0.0
            for (id, frame) in frames(mi) {
                guard let win = windows[id], let a = anims[id] else { continue }
                let (x, y) = (a.x.value, a.y.value)
                if x < vp.x || x + frame.w > vp.x + vp.w || y + 1 > vp.y + vp.h {
                    let (nx, ny) = (vp.x + gap + cascade, vp.y + gap + cascade)
                    AX.withoutEnhancedUI(win.pid) { win.setPosition(nx, ny) }
                    cascade = (cascade + 30).truncatingRemainder(dividingBy: 300)
                }
            }
        }
    }

    /// Put every window back on screen and quit. Callable from any thread;
    /// used when the app is asked to terminate.
    func quit() {
        send(.quit)
    }
}
