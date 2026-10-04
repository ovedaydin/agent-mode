import AppKit
import SwiftUI

/// What to put the Mac to sleep after, if anything.
private enum SleepPlan: Equatable {
    case none
    case allAgents
    case session(pid_t)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let sleepDelay: TimeInterval = 120

    private let blocker = SleepBlocker()
    private let tracker = AgentTracker()
    private let updater = Updater()
    private let tasksWindow = TasksWindowController()
    private let pairWindow = PairWindowController()
    private var statusItem: NSStatusItem!
    private var tickTimer: Timer?
    private var settingsWindow: NSWindow?
    private var applyScheduled = false

    private var manualOn = false
    private var manualUntil: Date?
    private var pausedForBattery: Int?   // battery % when paused
    private var lidActive = false
    private var warnedHot = false

    private var sleepPlan = SleepPlan.none
    private var sleepPlanSawWork = false  // only sleep after something has actually worked
    private var sleepAt: Date?

    private var animationTimer: Timer?
    private var animationFrame = 0
    private var lastAccounted: Date?

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
        accountWorkingTime(now: Date(), force: true)
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
            tracker.refresh(processes: ProcessTable.snapshot(), network: ProcessTable.networkBytesIn(),
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
        let now = Date()
        tracker.evaluate(now: now)
        accountWorkingTime(now: now)
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

        updateSleepPlan(now: now)
        updateAnimation()
        updateIcon()
    }

    // MARK: Sleep when done

    private func updateSleepPlan(now: Date) {
        let done: Bool
        switch sleepPlan {
        case .none:
            sleepAt = nil
            return
        case .allAgents:
            if !tracker.working.isEmpty || manualOn { sleepPlanSawWork = true }
            done = sleepPlanSawWork && tracker.working.isEmpty && !manualOn
        case .session(let pid):
            done = tracker.sessions[pid]?.workingSince == nil
        }

        guard done else {
            sleepAt = nil  // work resumed, so wait for it to finish again
            return
        }
        if let at = sleepAt {
            if now >= at { sleepNow() }
        } else {
            sleepAt = now.addingTimeInterval(Self.sleepDelay)
            Notifier.shared.post(title: "Your Mac will sleep in 2 minutes",
                                 body: "Agents are done. To stay awake, choose Cancel Sleep in the Agent Mode menu.")
        }
    }

    private func sleepNow() {
        sleepPlan = .none
        sleepAt = nil
        manualOn = false
        manualUntil = nil
        blocker.disable()
        LidMode.set(false)
        lidActive = false
        updateIcon()

        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        pmset.standardOutput = FileHandle.nullDevice
        try? pmset.run()
    }

    // MARK: Stats

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private lazy var today: (day: String, seconds: TimeInterval) = Prefs.stats

    private var workedToday: TimeInterval {
        today.day == Self.dayFormatter.string(from: Date()) ? today.seconds : 0
    }

    /// Adds time with at least one agent working to today's total. Saves at most once a minute,
    /// since every save triggers a defaults-change refresh.
    private func accountWorkingTime(now: Date, force: Bool = false) {
        let day = Self.dayFormatter.string(from: now)
        if today.day != day { today = (day, 0) }
        let before = today.seconds
        if let last = lastAccounted {
            today.seconds += max(0, min(now.timeIntervalSince(last), 30))  // skip time spent asleep
        }
        lastAccounted = tracker.working.isEmpty ? nil : now
        if force || Int(today.seconds / 60) != Int(before / 60) || Prefs.stats.day != day {
            Prefs.stats = today
        }
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
        } else if blocker.isActive {
            button.image = MenuIcon.awakeFrames[animationFrame % MenuIcon.awakeFrames.count]
        } else {
            button.image = MenuIcon.asleep
        }

        // Longest-running agent's time next to the icon, e.g. "47m".
        let started = tracker.working.compactMap(\.workingSince).min()
        if Prefs.showTimer, blocker.isActive, let started {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: " " + Self.format(Date().timeIntervalSince(started)),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }
        button.toolTip = statusText()
    }

    /// Animates the steam while agents are working.
    private func updateAnimation() {
        let animate = blocker.isActive && !tracker.working.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.animationFrame += 1
                self.updateIcon()
            }
        } else if !animate, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
            animationFrame = 0
        }
    }

    private func statusText() -> String {
        if let percent = pausedForBattery { return "Paused: battery at \(percent)%" }
        let lid = lidActive ? ", even with the lid closed" : ""
        if manualOn {
            if let until = manualUntil { return "Awake for \(Self.format(until.timeIntervalSinceNow)) more\(lid)" }
            return "Awake until turned off\(lid)"
        }
        let working = tracker.working
        let plan = sleepPlan == .none ? "" : ". Sleeps when done"
        if !working.isEmpty { return "Awake: \(working.map(\.agent).joined(separator: ", ")) working\(lid)\(plan)" }
        return Prefs.autoMode ? "Sleep allowed (no agents working)" : "Sleep allowed"
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
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
            let line = NSMenuItem(title: "    \(session.agent)\(place) — \(state)", action: nil, keyEquivalent: "")
            if session.workingSince != nil || sleepPlan == .session(session.pid) {
                let sub = NSMenu()
                let sleepItem = item("Sleep When This Finishes", #selector(sleepAfterSession(_:)))
                sleepItem.tag = Int(session.pid)
                sleepItem.state = sleepPlan == .session(session.pid) ? .on : .off
                sub.addItem(sleepItem)
                line.submenu = sub
            } else {
                line.isEnabled = false
            }
            menu.addItem(line)
        }
        if TasksWindowController.proInstalled {
            menu.addItem(item("Open Tasks…", #selector(openTasks), key: "t"))
            menu.addItem(item("Pair Phone…", #selector(openPairing)))
        }
        if workedToday >= 60 {
            menu.addItem(disabledItem("Today: agents worked \(Self.format(workedToday))"))
        }
        if let at = sleepAt {
            menu.addItem(item("Sleeping in \(Self.formatSeconds(at.timeIntervalSince(now))) — Cancel Sleep", #selector(cancelSleep)))
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
        let sleepAll = item("Sleep When All Agents Finish", #selector(sleepAfterAll))
        sleepAll.state = sleepPlan == .allAgents ? .on : .off
        sleepAll.toolTip = "Puts the Mac to sleep 2 minutes after the last agent finishes. Turns itself off after that."
        menu.addItem(sleepAll)
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

    @objc private func openPairing() {
        pairWindow.show()
    }

    @objc private func openTasks() {
        tasksWindow.show()
    }

    @objc private func sleepAfterAll() {
        sleepPlan = sleepPlan == .allAgents ? .none : .allAgents
        sleepPlanSawWork = false
        sleepAt = nil
        apply()
    }

    @objc private func sleepAfterSession(_ sender: NSMenuItem) {
        let plan = SleepPlan.session(pid_t(sender.tag))
        sleepPlan = sleepPlan == plan ? .none : plan
        sleepAt = nil
        apply()
    }

    @objc private func cancelSleep() {
        sleepPlan = .none
        sleepAt = nil
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
