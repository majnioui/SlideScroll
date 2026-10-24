import Foundation

// Checks for the layout core: `swift run core-checks`. A small runner instead
// of XCTest or Swift Testing, so it works with just the command line tools.

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    if !condition() {
        failures += 1
        print("  ✘ \(file):\(line) \(message)")
    }
}

let checks: [(String, () -> Void)] = [
    ("twoHalvesFillTheScreen", twoHalvesFillTheScreen),
    ("newWindowsOpenRightOfFocusAndClosedOnesLeave", newWindowsOpenRightOfFocusAndClosedOnesLeave),
    ("scrollsJustEnoughAndParksTheRest", scrollsJustEnoughAndParksTheRest),
    ("stackingPoppingAndOwnWidths", stackingPoppingAndOwnWidths),
    ("tabsAddedToFitGoOnceOneWindowIsLeft", tabsAddedToFitGoOnceOneWindowIsLeft),
    ("tabbedColumnsLeaveRoomForTheTabBar", tabbedColumnsLeaveRoomForTheTabBar),
    ("closingAStackedWindowKeepsTheRest", closingAStackedWindowKeepsTheRest),
    ("droppingOntoAWindowStacksIt", droppingOntoAWindowStacksIt),
    ("draggedWindowsLandWhereDropped", draggedWindowsLandWhereDropped),
    ("resizingAStackedWindowMovesOnlyTheSharedEdge", resizingAStackedWindowMovesOnlyTheSharedEdge),
    ("aLoneWindowKeepsItsHeightUntilStacked", aLoneWindowKeepsItsHeightUntilStacked),
    ("pinnedColumnsStayPutAndOthersParkClearOfThem", pinnedColumnsStayPutAndOthersParkClearOfThem),
    ("focusStepsOntoAndOffPins", focusStepsOntoAndOffPins),
    ("widthsCycleAndFullWidthToggles", widthsCycleAndFullWidthToggles),
    ("widthsFitBetweenPinnedColumns", widthsFitBetweenPinnedColumns),
    ("swipesStayInBoundsAndSnap", swipesStayInBoundsAndSnap),
    ("mergingRestoresSavedStacks", mergingRestoresSavedStacks),
    ("layoutSpringIsGentle", layoutSpringIsGentle),
    ("followSpringIsTightAndSurvivesLateFrames", followSpringIsTightAndSurvivesLateFrames),
]

for (name, check) in checks {
    let before = failures
    check()
    print(failures == before ? "✔ \(name)" : "✘ \(name)")
}
print(failures == 0 ? "\(checks.count) checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
