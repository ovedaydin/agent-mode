import AppKit

/// "Set Up Phone App…": downloads the self-contained Agent Mode Pro bridge, unpacks it into Application Support,
/// and hands it to BridgeManager. No Terminal, Node or npm needed; it uses the Mac's own Claude Code.
enum ProSetup {
    static var installDir: String { NSHomeDirectory() + "/Library/Application Support/Agent Mode/Pro" }

    static var bundleURL: URL {
        if let custom = UserDefaults.standard.string(forKey: "proBundleURL"), let url = URL(string: custom) { return url }
        let arch = ProcessInfo.processInfo.machineHardwareName == "x86_64" ? "x64" : "arm64"
        return URL(string: "https://github.com/ovedaydin/agent-mode/releases/latest/download/agentmode-pro-darwin-\(arch).tar.gz")!
    }

    static func run(bridge: BridgeManager, then done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Set up the phone app?"
        alert.informativeText = """
        Agent Mode will download its phone link (about 40 MB) and run it on this Mac, so the Agent Mode phone app can show and control your agents.

        It uses the Claude Code already installed on this Mac. Your phone and Mac need to be on the same Wi-Fi for now.
        """
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        fetch(bundleURL) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    let failed = NSAlert()
                    failed.messageText = "Couldn't set up the phone app"
                    failed.informativeText = error.localizedDescription
                    failed.runModal()
                case .success(let archive):
                    do {
                        let dir = try unpack(archive)
                        bridge.install(bundleDir: dir)
                        done()
                    } catch {
                        let failed = NSAlert()
                        failed.messageText = "Couldn't set up the phone app"
                        failed.informativeText = error.localizedDescription
                        failed.runModal()
                    }
                }
            }
        }
    }

    private static func fetch(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        if url.isFileURL { return completion(.success(url)) }
        URLSession.shared.downloadTask(with: url) { file, response, error in
            if let error { return completion(.failure(error)) }
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return completion(.failure(NSError(domain: "AgentMode", code: 3, userInfo: [NSLocalizedDescriptionKey: "The download isn't available right now."])))
            }
            // The temporary file is deleted when this handler returns, so keep a copy.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("agentmode-pro-\(UUID().uuidString).tar.gz")
            do { try FileManager.default.moveItem(at: file, to: kept); completion(.success(kept)) } catch { completion(.failure(error)) }
        }.resume()
    }

    /// Unpacks into a fresh folder, then swaps it in, so a failed setup never leaves a half-installed bridge.
    static func unpack(_ archive: URL) throws -> String {
        let fm = FileManager.default
        let parent = (installDir as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let staging = parent + "/Pro.new"
        try? fm.removeItem(atPath: staging)
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", staging]
        try tar.run()
        tar.waitUntilExit()
        let unpacked = staging + "/agentmode-pro"
        guard tar.terminationStatus == 0, fm.isExecutableFile(atPath: unpacked + "/runtime/bin/node") else {
            throw NSError(domain: "AgentMode", code: 4, userInfo: [NSLocalizedDescriptionKey: "The download looks damaged. Try again."])
        }
        try? fm.removeItem(atPath: installDir)
        try fm.moveItem(atPath: unpacked, toPath: installDir)
        try? fm.removeItem(atPath: staging)
        return installDir
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }
}
