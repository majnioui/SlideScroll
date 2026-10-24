import SlideScrollCore

// Behaviour people rely on, and the bugs that were fixed in it.

private let vp = Rect(x: 0, y: 0, w: 1000, h: 800)

/// `n` windows, each half the viewport wide.
private func strip(_ n: UInt32) -> Strip<UInt32> {
    var s = Strip<UInt32>(gap: 10, peek: 8)
    s.sync(Array(0..<n), newWidth: 485)
    return s
}

private func cols(_ s: Strip<UInt32>) -> [[UInt32]] {
    s.columns.map(\.windows)
}

func twoHalvesFillTheScreen() {
    let s = strip(2)
    expect(s.presetWidth(0.5, vp.w) == 485)
    let f = s.frames(vp)
    expect(f[0].1 == Rect(x: 10, y: 10, w: 485, h: 780))
    expect(f[1].1.x + 485 + 10 == vp.w)
}

func newWindowsOpenRightOfFocusAndClosedOnesLeave() {
    var s = strip(3)
    s.focused = 0
    s.sync([0, 1, 2, 7, 8], newWidth: 100)
    expect(cols(s) == [[0], [7], [8], [1], [2]])
    expect(s.focusedWindow == 0)

    s.focused = 4
    s.sync([0, 7], newWidth: 100)
    expect(cols(s) == [[0], [7]])
    expect(s.focused == 1, "focus stays in range")
}

func scrollsJustEnoughAndParksTheRest() {
    var s = strip(4)
    let f = s.frames(vp)
    expect(f[2].1.x == vp.w - 8, "parked right, peeking 8 pt")

    s.focused = 2
    s.ensureFocusedVisible(vp.w)
    expect(s.scroll == 1495 - vp.w)
    s.focused = 3
    s.ensureFocusedVisible(vp.w)
    expect(s.frames(vp)[0].1.x == 8 - 485, "parked left, peeking 8 pt")
}

func stackingPoppingAndOwnWidths() {
    var s = strip(3)
    s.columns[0].width = 300
    s.columns[1].width = 600
    s.focused = 1
    let r1 = s.stackInto(-1)
    expect(r1)
    expect(cols(s) == [[0, 1], [2]])
    expect(s.columns[0].width == 300, "the stack keeps its column's width")
    let f = s.frames(vp)
    expect(f[0].1.h == f[1].1.h, "equal halves")

    let r2 = s.popOut(1)

    expect(r2)
    expect(cols(s) == [[0], [1], [2]])
    expect(s.columns[1].width == 600, "the window gets its own width back")
    let r3 = s.popOut(1)
    expect(!r3, "a lone window has nothing to pop out of")
}

func stacksTooTallToShareOverlapOnScreen() {
    var s = strip(2)
    s.focused = 1
    s.stackInto(-1)
    // Apps that won't go shorter than 620 and 375: 995 plus the gap won't fit in 780.
    let mins: [UInt32: Double] = [0: 620, 1: 375]
    let f = s.frames(vp) { mins[$0] ?? 0 }
    expect(f[0].1 == Rect(x: 10, y: 10, w: 485, h: 620), "the top one keeps its height, at the top")
    expect(f[1].1.h == 375, "so does the bottom one")
    expect(f[1].1.y + f[1].1.h == 790, "with its bottom edge on screen")
    expect(f[1].1.y < f[0].1.y + f[0].1.h, "overlapping the one above")

    // When their shortest heights do fit, they share the column as usual.
    let g = s.frames(vp) { [0: 300, 1: 300][$0] ?? 0 }
    expect(g[0].1.h == 385 && g[1].1.h == 385)
}

func tabbedColumnsLeaveRoomForTheTabBar() {
    var s = strip(2)
    s.tabBar = 30
    s.focused = 1
    s.stackInto(-1)
    s.toggleTabbed()
    let f = s.frames(vp)
    expect(f[0].1 == Rect(x: 10, y: 40, w: 485, h: 750))
    expect(f[0].1 == f[1].1)
}

func closingAStackedWindowKeepsTheRest() {
    var s = strip(3)
    s.focused = 1
    s.stackInto(-1)
    s.sync([0, 2], newWidth: 100)
    expect(cols(s) == [[0], [2]])
    expect(s.focusedWindow == 0)
}

func droppingOntoAWindowStacksIt() {
    var s = strip(3)
    s.columns[2].width = 700
    let r4 = s.stackOnto(2, target: 0, below: true)
    expect(r4)
    expect(cols(s) == [[0, 2], [1]])
    expect(s.focusedWindow == 2)
    let r5 = s.popOut(1)
    expect(r5)
    expect(s.columns[1].width == 700, "keeps the width it had before")
}

func draggedWindowsLandWhereDropped() {
    var s = strip(4) // centres at ~252, 747, 1242, 1737
    let r6 = s.reinsert(0, centre: 1000, width: 300)
    expect(r6)
    expect(cols(s) == [[1], [0], [2], [3]])
    expect(s.columns[1].width == 300)

    // Out of a stack, the window leaves the stack.
    var t = strip(3)
    t.focused = 1
    t.stackInto(-1)
    let r7 = t.reinsert(1, centre: 2000, width: 300)
    expect(r7)
    expect(cols(t) == [[0], [2], [1]])
}

func resizingAStackedWindowMovesOnlyTheSharedEdge() {
    var s = strip(3)
    s.focused = 1
    s.stackInto(-1)
    s.focused = 1
    s.stackInto(-1) // [[0, 1, 2]]
    let usable = 780.0 - 20
    let third = usable / 3

    let r8 = s.resizeWindow(0, height: third + 100, topEdge: false, viewport: vp)

    expect(r8)
    var h = s.frames(vp).map(\.1.h)
    expect(abs(h[0] - (third + 100)) < 1e-9)
    expect(abs(h[1] - (third - 100)) < 1e-9)
    expect(abs(h[2] - third) < 1e-9)

    // Never below the minimum.
    let r9 = s.resizeWindow(2, height: 600, topEdge: true, viewport: vp)
    expect(r9)
    h = s.frames(vp).map(\.1.h)
    expect(abs(h[1] - minHeight) < 1e-9)
}

func aLoneWindowKeepsItsHeightUntilStacked() {
    var s = strip(2)
    let r10 = s.resizeWindow(0, height: 390, topEdge: false, viewport: vp)
    expect(r10)
    expect(s.frames(vp)[0].1.h == 390)
    s.stackOnto(1, target: 0, below: true)
    expect(s.columns[0].height == nil)
}

func pinnedColumnsStayPutAndOthersParkClearOfThem() {
    var s = strip(4)
    let r11 = s.togglePin(LEFT)
    expect(r11)
    expect(s.inner(vp) == Rect(x: 495, y: 0, w: 505, h: 800))
    s.focusLast()
    s.ensureFocusedVisible(vp.w)
    let f = s.frames(vp)
    expect(f[0].1.x == 10, "the pinned column doesn't move")
    expect(f[1].1.x == 8 - 485, "parked at the display's edge, not under the pin")

    // Same key unpins.
    var t = strip(3)
    t.focused = 2
    t.togglePin(RIGHT)
    let r12 = t.togglePin(RIGHT)
    expect(r12)
    expect(cols(t) == [[0], [1], [2]])
}

func focusStepsOntoAndOffPins() {
    var s = strip(3)
    s.focused = 2
    s.togglePin(RIGHT)
    let r13 = s.focusRight()
    expect(!r13)
    let r14 = s.focusLeft()
    expect(r14)
    expect(s.focusedWindow == 1)
    let r15 = s.focusRight()
    expect(r15)
    expect(s.focusedWindow == 2)
}

func widthsCycleAndFullWidthToggles() {
    var s = strip(1)
    s.cycleWidth(vp.w)
    expect(abs(s.columns[0].width - s.presetWidth(2.0 / 3, vp.w)) < 1e-9)
    s.cycleWidth(vp.w)
    s.cycleWidth(vp.w)
    expect(abs(s.columns[0].width - s.presetWidth(0.25, vp.w)) < 1e-9, "wraps around")

    var t = strip(2)
    t.toggleFullWidth(vp.w)
    expect(t.columns[0].width == 980)
    t.toggleFullWidth(vp.w)
    expect(t.columns[0].width == 485)
}

func widthsFitBetweenPinnedColumns() {
    var s = strip(3)
    s.togglePin(LEFT) // 505 left for the strip
    s.focusIndex(0)
    s.toggleFullWidth(vp.w)
    expect(s.columns[0].width == 505 - 20)
}

func swipesStayInBoundsAndSnap() {
    var s = strip(4) // strip ends at 1990
    s.scrollBy(5000, vp.w)
    expect(s.scroll == 990)
    s.scroll = 800
    s.snap(vp.w)
    expect(s.focused == 2)
    expect(s.scroll == 800, "already fully visible, no jump")
}

func mergingRestoresSavedStacks() {
    var s = strip(3)
    s.columns[0].weights = [250]
    s.columns[2].width = 200
    s.focused = 2
    s.mergeIntoPrevious(2)
    expect(cols(s) == [[0], [1, 2]])
    expect(s.columns[1].widths == [485, 200])
    expect(s.focused == 1)
}
