import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let blocker = SleepBlocker()
    private let tracker = AgentTracker()
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private var tickTimer: Timer?
    private var settingsWindow: NSWindow?
    private var applyScheduled = false

    private var manualOn = false
    private var manualUntil: Date?
    private var pausedForBattery: Int?   // battery % when paused
    private var lidActive = false
    private var warnedHot = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LidMode.resetIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Notifier.shared.setup()
        tracker.onTransition = { [weak self] session, duration, reason in
            self?.agentStopped(session, after: duration, reason: reason)
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(hookReceived(_:)), name: Prefs.hookNotification,
            object: nil, suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)

        updater.onChange = { [weak self] in self?.updateIcon() }
        updater.start()

        tick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        blocker.disable()
        LidMode.set(false)
    }

    // MARK: State

    private func tick() {
        if let until = manualUntil, Date() >= until {
            manualOn = false
            manualUntil = nil
        }
        if Prefs.autoMode {
            tracker.refresh(processes: ProcessTable.snapshot(),
                            names: Set(Prefs.agentNames.map { $0.lowercased() }), now: Date())
        } else {
            tracker.reset()
        }
        apply()
    }

    @objc private func hookReceived(_ note: Notification) {
        guard Prefs.autoMode, let message = HookMessage(userInfo: note.userInfo) else { return }
        tracker.handle(message, now: Date())
        apply()
    }

    @objc private func defaultsChanged() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyScheduled = false
            self?.tick()
        }
    }

    private func apply() {
        tracker.evaluate(now: Date())
        let working = tracker.working
        let wantAwake = manualOn || !working.isEmpty

        let battery = Power.battery()
        let limit = Prefs.batteryLimit
        if let battery, battery.onBattery, limit > 0, battery.percent <= limit {
            if wantAwake && pausedForBattery == nil {
                Notifier.shared.post(title: "Agent Mode paused",
                                     body: "Battery is at \(battery.percent)%, so your Mac can sleep now. Plug in to keep agents running.")
            }
            pausedForBattery = battery.percent
        } else {
            pausedForBattery = nil
        }

        let awake = wantAwake && pausedForBattery == nil
        if awake {
            let reason = manualOn ? "Agent Mode: kept awake manually"
                : "Agent Mode: \(working.map(\.agent).joined(separator: ", ")) working"
            blocker.enable(keepDisplayOn: Prefs.keepDisplayOn, reason: reason)
        } else {
            blocker.disable()
        }

        let hot = Power.isHot
        if awake && Prefs.lidMode && hot && !warnedHot {
            Notifier.shared.post(title: "Agent Mode: Mac is hot",
                                 body: "Closed-lid mode is off until it cools down. Open the lid to keep agents running.")
        }
        warnedHot = hot
        lidActive = awake && Prefs.lidMode && !hot && LidMode.helperInstalled
        LidMode.set(lidActive)

        updateIcon()
    }

    private func agentStopped(_ session: AgentSession, after duration: TimeInterval, reason: FinishReason) {
        guard Prefs.notifyOnFinish, duration >= TimeInterval(Prefs.notifyMinMinutes * 60) else { return }
        let place = session.project.map { " in \($0)" } ?? ""
        switch reason {
        case .finished:
            Notifier.shared.post(title: "\(session.agent) finished\(place)", body: "Worked for \(Self.format(duration)).")
        case .waiting:
            Notifier.shared.post(title: "\(session.agent) needs you\(place)",
                                 body: session.waitingDetail ?? "Waiting for your input after \(Self.format(duration)).")
        }
    }

    // MARK: UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if pausedForBattery != nil {
            let image = NSImage(systemSymbolName: "battery.25", accessibilityDescription: "Agent Mode paused")
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = blocker.isActive ? MenuIcon.awake : MenuIcon.asleep
        }
        button.toolTip = statusText()
    }

    private func statusText() -> String {
        if let percent = pausedForBattery { return "Paused: battery at \(percent)%" }
        let lid = lidActive ? ", even with the lid closed" : ""
        if manualOn {
            if let until = manualUntil { return "Awake for \(Self.format(until.timeIntervalSinceNow)) more\(lid)" }
            return "Awake until turned off\(lid)"
        }
        let working = tracker.working
        if !working.isEmpty { return "Awake: \(working.map(\.agent).joined(separator: ", ")) working\(lid)" }
        return Prefs.autoMode ? "Sleep allowed (no agents working)" : "Sleep allowed"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(max(m, 1))m"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        tick()
        menu.removeAllItems()

        menu.addItem(disabledItem(statusText()))
        let now = Date()
        for session in tracker.sortedSessions {
            let state: String
            if let since = session.workingSince {
                state = "working \(Self.format(now.timeIntervalSince(since)))"
            } else {
                state = session.waiting ? "needs you" : "idle"
            }
            let place = session.project.map { " · \($0)" } ?? ""
            menu.addItem(disabledItem("    \(session.agent)\(place) — \(state)"))
        }
        menu.addItem(.separator())

        menu.addItem(item(manualOn ? "Turn Off" : "Keep Awake", #selector(toggleManual)))
        let durationItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, minutes) in [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            let entry = item(title, #selector(keepAwakeFor(_:)))
            entry.tag = minutes
            sub.addItem(entry)
        }
        durationItem.submenu = sub
        menu.addItem(durationItem)
        menu.addItem(.separator())

        let auto = item("Stay Awake While Agents Work", #selector(toggleAuto))
        auto.state = Prefs.autoMode ? .on : .off
        menu.addItem(auto)
        if LidMode.helperInstalled {
            let lid = item("Stay Awake With Lid Closed", #selector(toggleLid))
            lid.state = Prefs.lidMode ? .on : .off
            menu.addItem(lid)
        }
        menu.addItem(.separator())

        if !ClaudeHooks.isInstalled() {
            let hooks = item("Set Up Claude Code Hooks…", #selector(installClaudeHooks))
            hooks.toolTip = "Lets Agent Mode know exactly when Claude Code is working, instead of guessing from CPU use."
            menu.addItem(hooks)
        }
        if let update = updater.available {
            menu.addItem(item("Update Available (v\(update.version))…", #selector(openUpdate)))
        }
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem(title: "Quit Agent Mode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func toggleManual() {
        manualOn.toggle()
        manualUntil = nil
        apply()
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        manualOn = true
        manualUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        apply()
    }

    @objc private func toggleAuto() {
        Prefs.autoMode.toggle()
    }

    @objc private func toggleLid() {
        _ = setLidMode(!Prefs.lidMode)
    }

    @objc private func installClaudeHooks() {
        let alert = NSAlert()
        alert.messageText = "Set up Claude Code hooks?"
        alert.informativeText = """
        Claude Code will tell Agent Mode when it starts and stops working, so your Mac stays awake exactly as long as it needs to, and you get a notification when it finishes.

        This adds hooks to ~/.claude/settings.json and saves a backup next to it. New Claude Code sessions pick them up. You can remove them in Settings.
        """
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeHooks.install()
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't set up Claude Code hooks"
            failed.informativeText = error.localizedDescription
            failed.runModal()
        }
    }

    @objc private func openUpdate() {
        if let url = updater.available?.url { NSWorkspace.shared.open(url) }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(setLidMode: { [weak self] in self?.setLidMode($0) ?? false })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Agent Mode Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Turns closed-lid mode on (installing the helper after a warning) or off. Returns the resulting state.
    private func setLidMode(_ on: Bool) -> Bool {
        if on && !LidMode.helperInstalled {
            let alert = NSAlert()
            alert.messageText = "Stay awake with the lid closed?"
            alert.informativeText = """
            Agent Mode will keep your Mac awake with the lid closed, but only while agents are working.

            A closed Mac in a bag can overheat. Agent Mode turns this off when the Mac gets hot or the battery hits your limit, but keep it somewhere with airflow.

            macOS will ask for your admin password once, to allow Agent Mode to run "pmset disablesleep".
            """
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            do {
                try LidMode.installHelper()
            } catch {
                if error.localizedDescription != "Cancelled." {
                    let failed = NSAlert()
                    failed.messageText = "Couldn't turn on closed-lid mode"
                    failed.informativeText = error.localizedDescription
                    failed.runModal()
                }
                return false
            }
        }
        Prefs.lidMode = on
        apply()
        return on
    }
}
