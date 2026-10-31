// What undo puts back: the order of a strip's columns, their stacks, widths,
// heights, tabs and pins, and which window had focus. Not the scroll: that
// follows focus.

public struct Arrangement<W: Equatable>: Equatable {
    var columns: [Column<W>]
    var pinned: [Column<W>?]
    var focusedWindow: W?

    /// Every window in it, pinned ones included.
    public var windows: [W] { (pinned[LEFT]?.windows ?? []) + columns.flatMap(\.windows) + (pinned[RIGHT]?.windows ?? []) }

    /// The same columns, whichever window has focus. Moving focus alone
    /// isn't something to undo.
    public func sameLayout(_ other: Arrangement<W>) -> Bool {
        let unfocused = { (c: Column<W>) -> Column<W> in var c = c; c.active = 0; return c }
        return columns.map(unfocused) == other.columns.map(unfocused)
            && pinned.map { $0.map(unfocused) } == other.pinned.map { $0.map(unfocused) }
    }
}

extension Strip {
    public var arrangement: Arrangement<W> {
        Arrangement(columns: columns, pinned: pinned, focusedWindow: focusedWindow)
    }

    /// Go back to `a`. Windows that have closed since (`exists` is false)
    /// are left out; windows that weren't open then (`isNew`) keep their
    /// columns, right of the focused one.
    public mutating func restore(_ a: Arrangement<W>, exists: (W) -> Bool, isNew: (W) -> Bool) {
        let newcomers = allColumns.compactMap { c -> Column<W>? in
            var c = c
            c.retain(isNew)
            return c.windows.isEmpty ? nil : c
        }
        let current = focusedWindow
        columns = a.columns.compactMap { c in
            var c = c
            c.retain(exists)
            return c.windows.isEmpty ? nil : c
        }
        for s in 0..<2 {
            var c = a.pinned[s]
            c?.retain(exists)
            pinned[s] = c?.windows.isEmpty == false ? c : nil
        }
        focusPinned = nil
        focused = 0
        if let w = a.focusedWindow, exists(w) { focus(w) } else if let w = current, contains(w) { focus(w) }
        let at = columns.isEmpty ? 0 : focused + 1
        columns.insert(contentsOf: newcomers, at: min(at, columns.count))
    }
}
