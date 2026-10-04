import AppKit

Prefs.registerDefaults()

// The same binary doubles as a small CLI (used by agent hooks).
if let command = CommandLine.arguments.dropFirst().first, CLI.commands.contains(command) {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}

// Only one menu bar instance at a time.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
