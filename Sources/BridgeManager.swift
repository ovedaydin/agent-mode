import Foundation

/// Keeps Agent Mode Pro's bridge running while the menu bar app runs, so the phone can always reach
/// this Mac. Starts it at launch, restarts it if it stops, and logs to ~/.agentmode-pro/bridge.log.
final class BridgeManager {
    private static let configDir = NSHomeDirectory() + "/.agentmode-pro"
    private static let launchInfo = configDir + "/bridge.json"
    private static let logPath = configDir + "/bridge.log"
    private static let health = URL(string: "http://127.0.0.1:8787/")!

    private var process: Process?
    private var timer: Timer?
    private var restartDelay: TimeInterval = 2
    private(set) var isRunning = false
    var onChange: (() -> Void)?

    /// Agent Mode Pro is set up when its bridge has run once and recorded how to start it.
    static var available: Bool { FileManager.default.fileExists(atPath: launchInfo) }

    func start() {
        guard Self.available else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        process?.terminate()
        process = nil
    }

    /// If nothing answers on the bridge port, start one (unless ours is already starting).
    private func check() {
        var request = URLRequest(url: Self.health, timeoutInterval: 3)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let up = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self else { return }
                if up != self.isRunning { self.isRunning = up; self.onChange?() }
                if !up && self.process == nil { self.launch() }
            }
        }.resume()
    }

    /// How to start the bridge, from bridge.json: {node, args, dir}. Older bridges wrote {node, tsx, server, dir}.
    private static func launchCommand() -> (node: String, args: [String], dir: String)? {
        guard let data = FileManager.default.contents(atPath: launchInfo),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let node = info["node"] as? String, let dir = info["dir"] as? String,
              FileManager.default.isExecutableFile(atPath: node) else { return nil }
        if let args = info["args"] as? [String] { return (node, args, dir) }
        if let tsx = info["tsx"] as? String, let server = info["server"] as? String { return (node, [tsx, server], dir) }
        return nil
    }

    /// Points the app at an unpacked Pro bundle and starts it (used by Set Up Phone App).
    func install(bundleDir: String) {
        let info: [String: Any] = [
            "node": bundleDir + "/runtime/bin/node",
            "args": [bundleDir + "/dist/server.js"],
            "dir": bundleDir + "/",
        ]
        try? FileManager.default.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            FileManager.default.createFile(atPath: Self.launchInfo, contents: data)
        }
        process?.terminate()
        process = nil
        restartDelay = 2
        if timer == nil { start() } else { check() }
    }

    private func launch() {
        guard let (node, args, dir) = Self.launchCommand() else { return }

        if !FileManager.default.fileExists(atPath: Self.logPath) {
            FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        }
        let log = FileHandle(forWritingAtPath: Self.logPath)
        log?.seekToEndOfFile()
        log?.write(Data("\n--- \(Date()) starting bridge\n".utf8))

        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (node as NSString).deletingLastPathComponent + ":/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        task.environment = env
        task.standardOutput = log
        task.standardError = log
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.isRunning = false
                self.onChange?()
                // Restart with backoff, unless the app is quitting (stop() clears the timer).
                guard self.timer != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.restartDelay) { self.check() }
                self.restartDelay = min(self.restartDelay * 2, 60)
            }
        }
        do {
            try task.run()
            process = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.process === task { self?.restartDelay = 2 }  // stayed up: reset backoff
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.check() }
        } catch {
            log?.write(Data("couldn't start bridge: \(error)\n".utf8))
        }
    }
}
