import AppKit

Prefs.registerDefaults()

// `agentmode claude …` / `agentmode codex …`: run the agent through Agent Mode Pro's terminal wrapper,
// so the phone app can follow and drive it. The Pro bridge installs the wrapper at ~/.agentmode-pro/wrap.
if let agent = CommandLine.arguments.dropFirst().first, ["claude", "codex"].contains(agent) {
    let wrapper = NSHomeDirectory() + "/.agentmode-pro/wrap"
    guard FileManager.default.isExecutableFile(atPath: wrapper) else {
        FileHandle.standardError.write(Data("""
        Agent Mode Pro isn't set up on this Mac, so `agentmode \(agent)` can't connect to your phone.
        Start the Agent Mode Pro bridge once, or run `\(agent)` directly.\n
        """.utf8))
        exit(1)
    }
    let args = [wrapper] + CommandLine.arguments.dropFirst()
    let cArgs = args.map { strdup($0) } + [nil]
    execv(wrapper, cArgs)
    perror("agentmode: couldn't start the wrapper")
    exit(1)
}

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
