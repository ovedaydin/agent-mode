import Foundation
import Darwin

// MARK: - Process table

struct ProcessEntry {
    let pid: pid_t
    let ppid: pid_t
    let cpu: Double
    let name: String
}

enum ProcessTable {
    static func snapshot() -> [pid_t: ProcessEntry] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Axo", "pid=,ppid=,%cpu=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        var table: [pid_t: ProcessEntry] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                  let cpu = Double(fields[2]) else { continue }
            let comm = fields[3].trimmingCharacters(in: .whitespaces)
            let name = (comm.split(separator: "/").last.map(String.init) ?? comm).lowercased()
            table[pid] = ProcessEntry(pid: pid, ppid: ppid, cpu: cpu, name: name)
        }
        return table
    }

    /// Total bytes received per process so far, from `nettop`.
    static func networkBytesIn() -> [pid_t: Int64] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-P", "-L", "1", "-J", "bytes_in", "-x"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        // Lines look like "claude.5807,205686,"
        var result: [pid_t: Int64] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let bytes = Int64(fields[1]) else { continue }
            result[pid, default: 0] += bytes
        }
        return result
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}

// MARK: - Hook messages

enum HookState: String {
    case busy, idle, waiting
}

struct HookMessage {
    var state: HookState
    var agent: String
    var pid: pid_t
    var cwd: String?
    var detail: String?

    var userInfo: [String: String] {
        var info = ["state": state.rawValue, "agent": agent, "pid": String(pid)]
        info["cwd"] = cwd
        info["detail"] = detail
        return info
    }

    init(state: HookState, agent: String, pid: pid_t, cwd: String?, detail: String?) {
        self.state = state; self.agent = agent; self.pid = pid; self.cwd = cwd; self.detail = detail
    }

    init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo as? [String: String],
              let state = info["state"].flatMap(HookState.init(rawValue:)),
              let agent = info["agent"], let pid = info["pid"].flatMap(pid_t.init) else { return nil }
        self.init(state: state, agent: agent, pid: pid, cwd: info["cwd"], detail: info["detail"])
    }
}

// MARK: - Sessions

final class AgentSession {
    let pid: pid_t
    var agent: String
    var cwd: String?
    /// True once a hook has reported this session busy; from then on hooks are the source of truth.
    var hooked = false
    var hookBusy = false
    var waiting = false
    var waitingDetail: String?
    var lastHeartbeat: Date?
    var lastActive: Date?
    var ignoreActivityUntil: Date?
    var lastBytesIn: Int64?
    var workingSince: Date?

    init(pid: pid_t, agent: String) {
        self.pid = pid
        self.agent = agent
    }

    var project: String? {
        guard let cwd, cwd != "/" else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

enum FinishReason { case finished, waiting }

/// Decides which agent processes are actually working: from hooks when available,
/// otherwise from CPU use and from the model's reply streaming in over the network.
final class AgentTracker {
    static let cpuThreshold = 5.0                 // % CPU of the agent's process tree that counts as working
    static let networkThreshold: Int64 = 2048     // bytes received per check; idle sessions get a few hundred
    static let activityGrace: TimeInterval = 180  // keep counting as working this long after activity stops
    static let heartbeatTimeout: TimeInterval = 1800  // a hooked "busy" with no hook traffic expires after this

    private(set) var sessions: [pid_t: AgentSession] = [:]
    var onTransition: ((AgentSession, TimeInterval, FinishReason) -> Void)?

    var sortedSessions: [AgentSession] { sessions.values.sorted { $0.pid < $1.pid } }

    func reset() { sessions.removeAll() }

    func refresh(processes: [pid_t: ProcessEntry], network: [pid_t: Int64], names: Set<String>, now: Date) {
        var children: [pid_t: [pid_t]] = [:]
        for entry in processes.values { children[entry.ppid, default: []].append(entry.pid) }

        let me = getpid()
        func hasAgentAncestor(_ pid: pid_t) -> Bool {
            var current = processes[pid]?.ppid ?? 0
            for _ in 0..<64 where current > 1 {
                guard let entry = processes[current] else { return false }
                if names.contains(entry.name) { return true }
                current = entry.ppid
            }
            return false
        }

        for entry in processes.values
        where entry.pid != me && names.contains(entry.name) && !hasAgentAncestor(entry.pid) && sessions[entry.pid] == nil {
            let session = AgentSession(pid: entry.pid, agent: entry.name)
            session.cwd = ProcessTable.workingDirectory(of: entry.pid)
            sessions[entry.pid] = session
        }

        for (pid, session) in sessions {
            guard let entry = processes[pid] else {
                sessions[pid] = nil   // process exited
                continue
            }
            if !session.hooked && !names.contains(entry.name) {
                sessions[pid] = nil   // no longer on the agent list
                continue
            }
            var cpu = 0.0
            var stack = [pid]
            while let next = stack.popLast() {
                cpu += processes[next]?.cpu ?? 0
                stack.append(contentsOf: children[next] ?? [])
            }
            var received: Int64 = 0
            if let bytes = network[pid] {
                if let previous = session.lastBytesIn { received = max(0, bytes - previous) }
                session.lastBytesIn = bytes
            }
            let active = cpu >= Self.cpuThreshold || received >= Self.networkThreshold
            if active, session.ignoreActivityUntil.map({ now >= $0 }) ?? true {
                session.lastActive = now
            }
        }
    }

    func handle(_ message: HookMessage, now: Date) {
        let session = sessions[message.pid] ?? AgentSession(pid: message.pid, agent: message.agent)
        sessions[message.pid] = session
        session.agent = message.agent
        if let cwd = message.cwd { session.cwd = cwd }

        switch message.state {
        case .busy:
            session.hooked = true
            session.hookBusy = true
            session.waiting = false
            session.lastHeartbeat = now
        case .idle, .waiting:
            session.hookBusy = false
            session.waiting = message.state == .waiting
            session.waitingDetail = message.detail
            // CPU use decays slowly in `ps`, so don't let it re-mark the session as working right away.
            session.lastActive = nil
            session.ignoreActivityUntil = now.addingTimeInterval(30)
        }
    }

    func isWorking(_ s: AgentSession, now: Date) -> Bool {
        let recentlyActive = s.lastActive.map { now.timeIntervalSince($0) < Self.activityGrace } ?? false
        if s.hooked {
            let heartbeatFresh = s.lastHeartbeat.map { now.timeIntervalSince($0) < Self.heartbeatTimeout } ?? false
            return s.hookBusy && (heartbeatFresh || recentlyActive)
        }
        return recentlyActive
    }

    /// Updates each session's working state and reports sessions that just stopped working.
    func evaluate(now: Date) {
        for session in sortedSessions {
            let working = isWorking(session, now: now)
            if working, session.workingSince == nil {
                session.workingSince = now
                session.waiting = false
            } else if !working, let since = session.workingSince {
                session.workingSince = nil
                let end = session.hooked ? now : (session.lastActive ?? now)
                onTransition?(session, max(0, end.timeIntervalSince(since)), session.waiting ? .waiting : .finished)
            }
        }
    }

    var working: [AgentSession] { sortedSessions.filter { $0.workingSince != nil } }
}
