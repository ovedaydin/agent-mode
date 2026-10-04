import AppKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Sleep prevention

final class SleepBlocker {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    var isActive: Bool { systemAssertion != 0 }

    func enable(keepDisplayOn: Bool, reason: String) {
        if systemAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &systemAssertion)
        }
        if keepDisplayOn, displayAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &displayAssertion)
        } else if !keepDisplayOn, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    func disable() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }
}

// MARK: - Agent process detection

enum AgentDetector {
    static let defaultNames = ["claude", "codex", "aider", "gemini", "cursor-agent", "opencode", "amp", "goose"]

    static var names: [String] {
        UserDefaults.standard.stringArray(forKey: "agentProcessNames") ?? defaultNames
    }

    /// Returns the names of agent processes currently running (exact process-name match).
    static func runningAgents() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Axo", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let wanted = Set(names.map { $0.lowercased() })
        var found = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let base = (line.split(separator: "/").last.map(String.init) ?? "").lowercased()
            if wanted.contains(base) { found.insert(base) }
        }
        return found.sorted()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let blocker = SleepBlocker()
    private var statusItem: NSStatusItem!
    private var tickTimer: Timer?

    private let defaults = UserDefaults.standard
    private var manualOn = false
    private var manualUntil: Date?
    private var detectedAgents: [String] = []

    private var autoMode: Bool {
        get { defaults.object(forKey: "autoMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoMode") }
    }
    private var keepDisplayOn: Bool {
        get { defaults.bool(forKey: "keepDisplayOn") }
        set { defaults.set(newValue, forKey: "keepDisplayOn") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        blocker.disable()
    }

    // Re-evaluate state: expire timers, scan for agents, apply assertion, refresh icon.
    private func tick() {
        if let until = manualUntil, Date() >= until {
            manualOn = false
            manualUntil = nil
        }
        detectedAgents = autoMode ? AgentDetector.runningAgents() : []
        apply()
    }

    private func apply() {
        let shouldBeAwake = manualOn || !detectedAgents.isEmpty
        if shouldBeAwake {
            let reason = manualOn ? "Agent Mode: kept awake manually" : "Agent Mode: agents running (\(detectedAgents.joined(separator: ", ")))"
            blocker.enable(keepDisplayOn: keepDisplayOn, reason: reason)
        } else {
            blocker.disable()
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = blocker.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agent Mode")
        image?.isTemplate = true
        button.image = image
        button.toolTip = statusText()
    }

    private func statusText() -> String {
        if manualOn {
            if let until = manualUntil {
                return "Awake for \(Self.format(until.timeIntervalSinceNow)) more"
            }
            return "Awake until turned off"
        }
        if !detectedAgents.isEmpty {
            return "Awake: \(detectedAgents.joined(separator: ", ")) running"
        }
        return autoMode ? "Sleep allowed (no agents running)" : "Sleep allowed"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(max(m, 1))m"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        tick()
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: manualOn ? "Turn Off" : "Keep Awake",
                                action: #selector(toggleManual), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let durationItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, minutes) in [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            let item = NSMenuItem(title: title, action: #selector(keepAwakeFor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            sub.addItem(item)
        }
        durationItem.submenu = sub
        menu.addItem(durationItem)
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "Auto: Stay Awake While Agents Run", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoMode ? .on : .off
        auto.toolTip = "Watches for: " + AgentDetector.names.joined(separator: ", ")
        menu.addItem(auto)

        let display = NSMenuItem(title: "Keep Display On Too", action: #selector(toggleDisplay), keyEquivalent: "")
        display.target = self
        display.state = keepDisplayOn ? .on : .off
        menu.addItem(display)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Mode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

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
        autoMode.toggle()
        tick()
    }

    @objc private func toggleDisplay() {
        keepDisplayOn.toggle()
        apply()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Agent Mode.app to /Applications and try again."
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
