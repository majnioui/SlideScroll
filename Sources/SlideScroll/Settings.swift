import AppKit
import SwiftUI

private let author = "majnioui"
private let website = "slidescroll.majnioui.me"
private let size = NSSize(width: 620, height: 560)

/// The Settings window, with a tab per topic in its toolbar like System
/// Settings: General (login, updates, setup checks, logging), Windows
/// (swipes, the gap, apps that always float), Shortcuts and About.
final class SettingsWindow: NSWindow, NSWindowDelegate {
    private static var window: SettingsWindow?

    /// Open the Settings window, or bring it to the front.
    static func show() {
        let window = window ?? {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            func tab<V: View>(_ title: String, _ symbol: String, _ view: V) {
                let host = NSHostingController(rootView: view.environmentObject(AppModel.shared).frame(width: size.width, height: size.height))
                host.title = title
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                tabs.addTabViewItem(item)
            }
            tab("General", "gearshape", GeneralTab())
            tab("Windows", "rectangle.split.3x1", WindowsTab())
            tab("Shortcuts", "keyboard", ShortcutsTab())
            tab("About", "info.circle", AboutTab())
            let w = SettingsWindow(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.contentViewController = tabs
            w.toolbarStyle = .preference
            w.setContentSize(size)
            // Reopened from the menu later, so it must outlive being closed.
            w.isReleasedWhenClosed = false
            w.delegate = w
            w.center()
            self.window = w
            return w
        }()
        AppModel.shared.refreshWarnings()
        // SlideScroll has no Dock icon, so its window only gets the keyboard if
        // the app is brought forward.
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Every key press passes through here first, including ones with ⌘ that
    /// would otherwise become menu shortcuts: recording a shortcut takes them all.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && handleKey(event) { return }
        super.sendEvent(event)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let model = AppModel.shared
        let code = event.keyCode
        let mods = UInt64(event.modifierFlags.rawValue) & Mod.all
        guard let (action, slot) = model.recording else {
            // No menu bar of our own, so ⌘W is handled here.
            if mods == Mod.cmd && code == 13 {
                performClose(nil)
                return true
            }
            return false
        }
        switch (code, mods) {
        case (53, 0): break // Escape cancels
        case (51, 0), (117, 0): model.changeKeymap { $0.set(action, slot: slot, nil) } // Delete removes
        default:
            let shortcut = Shortcut(mods: mods, key: code)
            guard shortcut.isValid else {
                // Needs ⌃, ⌥ or ⌘, or it would take over typing. Keep listening.
                NSSound.beep()
                return true
            }
            Log.info("\(actions[action].label) is now on \(shortcut.configText)")
            model.changeKeymap { $0.set(action, slot: slot, shortcut) }
        }
        model.recording = nil
        return true
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.recording = nil
    }

    /// Back from System Settings, perhaps having fixed something.
    func windowDidBecomeKey(_ notification: Notification) {
        AppModel.shared.refreshWarnings()
    }

    /// Recording keeps global shortcuts off, so it stops as soon as the keys
    /// stop coming here, e.g. on switching to another app.
    func windowDidResignKey(_ notification: Notification) {
        if AppModel.shared.recording != nil { AppModel.shared.recording = nil }
    }
}

/// Secondary text under a control.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    private var updateLine: String {
        let now = Update.version
        return switch model.update {
        case .idle: "You have SlideScroll \(now)."
        case .checking: "Checking for updates…"
        case .upToDate: "SlideScroll \(now) is the latest version."
        case .downloading(let v): "Downloading SlideScroll \(v)…"
        case .ready(let v): "SlideScroll \(v) is ready. Restart to install it."
        case .installing: "Installing…"
        case .failed(let e): "Couldn't update: \(e)"
        case .unavailable(let why): why
        }
    }

    var body: some View {
        let available = { if case .unavailable = model.update { false } else { true } }()
        let busy = { switch model.update { case .checking, .downloading, .installing: true; default: false } }()
        Form {
            Section {
                Text(model.statusText).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch SlideScroll at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                    .disabled(!model.bundled)
                if !model.bundled { Note("Available when SlideScroll runs as an app.") }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(get: { Update.autoCheck }, set: { Update.autoCheck = $0 }))
                    .disabled(!available)
                Note(updateLine)
                if case .ready = model.update {
                    Button("Restart to Update") { App.installUpdate() }
                } else {
                    Button("Check Now") { Update.checkNow() }.disabled(!available || busy)
                }
            }
            Section("Setup") {
                if model.warnings.isEmpty {
                    Text("✓  Nothing in macOS is getting in SlideScroll's way.")
                }
                ForEach(model.warnings) { w in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("⚠︎  \(w.title)").bold()
                        Note(w.detail)
                        if let url = w.settings {
                            Button("Open System Settings…") { App.open(url) }
                        }
                    }
                }
                Button("Check Again") { model.refreshWarnings() }
            }
            Section("Troubleshooting") {
                Toggle("Verbose logging", isOn: $model.verbose)
                Note("Writes more detail to the log, to help track down a problem.")
                Button("Show Log in Finder") { App.revealLog() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WindowsTab: View {
    @EnvironmentObject var model: AppModel

    /// Names of the running apps with windows of their own, that don't float yet.
    private var appsToFloat: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .filter { $0 != "SlideScroll" && !model.prefs.floatApps.contains($0) }
        return Array(Set(names)).sorted { $0.lowercased() < $1.lowercased() }
    }

    var body: some View {
        // Set by hand in config.toml to something Settings doesn't offer.
        let gaps = Prefs.gaps.contains(model.prefs.gap) ? Prefs.gaps : Prefs.gaps + [model.prefs.gap]
        Form {
            Section("Trackpad") {
                Picker("Swipe the strip with", selection: Binding(get: { model.prefs.fingers }, set: { n in
                    model.changePrefs { $0.fingers = n }
                    // Whether macOS's own swipes get in the way depends on the count.
                    model.refreshWarnings()
                })) {
                    Text("Three fingers").tag(3)
                    Text("Four fingers").tag(4)
                }
                Note("macOS mustn't use the same swipe: General, Setup says if it does and how to turn it off.")
                Toggle("Natural direction", isOn: Binding(get: { model.prefs.natural }, set: { on in model.changePrefs { $0.natural = on } }))
                Note("The strip moves with your fingers, like scrolling a page. Off, it moves the other way.")
            }
            Section("Layout") {
                Picker("Space between windows", selection: Binding(get: { model.prefs.gap }, set: { g in model.changePrefs { $0.gap = g } })) {
                    ForEach(gaps, id: \.self) { g in Text(g == 0 ? "None" : "\(g.formatted()) pt").tag(g) }
                }
            }
            Section("Always Float") {
                Note("Windows of these apps stay where you put them, outside the strip. To float a single window, use ⌃⌥T.")
                if model.prefs.floatApps.isEmpty { Note("No apps yet.") }
                ForEach(model.prefs.floatApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button("Remove") { model.changePrefs { $0.floatApps.removeAll { $0 == app } } }
                    }
                }
                let candidates = appsToFloat
                Menu("Add App…") {
                    ForEach(candidates, id: \.self) { app in
                        Button(app) { model.changePrefs { $0.floatApps.append(app) } }
                    }
                }
                .disabled(candidates.isEmpty)
                .fixedSize()
                Note("Lists the apps running now.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsTab: View {
    @EnvironmentObject var model: AppModel

    private var groups: [(String, [Int])] {
        var out: [(String, [Int])] = []
        for i in actions.indices {
            if out.last?.0 == actions[i].group { out[out.count - 1].1.append(i) } else { out.append((actions[i].group, [i])) }
        }
        return out
    }

    var body: some View {
        Form {
            Section {
                Note("Click a shortcut, then press the new keys. Esc cancels; Delete removes the shortcut.")
            }
            ForEach(groups, id: \.0) { group, indices in
                Section(group) {
                    ForEach(indices, id: \.self) { i in row(i) }
                }
            }
            Section {
                Button("Restore All Defaults") {
                    model.changeKeymap { $0 = .defaults }
                    model.recording = nil
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ i: Int) -> some View {
        HStack {
            Text(actions[i].label)
            Spacer()
            ForEach(0..<Keymap.slots, id: \.self) { slot in
                let recording = model.recording.map { $0 == (i, slot) } ?? false
                Button {
                    // Clicking the slot that's recording stops recording.
                    model.recording = recording ? nil : (i, slot)
                } label: {
                    Text(recording ? "Type shortcut…" : model.keymap.bindings[i].indices.contains(slot)
                        ? model.keymap.bindings[i][slot].label() : "—")
                        .frame(width: 110)
                }
            }
            Button {
                model.changeKeymap { $0.reset(i) }
                model.recording = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
            .opacity(model.keymap.isDefault(i) ? 0 : 1)
            .disabled(model.keymap.isDefault(i))
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 4) {
            Spacer().frame(height: 40)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("SlideScroll").font(.system(size: 26, weight: .bold)).padding(.top, 12)
            Text("Version \(Update.version)").foregroundStyle(.secondary).padding(.bottom, 14)
            Text("A scrolling window manager for macOS.")
            Text("Made by \(author)").padding(.bottom, 8)
            Link(website, destination: URL(string: "https://\(website)")!)
            Spacer()
            Text("© \(author) · MIT License").font(.caption).foregroundStyle(.tertiary).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }
}
