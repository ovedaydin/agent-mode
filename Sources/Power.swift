import Foundation
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Idle-sleep assertions

final class SleepBlocker {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var currentReason = ""

    var isActive: Bool { systemAssertion != 0 }

    func enable(keepDisplayOn: Bool, reason: String) {
        if reason != currentReason { disable() }  // re-create so `pmset -g assertions` shows the current reason
        currentReason = reason
        if systemAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &systemAssertion)
        }
        if keepDisplayOn, displayAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &displayAssertion)
        } else if !keepDisplayOn, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    func disable() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        currentReason = ""
    }
}

// MARK: - Battery and heat

enum Power {
    struct Battery {
        let percent: Int
        let onBattery: Bool
    }

    static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return Battery(percent: current * 100 / max, onBattery: onBattery)
        }
        return nil
    }

    static var isHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}

// MARK: - Closed-lid mode

/// Keeps the Mac awake with the lid closed via `pmset disablesleep`, which needs root.
/// A one-time admin prompt installs a sudoers rule that allows exactly these two commands.
enum LidMode {
    static let sudoersPath = "/etc/sudoers.d/agentmode"
    private static var applied: Bool?

    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// Turns lid-closed sleep prevention on or off. No-op if unchanged or the helper isn't installed.
    static func set(_ disableSleep: Bool) {
        guard helperInstalled, applied != disableSleep else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disableSleep ? "1" : "0"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            applied = disableSleep
            if Prefs.lidApplied != disableSleep { Prefs.lidApplied = disableSleep }
        }
    }

    /// Undo a `disablesleep 1` left behind if the app crashed or was force-quit.
    static func resetIfNeeded() {
        if Prefs.lidApplied { applied = true; set(false) }
    }

    static func installHelper() throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw error("Your username contains characters Agent Mode can't put in a sudoers rule.")
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentmode-sudoers-\(UUID().uuidString)")
        try rule.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try runAsAdmin("/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' \(sudoersPath)")
    }

    private static func runAsAdmin(_ shell: String) throws {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"Agent Mode needs your password to control sleep with the lid closed.\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let message = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw error(message.contains("-128") ? "Cancelled." : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "AgentMode", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
