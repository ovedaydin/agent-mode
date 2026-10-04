import Foundation

enum Prefs {
    static let hookNotification = Notification.Name("io.github.ovedaydin.agentmode.hook")
    static let defaultAgentNames = ["claude", "codex", "aider", "gemini", "cursor-agent", "opencode", "amp", "goose"]

    enum Key {
        static let autoMode = "autoMode"
        static let keepDisplayOn = "keepDisplayOn"
        static let agentNames = "agentProcessNames"
        static let batteryLimit = "batteryLimit"
        static let notifyOnFinish = "notifyOnFinish"
        static let notifyMinMinutes = "notifyMinMinutes"
        static let lidMode = "lidMode"
        static let lidApplied = "lidApplied"
        static let checkForUpdates = "checkForUpdates"
    }

    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            Key.autoMode: true,
            Key.keepDisplayOn: false,
            Key.batteryLimit: 20,
            Key.notifyOnFinish: true,
            Key.notifyMinMinutes: 2,
            Key.lidMode: false,
            Key.checkForUpdates: true,
        ])
    }

    static var autoMode: Bool {
        get { d.bool(forKey: Key.autoMode) }
        set { d.set(newValue, forKey: Key.autoMode) }
    }
    static var keepDisplayOn: Bool {
        get { d.bool(forKey: Key.keepDisplayOn) }
        set { d.set(newValue, forKey: Key.keepDisplayOn) }
    }
    static var agentNames: [String] {
        get { d.stringArray(forKey: Key.agentNames) ?? defaultAgentNames }
        set { d.set(newValue, forKey: Key.agentNames) }
    }
    /// Battery percentage at or below which Agent Mode stops keeping the Mac awake. 0 = never.
    static var batteryLimit: Int { d.integer(forKey: Key.batteryLimit) }
    static var notifyOnFinish: Bool { d.bool(forKey: Key.notifyOnFinish) }
    static var notifyMinMinutes: Int { d.integer(forKey: Key.notifyMinMinutes) }
    static var lidMode: Bool {
        get { d.bool(forKey: Key.lidMode) }
        set { d.set(newValue, forKey: Key.lidMode) }
    }
    /// Whether we last left `pmset disablesleep` on, so it can be undone after a crash.
    static var lidApplied: Bool {
        get { d.bool(forKey: Key.lidApplied) }
        set { d.set(newValue, forKey: Key.lidApplied) }
    }
    static var checkForUpdates: Bool { d.bool(forKey: Key.checkForUpdates) }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
