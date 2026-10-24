import Foundation

// Platform-independent model of a scrolling window strip.
//
// Columns are laid out left to right on an infinite horizontal strip. A
// column holds one window, or a stack of windows sharing its width.
// The viewport (the screen) looks at a slice of the strip starting at `scroll`.
// Columns that fall outside the viewport are "parked" against the nearest
// screen edge, leaving `peek` pixels visible, because macOS refuses to place
// a window fully off screen.

public struct Rect: Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Width presets as fractions of the viewport, cycled by `cycleWidth`.
public let widthPresets: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75]
/// Step for `nudgeWidth`, as a fraction of the viewport.
public let nudge = 0.1
/// Factor for `nudgeHeight`.
let heightStep = 1.25
/// A stacked window's height can't go below 1/5 or above 5x the average weight.
let minWeight = 0.2
let maxWeight = 5.0
/// No window is resized shorter than this.
public let minHeight = 100.0
/// A lone window resized to within this many pixels of the full height fills it.
let snapToFull = 8.0

/// Index into `Strip.pinned`.
public let LEFT = 0
public let RIGHT = 1

public struct Column<W: Equatable>: Equatable {
    /// Top to bottom. Never empty.
    public var windows: [W]
    /// Relative height of each window (same length as `windows`).
    public var weights: [Double]
    /// Each window's own width, from when it was a column by itself: the
    /// width it gets back when it leaves a stack (same length as `windows`).
    /// A lone window's own width is the column's `width`.
    public var widths: [Double]
    /// The window in this column that gets focus when the column does.
    public var active: Int
    /// Tabbed columns show one window at a time, each filling the column.
    public var tabbed: Bool
    /// Made tabbed by `fitAsTabs`, not by the user: it goes back to a
    /// plain column once it's down to one window.
    public var autoTabbed: Bool
    public var width: Double
    /// Width to go back to when leaving full width.
    public var restoreWidth: Double?
    /// A lone window's own height, as a fraction of the full height, after
    /// the user resized it. `nil` fills the column. Stacks share the full
    /// height by `weights` instead.
    public var height: Double?

    public init(_ window: W, width: Double) {
        windows = [window]
        weights = [1.0]
        widths = [width]
        active = 0
        tabbed = false
        autoTabbed = false
        self.width = width
        restoreWidth = nil
        height = nil
    }

    public var activeWindow: W { windows[active] }

    func row(of window: W) -> Int? {
        windows.firstIndex(of: window)
    }

    /// The width the window in `row` had as a column of its own.
    public func ownWidth(_ row: Int) -> Double {
        windows.count == 1 ? width : widths[row]
    }

    /// About to become a stack: a lone window's own width is the column's
    /// current width, whatever it was resized to since it was created.
    mutating func keepOwnWidth() {
        if windows.count == 1 {
            widths[0] = width
        }
    }

    /// Add `window` at the bottom with an average share of the height. The
    /// column becomes a stack, so a lone window's own height no longer applies.
    /// `ownWidth` is the width the window had as a column of its own.
    mutating func push(_ window: W, ownWidth: Double) {
        keepOwnWidth()
        let weight = weights.reduce(0, +) / Double(weights.count)
        windows.append(window)
        weights.append(weight)
        widths.append(ownWidth)
        active = windows.count - 1
        height = nil
    }

    /// Show the windows as tabs because they can't share the column's height.
    public mutating func fitAsTabs() {
        tabbed = true
        autoTabbed = true
    }

    /// Tabs added by `fitAsTabs` aren't needed for a lone window.
    mutating func dropAutoTabs() {
        if autoTabbed && windows.count < 2 {
            tabbed = false
            autoTabbed = false
        }
    }

    @discardableResult
    mutating func removeRow(_ row: Int) -> W {
        weights.remove(at: row)
        widths.remove(at: row)
        let w = windows.remove(at: row)
        if active >= row && active > 0 {
            active -= 1
        }
        dropAutoTabs()
        return w
    }

    /// Keep only the windows for which `keep` is true.
    public mutating func retain(_ keep: (W) -> Bool) {
        let flags = windows.map(keep)
        if flags.isEmpty {
            return
        }
        // The active window, or the nearest kept one above it, stays active.
        let keptUpToActive = flags[...min(active, flags.count - 1)].filter { $0 }.count
        windows = zip(windows, flags).filter { $0.1 }.map { $0.0 }
        weights = zip(weights, flags).filter { $0.1 }.map { $0.0 }
        widths = zip(widths, flags).filter { $0.1 }.map { $0.0 }
        dropAutoTabs()
        active = min(max(keptUpToActive - 1, 0), max(windows.count - 1, 0))
    }
}

public struct Strip<W: Equatable> {
    /// The scrolling columns.
    public var columns: [Column<W>] = []
    public var focused = 0
    /// Columns pinned to the left / right screen edge. They stay put while the
    /// rest of the strip scrolls in the space between them.
    public var pinned: [Column<W>?] = [nil, nil]
    /// Focus is on a pinned column (`LEFT` or `RIGHT`) rather than `focused`.
    public var focusPinned: Int?
    public var scroll = 0.0
    public var gap: Double
    public var peek: Double
    /// Height reserved above a tabbed column's windows for its tab bar,
    /// including the gap below the bar.
    public var tabBar = 0.0
    /// Top edge for columns parked past the left / right edge, when parking
    /// them beside the viewport would put them on a neighbouring display.
    /// `nil` parks them level with the rest.
    public var parkY: [Double?] = [nil, nil]

    public init(gap: Double, peek: Double) {
        self.gap = gap
        self.peek = peek
    }

    /// Every column, pinned ones included, left to right.
    public var allColumns: [Column<W>] {
        (pinned[LEFT].map { [$0] } ?? []) + columns + (pinned[RIGHT].map { [$0] } ?? [])
    }

    public func contains(_ window: W) -> Bool {
        allColumns.contains { $0.windows.contains(window) }
    }

    /// Where the column holding `window` is, pinned or not.
    enum Slot { case pinned(Int), column(Int) }

    func slot(of window: W) -> Slot? {
        if let c = pinned[LEFT], c.windows.contains(window) { return .pinned(LEFT) }
        if let i = columns.firstIndex(where: { $0.windows.contains(window) }) { return .column(i) }
        if let c = pinned[RIGHT], c.windows.contains(window) { return .pinned(RIGHT) }
        return nil
    }

    /// The column holding `window`, pinned or not.
    public func column(of window: W) -> Column<W>? {
        switch slot(of: window) {
        case .pinned(let s): return pinned[s]
        case .column(let i): return columns[i]
        case nil: return nil
        }
    }

    /// Change the column holding `window`, pinned or not. Returns nil if
    /// `window` isn't in the strip.
    @discardableResult
    public mutating func withColumn<R>(of window: W, _ body: (inout Column<W>) -> R) -> R? {
        switch slot(of: window) {
        case .pinned(let s):
            var c = pinned[s]!
            let r = body(&c)
            pinned[s] = c
            return r
        case .column(let i):
            return body(&columns[i])
        case nil:
            return nil
        }
    }

    func pinnedSide(of window: W) -> Int? {
        (0..<2).first { pinned[$0]?.windows.contains(window) ?? false }
    }

    func focusedCol() -> Column<W>? {
        if let side = focusPinned { return pinned[side] }
        return columns.indices.contains(focused) ? columns[focused] : nil
    }

    /// Change the focused column, if there is one.
    @discardableResult
    mutating func withFocusedCol<R>(_ body: (inout Column<W>) -> R) -> R? {
        if let side = focusPinned {
            guard var c = pinned[side] else { return nil }
            let r = body(&c)
            pinned[side] = c
            return r
        }
        guard columns.indices.contains(focused) else { return nil }
        return body(&columns[focused])
    }

    /// The part of the viewport the scrolling columns live in: everything
    /// between the pinned columns.
    public func inner(_ viewport: Rect) -> Rect {
        let side = { (s: Int) -> Double in self.pinned[s].map { $0.width + self.gap } ?? 0 }
        let (left, right) = (side(LEFT), side(RIGHT))
        return Rect(x: viewport.x + left, y: viewport.y, w: viewport.w - left - right, h: viewport.h)
    }

    func innerW(_ viewportW: Double) -> Double {
        inner(Rect(x: 0, y: 0, w: viewportW, h: 0)).w
    }

    /// Width the focused column has to itself: the space between the pinned
    /// columns for a scrolling column, or for a pinned one, everything but
    /// the column pinned on the other side.
    func roomForFocused(_ viewportW: Double) -> Double {
        guard let side = focusPinned else { return innerW(viewportW) }
        return viewportW - (pinned[1 - side].map { $0.width + gap } ?? 0)
    }

    /// Pin the focused column to the `side` edge, or unpin it if it's already
    /// pinned there. A column already pinned on that side goes back to the
    /// strip's end on that side.
    @discardableResult
    public mutating func togglePin(_ side: Int) -> Bool {
        if let s = focusPinned {
            if s != side {
                return false
            }
            let col = pinned[s]!
            pinned[s] = nil
            focused = side == LEFT ? 0 : columns.count
            columns.insert(col, at: focused)
            focusPinned = nil
            return true
        }
        if columns.isEmpty {
            return false
        }
        let col = columns.remove(at: focused)
        if let old = pinned[side] {
            pinned[side] = nil
            if side == LEFT {
                columns.insert(old, at: 0)
            } else {
                columns.append(old)
            }
        }
        pinned[side] = col
        focusPinned = side
        focused = min(focused, max(columns.count - 1, 0))
        return true
    }

    /// Width of a column sized to `fraction` of the viewport, chosen so that
    /// e.g. two halves plus three gaps fill the viewport exactly.
    public func presetWidth(_ fraction: Double, _ viewportW: Double) -> Double {
        fraction * (viewportW - gap) - gap
    }

    /// Reconcile with the current set of windows: drop columns whose window is
    /// gone and insert new ones just right of the focused column (or in the
    /// given order on an empty strip). Returns true if anything changed.
    @discardableResult
    public mutating func sync(_ windows: [W], newWidth: Double) -> Bool {
        let focusedWindow = self.focusedWindow
        let count = { (s: Strip<W>) in s.allColumns.reduce(0) { $0 + $1.windows.count } }
        let before = count(self)
        for i in columns.indices {
            columns[i].retain { windows.contains($0) }
        }
        columns.removeAll { $0.windows.isEmpty }
        for s in 0..<2 {
            if var c = pinned[s] {
                c.retain { windows.contains($0) }
                pinned[s] = c.windows.isEmpty ? nil : c
            }
        }
        if let s = focusPinned, pinned[s] == nil {
            focusPinned = nil
        }
        let removed = before != count(self)

        if let f = focusedWindow, let i = index(of: f) {
            focused = i
        } else {
            focused = min(focused, max(columns.count - 1, 0))
        }

        var at = columns.isEmpty ? 0 : focused + 1
        var added = false
        for w in windows where !contains(w) {
            columns.insert(Column(w, width: newWidth), at: at)
            at += 1
            added = true
        }
        return removed || added
    }

    /// Put `new` exactly where `old` is (e.g. switching native tabs, where
    /// each tab is its own window). Returns false if `old` isn't in the strip.
    @discardableResult
    public mutating func replace(_ old: W, with new: W) -> Bool {
        withColumn(of: old) { col in
            col.windows[col.row(of: old)!] = new
        } != nil
    }

    /// Insert `window` as its own column at `index` (clamped), keeping focus
    /// on the same column. Used to put a window back in a slot it just left.
    public mutating func insertColumn(at index: Int, _ window: W, width: Double) {
        let index = min(index, columns.count)
        columns.insert(Column(window, width: width), at: index)
        if focusPinned == nil && index <= focused && columns.count > 1 {
            focused += 1
        }
    }

    /// Take `window` out of the strip, e.g. to move it to another display.
    /// Returns the width of the column it was in.
    @discardableResult
    public mutating func remove(_ window: W) -> Double? {
        if let side = pinnedSide(of: window) {
            var col = pinned[side]!
            let width = col.width
            col.removeRow(col.row(of: window)!)
            if col.windows.isEmpty {
                pinned[side] = nil
                if focusPinned == side {
                    focusPinned = nil
                }
            } else {
                pinned[side] = col
            }
            return width
        }
        guard let (i, row) = position(of: window) else { return nil }
        let width = columns[i].width
        columns[i].removeRow(row)
        if columns[i].windows.isEmpty {
            columns.remove(at: i)
            if i < focused {
                focused -= 1
            }
            focused = min(focused, max(columns.count - 1, 0))
        }
        return width
    }

    /// Index of the column holding `window`.
    public func index(of window: W) -> Int? {
        columns.firstIndex { $0.windows.contains(window) }
    }

    /// Column and row of `window`.
    public func position(of window: W) -> (Int, Int)? {
        for (i, c) in columns.enumerated() {
            if let r = c.row(of: window) { return (i, r) }
        }
        return nil
    }

    public var focusedWindow: W? {
        focusedCol()?.activeWindow
    }

    @discardableResult
    public mutating func focus(_ window: W) -> Bool {
        if let side = pinnedSide(of: window) {
            var col = pinned[side]!
            let row = col.row(of: window)!
            let changed = focusPinned != side || col.active != row
            col.active = row
            pinned[side] = col
            focusPinned = side
            return changed
        }
        if let (i, r) = position(of: window), focusPinned != nil || i != focused || r != columns[i].active {
            focused = i
            columns[i].active = r
            focusPinned = nil
            return true
        }
        return false
    }

    /// Focus the window above (`-1`) or below (`1`) in the focused column.
    @discardableResult
    public mutating func focusVertical(_ dir: Int) -> Bool {
        withFocusedCol { col in
            let next = col.active + dir
            if next < 0 || next >= col.windows.count {
                return false
            }
            col.active = next
            return true
        } ?? false
    }

    /// Move the focused window up (`-1`) or down (`1`) within its stack.
    @discardableResult
    public mutating func moveVertical(_ dir: Int) -> Bool {
        withFocusedCol { col in
            let next = col.active + dir
            if next < 0 || next >= col.windows.count {
                return false
            }
            col.windows.swapAt(col.active, next)
            col.weights.swapAt(col.active, next)
            col.active = next
            return true
        } ?? false
    }

    /// Move the focused window into the stack of the column to the left
    /// (`dir = -1`) or right (`1`), at the bottom.
    @discardableResult
    public mutating func stackInto(_ dir: Int) -> Bool {
        if focusPinned != nil || columns.isEmpty {
            return false
        }
        var target = focused + dir
        if target < 0 || target >= columns.count {
            return false
        }
        let ownWidth = columns[focused].ownWidth(columns[focused].active)
        let w = columns[focused].removeRow(columns[focused].active)
        if columns[focused].windows.isEmpty {
            columns.remove(at: focused)
            if target > focused {
                target -= 1
            }
        }
        columns[target].push(w, ownWidth: ownWidth)
        focused = target
        return true
    }

    /// Take the focused window out of its stack into a new column on the
    /// left (`dir = -1`) or right (`1`), at the width it had before it joined.
    @discardableResult
    public mutating func popOut(_ dir: Int) -> Bool {
        if focusPinned != nil || columns.isEmpty {
            return false
        }
        if columns[focused].windows.count < 2 {
            return false
        }
        let width = columns[focused].ownWidth(columns[focused].active)
        let w = columns[focused].removeRow(columns[focused].active)
        let at = dir < 0 ? focused : focused + 1
        columns.insert(Column(w, width: width), at: at)
        focused = at
        return true
    }

    /// Make the focused window in a stack taller (`steps > 0`) or shorter.
    @discardableResult
    public mutating func nudgeHeight(_ steps: Double) -> Bool {
        withFocusedCol { col in
            if col.windows.count < 2 || col.tabbed {
                return false
            }
            let avg = col.weights.reduce(0, +) / Double(col.weights.count)
            let w = col.weights[col.active] * pow(heightStep, steps)
            col.weights[col.active] = min(max(w, minWeight * avg), maxWeight * avg)
            return true
        } ?? false
    }

    /// Give every window in the focused stack the same height, and a lone
    /// window the full height.
    public mutating func equalizeHeights() {
        withFocusedCol { col in
            col.height = nil
            col.weights = col.weights.map { _ in 1.0 }
        }
    }

    public mutating func toggleTabbed() {
        withFocusedCol { col in
            col.tabbed.toggle()
            col.autoTabbed = false
        }
    }

    /// Merge column `i` into the column on its left (used to restore stacks).
    public mutating func mergeIntoPrevious(_ i: Int) {
        if i == 0 || i >= columns.count {
            return
        }
        let col = columns.remove(at: i)
        let ownWidths = col.windows.indices.map { col.ownWidth($0) }
        var prev = columns[i - 1]
        prev.keepOwnWidth()
        // Weights only mean something within a column: bring the incoming
        // ones to the same scale as the stack they join.
        let avg = { (w: [Double]) in w.reduce(0, +) / Double(w.count) }
        let scale = avg(prev.weights) / avg(col.weights)
        for ((w, weight), ownWidth) in zip(zip(col.windows, col.weights), ownWidths) {
            prev.windows.append(w)
            prev.weights.append(weight * scale)
            prev.widths.append(ownWidth)
        }
        prev.height = nil
        columns[i - 1] = prev
        if focused >= i {
            focused -= 1
        }
    }

    /// Move focus one column left (`dir = -1`) or right (`1`), stepping onto
    /// and off the pinned columns at either end.
    private mutating func stepHorizontal(_ dir: Int) -> Bool {
        let near = dir < 0 ? LEFT : RIGHT
        switch focusPinned {
        case .some(let s) where s == near:
            return false
        case .some:
            // Leaving the far pinned column: onto the nearest end of the strip.
            if columns.isEmpty {
                if pinned[near] == nil {
                    return false
                }
                focusPinned = near
            } else {
                focused = dir < 0 ? columns.count - 1 : 0
                focusPinned = nil
            }
            return true
        case .none:
            let next = focused + dir
            if !columns.isEmpty && next >= 0 && next < columns.count {
                focused = next
                return true
            } else if pinned[near] != nil {
                focusPinned = near
                return true
            } else {
                return false
            }
        }
    }

    @discardableResult
    public mutating func focusLeft() -> Bool { stepHorizontal(-1) }

    @discardableResult
    public mutating func focusRight() -> Bool { stepHorizontal(1) }

    @discardableResult
    public mutating func focusIndex(_ i: Int) -> Bool {
        if i < columns.count && (i != focused || focusPinned != nil) {
            focused = i
            focusPinned = nil
            return true
        }
        return false
    }

    /// Focus the leftmost (`side` is LEFT) or rightmost column, pinned ones
    /// included, as when focus arrives from a neighbouring strip.
    @discardableResult
    public mutating func focusEnd(_ side: Int) -> Bool {
        if pinned[side] != nil {
            focusPinned = side
        } else if columns.isEmpty {
            return false
        } else {
            focused = side == LEFT ? 0 : columns.count - 1
            focusPinned = nil
        }
        return true
    }

    @discardableResult
    public mutating func focusLast() -> Bool {
        focusIndex(max(columns.count - 1, 0))
    }

    @discardableResult
    public mutating func moveLeft() -> Bool {
        if focusPinned == nil && focused > 0 {
            columns.swapAt(focused, focused - 1)
            focused -= 1
            return true
        }
        return false
    }

    @discardableResult
    public mutating func moveRight() -> Bool {
        if focusPinned == nil && focused + 1 < columns.count {
            columns.swapAt(focused, focused + 1)
            focused += 1
            return true
        }
        return false
    }

    /// Switch the focused column to the next width preset.
    public mutating func cycleWidth(_ viewportW: Double) {
        guard let width = focusedCol()?.width else { return }
        let room = roomForFocused(viewportW)
        let presets = widthPresets.map { presetWidth($0, room) }
        // Pick the first preset noticeably wider than the current width, wrapping around.
        let next = presets.first { $0 > width + 1.0 } ?? presets[0]
        withFocusedCol { col in
            col.width = next
            col.restoreWidth = nil
        }
    }

    /// Toggle the focused column between full width and its previous width.
    public mutating func toggleFullWidth(_ viewportW: Double) {
        let full = presetWidth(1.0, roomForFocused(viewportW))
        withFocusedCol { col in
            let restore = col.restoreWidth
            col.restoreWidth = nil
            if let w = restore, abs(col.width - full) < 1.0 {
                col.width = w
            } else {
                col.restoreWidth = col.width
                col.width = full
            }
        }
    }

    /// Make the focused column wider (`steps > 0`) or narrower by `nudge` per step.
    public mutating func nudgeWidth(_ steps: Double, _ viewportW: Double, minWidth: Double) {
        let full = presetWidth(1.0, roomForFocused(viewportW))
        withFocusedCol { col in
            col.width = min(max(col.width + steps * nudge * viewportW, min(minWidth, full)), full)
            col.restoreWidth = nil
        }
    }

    /// Scroll so the focused column sits in the middle of the viewport. May
    /// scroll past either end of the strip, which is what centring the first
    /// or last column needs.
    public mutating func centreFocused(_ viewportW: Double) {
        if focusPinned != nil {
            return
        }
        let viewportW = innerW(viewportW)
        if columns.indices.contains(focused) {
            scroll = columnX(focused) + columns[focused].width / 2 - viewportW / 2
        }
    }

    /// Put a window back after the user dragged it: it lands as its own
    /// column between the columns whose centres surround `centre` (strip
    /// coordinates), takes the given width, and gets focus. A window dragged
    /// out of a stack leaves the stack.
    @discardableResult
    public mutating func reinsert(_ window: W, centre: Double, width: Double) -> Bool {
        // Dragging a pinned window unpins it.
        if let side = pinnedSide(of: window) {
            let to = slotFor(centre, skip: nil)
            var p = pinned[side]!
            let col: Column<W>
            if p.windows.count == 1 {
                p.width = width
                col = p
                pinned[side] = nil
            } else {
                let row = p.row(of: window)!
                col = Column(p.removeRow(row), width: width)
                pinned[side] = p
            }
            columns.insert(col, at: to)
            focused = to
            focusPinned = nil
            return true
        }
        guard let (from, row) = position(of: window) else { return false }
        let alone = columns[from].windows.count == 1
        // Compare against where the other columns are on screen right now,
        // i.e. before this window is taken out of the strip.
        let to = slotFor(centre, skip: alone ? from : nil)
        let col: Column<W>
        if alone {
            var c = columns.remove(at: from)
            c.width = width
            col = c
        } else {
            col = Column(columns[from].removeRow(row), width: width)
        }
        columns.insert(col, at: to)
        focused = to
        focusPinned = nil
        return true
    }

    /// A window dragged in from another display lands as its own column
    /// where it was dropped (`centre` in strip coordinates), and gets focus.
    public mutating func insertDropped(_ window: W, centre: Double, width: Double) {
        let to = slotFor(centre, skip: nil)
        columns.insert(Column(window, width: width), at: to)
        focused = to
        focusPinned = nil
    }

    /// Put `window` into the stack holding `target`, just above or below it,
    /// taking it from wherever it is in this strip (or adding it, if it came
    /// from another display). It gets an equal share of the column's height
    /// and focus. In a tabbed column it becomes a new tab.
    @discardableResult
    public mutating func stackOnto(_ window: W, target: W, below: Bool) -> Bool {
        if window == target || !contains(target) {
            return false
        }
        let ownWidth = allColumns.lazy.compactMap { c in c.row(of: window).map { c.ownWidth($0) } }.first
        let width = remove(window)
        withColumn(of: target) { col in
            let at = col.row(of: target)! + (below ? 1 : 0)
            col.keepOwnWidth()
            col.widths.insert(ownWidth ?? width ?? col.width, at: at)
            let height = col.height
            col.height = nil
            if let f = height, !col.tabbed, col.windows.count == 1 {
                // A lone window the user made shorter keeps its height; the new
                // window takes the rest.
                let f = min(max(f, 0.1), 0.9)
                col.weights = [f]
                col.windows.insert(window, at: at)
                col.weights.insert(1 - f, at: at)
            } else {
                let weight = col.weights.reduce(0, +) / Double(col.weights.count)
                col.windows.insert(window, at: at)
                col.weights.insert(weight, at: at)
            }
        }
        focus(window)
        return true
    }

    /// The user resized `window` to `height` with the mouse, dragging its top
    /// edge (`true`) or bottom edge (`false`). In a stack, the neighbour on
    /// that edge gives or takes the difference and everything else stays put;
    /// a lone window keeps its new height. With `nil`, whichever neighbour
    /// exists (below first) adjusts: used when an app won't go as short as
    /// asked. Returns false if nothing could change.
    @discardableResult
    public mutating func resizeWindow(_ window: W, height: Double, topEdge: Bool?, viewport: Rect) -> Bool {
        let fullH = viewport.h - 2 * gap
        let gap = self.gap
        return withColumn(of: window) { col -> Bool in
            if col.tabbed {
                return false
            }
            let n = col.windows.count
            if n == 1 {
                col.height = height < fullH - snapToFull ? max(height, minHeight) / fullH : nil
                return true
            }
            let row = col.row(of: window)!
            let above: Int? = row > 0 ? row - 1 : nil
            let below: Int? = row + 1 < n ? row + 1 : nil
            let neighbour: Int?
            switch topEdge {
            case true?: neighbour = above
            case false?: neighbour = below
            case nil: neighbour = below ?? above
            }
            guard let nb = neighbour else { return false }
            let usable = fullH - gap * Double(n - 1)
            let total = col.weights.reduce(0, +)
            // Heights are weights too: only their ratios matter.
            var heights = col.weights.map { usable * $0 / total }
            let pair = heights[row] + heights[nb]
            let h = pair > 2 * minHeight ? min(max(height, minHeight), pair - minHeight) : pair / 2
            heights[row] = h
            heights[nb] = pair - h
            // Back to weights averaging 1, the scale every other operation uses.
            col.weights = heights.map { $0 * Double(n) / usable }
            return true
        } ?? false
    }

    /// How many columns (other than `skip`) have their centre left of `centre`.
    func slotFor(_ centre: Double, skip: Int?) -> Int {
        columns.indices.filter { $0 != skip && columnX($0) + columns[$0].width / 2 < centre }.count
    }

    /// Left edge of column `i` in strip coordinates.
    public func columnX(_ i: Int) -> Double {
        gap + columns[..<i].reduce(0) { $0 + $1.width + gap }
    }

    /// Scroll just far enough that the focused column is fully visible.
    public mutating func ensureFocusedVisible(_ viewportW: Double) {
        if focusPinned != nil {
            return
        }
        let viewportW = innerW(viewportW)
        guard columns.indices.contains(focused) else {
            scroll = 0
            return
        }
        let col = columns[focused]
        let x = columnX(focused)
        if x + col.width + gap > scroll + viewportW {
            scroll = x + col.width + gap - viewportW
        }
        // Applied second so a column wider than the viewport stays left-aligned.
        if x - gap < scroll {
            scroll = x - gap
        }
    }

    /// Furthest the strip can scroll: the last column flush with the right edge.
    public func maxScroll(_ viewportW: Double) -> Double {
        let total = columnX(columns.count)
        return max(total - innerW(viewportW), 0)
    }

    /// Scroll freely by `dx` pixels (e.g. following a trackpad swipe), staying in bounds.
    public mutating func scrollBy(_ dx: Double, _ viewportW: Double) {
        scroll = min(max(scroll + dx, 0), maxScroll(viewportW))
    }

    /// Focus the column whose centre is nearest the centre of the viewport,
    /// then scroll so it's fully visible. Used when a swipe ends.
    public mutating func snap(_ viewportW: Double) {
        let centre = scroll + innerW(viewportW) / 2
        let distances = columns.indices.map { abs(columnX($0) + columns[$0].width / 2 - centre) }
        if let i = distances.indices.min(by: { distances[$0] < distances[$1] }) {
            focused = i
            focusPinned = nil
        }
        ensureFocusedVisible(viewportW)
    }

    /// Screen frame for every window at the current scroll offset, with
    /// off-screen columns parked against the viewport edges. Stacked windows
    /// split the column's height by weight; tabbed ones all fill it, below
    /// their tab bar.
    public func frames(_ viewport: Rect) -> [(W, Rect)] {
        let inner = inner(viewport)
        let right = inner.x + inner.w
        let top = viewport.y + gap
        var out: [(W, Rect)] = []
        if let c = pinned[LEFT] {
            columnFrames(c, x: viewport.x + gap, top: top, viewport: viewport, into: &out)
        }
        for (i, c) in columns.enumerated() {
            var x = inner.x + columnX(i) - scroll
            var y = top
            // Parked at the display's edges, not just past the pinned
            // columns: macOS can't be told to keep a pinned window above
            // one parked behind it, and a recently focused window would
            // otherwise cover it.
            if x > right - peek {
                x = viewport.x + viewport.w - peek
                y = parkY[RIGHT] ?? top
            } else if x + c.width < inner.x + peek {
                x = viewport.x + peek - c.width
                y = parkY[LEFT] ?? top
            }
            columnFrames(c, x: x, top: y, viewport: viewport, into: &out)
        }
        if let c = pinned[RIGHT] {
            columnFrames(c, x: viewport.x + viewport.w - gap - c.width, top: top, viewport: viewport, into: &out)
        }
        return out
    }

    /// Frames for the windows of one column whose top edge is at `top`.
    func columnFrames(_ c: Column<W>, x: Double, top: Double, viewport: Rect, into out: inout [(W, Rect)]) {
        let fullH = viewport.h - 2 * gap
        if c.tabbed {
            for w in c.windows {
                out.append((w, Rect(x: x, y: top + tabBar, w: c.width, h: fullH - tabBar)))
            }
            return
        }
        if c.windows.count == 1 {
            let h = c.height.map { min($0 * fullH, fullH) } ?? fullH
            out.append((c.windows[0], Rect(x: x, y: top, w: c.width, h: h)))
            return
        }
        let usable = fullH - gap * Double(c.windows.count - 1)
        let total = c.weights.reduce(0, +)
        var y = top
        for (w, weight) in zip(c.windows, c.weights) {
            let h = usable * weight / total
            out.append((w, Rect(x: x, y: y, w: c.width, h: h)))
            y += h + gap
        }
    }
}
