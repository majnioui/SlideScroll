# Changelog

## 0.3.0

### Added

- A strip indicator: while you move with a shortcut or a swipe, the strip's
  columns show as app icons at the bottom of the screen for a moment, the
  focused one highlighted. Click one to jump to it. Turn it off in Settings →
  Windows.
- An outline around the focused window, in your accent colour. Turn it on in
  Settings → Windows.
- Undo and redo for the layout: `⌃⌥Z` puts back the last change made by a
  shortcut or a drag (moving, stacking, widths, heights, pins, tabs), `⌃⌥⇧Z`
  redoes it. Windows opened since stay; ones closed since stay closed.
- `⌃⌥⇥` jumps back to the window you were in before this one.
- The menu bar menu lists the strip's windows in order, with the focused one
  ticked. Pick one to jump to it.

## 0.2.0

### Added

- A `slidescroll://` URL for every action (`slidescroll://cycle-width`,
  `slidescroll://focus-window-3`, …) plus `pause`, `resume`, `toggle-pause` and
  `settings`, so Raycast, Alfred, Shortcuts and scripts can drive SlideScroll.
  The app's binary takes the same names: `slidescroll focus-left`.
- Opening widths per app: new windows of an app can open at ¼, ⅓, ½, ⅔, ¾ or
  the full screen instead of half. Set them in Settings → Windows, or under
  `[apps.width]` in config.toml.
- A Buy Me a Coffee link in Settings → About.

## 0.1.2

### Changed

- Two windows stacked in one column whose apps won't get short enough to share
  it (T3 Code and Chrome, say) now overlap instead of turning into tabs. Each
  keeps the shortest height its app allows, the bottom one stays fully on
  screen, and the one you focus comes to the front.

### Fixed

- Chrome and Electron apps report their old size for a moment after a resize,
  which could be taken for the shortest they'd go. SlideScroll now looks again
  before believing a size it didn't ask for.

## 0.1.1

### Fixed

- Dragging a window that wasn't focused made it shake under the pointer, and
  dropping it on another window didn't stack it: the drag only counted once
  macOS reported the window as focused. A window grabbed by its title bar now
  counts at once.
- Two windows stacked in one column, whose apps both refuse to get shorter
  (T3 Code and Chrome, say), bounced against each other forever. Once their
  shortest heights can't share the column, they're shown as tabs right away.
- Verbose logging recorded every key press. It now logs only shortcuts.

## 0.1.0

A fresh start for SlideScroll. It does everything the earlier releases did, with
the same shortcuts and swipes, and keeps your settings and saved layout:

- Windows on an endless strip per display, each column at the width you gave it.
- Stacks, tabs with a frosted tab bar, and columns pinned to either edge.
- Four- or three-finger swipes, and a shortcut for every move, all changeable in
  Settings.
- Animation timed to the display's refresh, with moves, resizes and focus
  changes that never wait on a slow app.
- Setup checks, Launch at Login, automatic updates, and Reduce Motion support.

### Fixed

- With a column pinned, moving focus to another window of the pinned window's
  app no longer sends focus back to the pinned window.

Coming from an earlier release (0.1.1 to 0.5.3)? Install this one once from the
website or the disk image; it updates itself from here on.
