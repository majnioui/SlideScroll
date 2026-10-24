import CoreGraphics

/// Everything the engine is asked to do, from shortcuts, the trackpad, window
/// events, the UI and its own workers. Handled in order on the engine's queue.
enum Command {
    case focusLeft, focusRight
    case moveLeft, moveRight
    case focusFirst, focusLast
    /// Jump to the column at this index (0-based).
    case focusIndex(Int)
    case cycleWidth, fullWidth, centre, wider, narrower
    /// Take the focused window out of the strip, or put a floating one back.
    case toggleFloat
    /// Focus the window above / below in a stack.
    case focusUp, focusDown
    /// Move the focused window up / down within its stack.
    case moveUp, moveDown
    /// Move the focused window into the stack on its left / right.
    case stackLeft, stackRight
    /// Take the focused window out of its stack into a new column.
    case popLeft, popRight
    case taller, shorter, equalizeHeights, toggleTabbed
    /// Pin the focused column to the left / right edge, or unpin it.
    case pinLeft, pinRight
    /// Focus the strip on the next display.
    case focusNextDisplay
    /// Move the focused window to the next display's strip.
    case sendToNextDisplay
    case quit

    /// A tab was clicked: focus its window.
    case focusWindow(CGWindowID)
    /// Displays were connected, removed or rearranged, or their usable area changed.
    case displaysChanged([Display])
    /// Stop managing windows and bring them all on screen, until `resume`.
    case pause, resume
    /// The Mac is going to sleep, the screen locked, or the user switched
    /// away. Windows and displays come and go meanwhile; none of it counts.
    case suspend
    /// Back from `suspend`, with the displays as they are now.
    case wake([Display])
    /// Trackpad swipe moved by this fraction of the trackpad width.
    case swipe(Double)
    /// Swipe released, with its speed in trackpad widths per second.
    case swipeEnd(Double)
    /// The display is about to show a frame: when it will be on screen, in seconds.
    case frame(at: Double)
    /// A window was opened, closed, minimised, hidden or shown.
    case windowsChanged
    /// An app was activated or its focused window changed; carries the
    /// newly focused window when the event told us which one it is.
    case focusChanged(CGWindowID?)
    /// The user is moving or resizing this window with the mouse.
    case windowDragged(CGWindowID)
    /// A window we asked to focus has been focused.
    case focused(CGWindowID)
    /// A resize we asked for has been applied: the size asked for, and the
    /// size the app actually took.
    case resized(CGWindowID, want: CGSize, got: CGSize)
    /// A window moved or resized without the mouse: our animation, or
    /// something else (macOS tiling, another app) that needs undoing.
    case windowMoved(CGWindowID)
    /// The space between windows changed in Settings.
    case setGap(Double)
    /// The apps whose windows always float changed in Settings.
    case setFloatApps([String])
    /// "Reduce motion" was turned on or off in Accessibility settings.
    case setReduceMotion(Bool)
}
