import Foundation
import Darwin

enum CLI {
    static let commands: Set<String> = ["hook", "install-claude-hooks", "uninstall-claude-hooks", "help", "--help"]

    static let usage = """
    Usage: AgentMode <command>

      claude [options…] / codex [options…]
          Run the agent so the Agent Mode phone app can follow and drive it (needs Agent Mode Pro).

      hook [busy|idle|waiting] [--agent NAME]
          Tell the running app an agent's state. Reads Claude Code hook JSON from
          stdin or a Codex notify payload as the last argument when no state is given.
      install-claude-hooks [SETTINGS_PATH]
          Add Agent Mode hooks to ~/.claude/settings.json (or SETTINGS_PATH).
      uninstall-claude-hooks [SETTINGS_PATH]
          Remove them again.
    """

    static func run(_ args: [String]) -> Int32 {
        let rest = Array(args.dropFirst())
        switch args.first {
        case "hook":
            sendHook(rest)
            return 0  // never fail the agent's hook
        case "install-claude-hooks", "uninstall-claude-hooks":
            let url = rest.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? ClaudeHooks.settingsURL
            do {
                if args.first == "install-claude-hooks" {
                    try ClaudeHooks.install(at: url)
                    print("Installed Agent Mode hooks in \(url.path)")
                } else {
                    try ClaudeHooks.uninstall(at: url)
                    print("Removed Agent Mode hooks from \(url.path)")
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        default:
            print(usage)
            return 0
        }
    }

    // MARK: Hook

    private static func sendHook(_ args: [String]) {
        var explicitState: HookState?
        var agent: String?
        var payload: [String: Any] = [:]

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--agent", i + 1 < args.count {
                agent = args[i + 1]
                i += 1
            } else if let state = HookState(rawValue: arg) {
                explicitState = state
            } else if arg.hasPrefix("{") {
                payload = parseJSON(Data(arg.utf8))  // Codex passes its notify payload as an argument
            }
            i += 1
        }
        if payload.isEmpty, explicitState == nil, isatty(STDIN_FILENO) == 0 {
            payload = parseJSON(readStdin(timeout: 2))
        }

        let event = payload["hook_event_name"] as? String
        let codexType = payload["type"] as? String
        var detail: String?
        let state: HookState
        if let explicitState {
            state = explicitState
        } else if let event {
            switch event {
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop", "PreCompact": state = .busy
            case "Stop", "SessionEnd": state = .idle
            case "Notification":
                state = .waiting
                detail = payload["message"] as? String
            default: return
            }
        } else if codexType == "agent-turn-complete" {
            state = .idle
        } else {
            return
        }

        let names = Set(Prefs.agentNames.map { $0.lowercased() })
        let (pid, ancestorName) = agentAncestor(names: names)
        let resolvedAgent = agent ?? (event != nil ? "claude" : codexType != nil ? "codex" : ancestorName)

        let message = HookMessage(state: state, agent: resolvedAgent, pid: pid,
                                  cwd: payload["cwd"] as? String, detail: detail)
        DistributedNotificationCenter.default().postNotificationName(
            Prefs.hookNotification, object: nil, userInfo: message.userInfo, deliverImmediately: true)
    }

    private static func parseJSON(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func readStdin(timeout: TimeInterval) -> Data {
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = FileHandle.standardInput.readDataToEndOfFile()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? data : Data()
    }

    /// Walks up the process tree to find the agent that ran this hook.
    /// Falls back to the first ancestor that isn't a shell.
    private static func agentAncestor(names: Set<String>) -> (pid_t, String) {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]
        var fallback: (pid_t, String)?
        var pid = getppid()
        for _ in 0..<32 where pid > 1 {
            guard let (ppid, name) = processInfo(pid) else { break }
            let lower = name.lowercased()
            if names.contains(lower) { return (pid, lower) }
            if fallback == nil, !shells.contains(lower) { fallback = (pid, lower) }
            pid = ppid
        }
        return fallback ?? (getppid(), "agent")
    }

    private static func processInfo(_ pid: pid_t) -> (pid_t, String)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return (info.kp_eproc.e_ppid, name)
    }
}

// MARK: - Claude Code hook installer

enum ClaudeHooks {
    static let events = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    private static let marker = "/Contents/MacOS/AgentMode"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var executablePath: String { Bundle.main.executablePath ?? "/Applications/Agent Mode.app\(marker)" }

    static var command: String {
        "'" + executablePath.replacingOccurrences(of: "'", with: "'\\''") + "' hook"
    }

    static var codexConfigLine: String {
        "notify = [\"\(executablePath)\", \"hook\", \"--agent\", \"codex\"]"
    }

    static func isInstalled(at url: URL = settingsURL) -> Bool {
        guard let hooks = (try? load(url))?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]])?.contains { isOurs($0) } ?? false
        }
    }

    static func install(at url: URL = settingsURL) throws {
        let url = url.resolvingSymlinksInPath()  // keep dotfile symlinks intact
        var settings = try load(url)
        var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        for event in events {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if event == "PostToolUse" { group["matcher"] = "*" }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        try save(settings, to: url)
    }

    static func uninstall(at url: URL = settingsURL) throws {
        let url = url.resolvingSymlinksInPath()
        var settings = try load(url)
        let hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try save(settings, to: url)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains(marker) ?? false } ?? false
    }

    private static func removingOurs(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let filtered = entries.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if filtered.isEmpty { return nil }
                var copy = group
                copy["hooks"] = filtered
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AgentMode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(url.path) isn't a JSON object"])
        }
        return object
    }

    private static func save(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("agentmode-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
