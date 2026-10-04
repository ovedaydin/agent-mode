import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    /// Called when the lid-mode toggle changes; returns the state that actually took effect.
    let setLidMode: (Bool) -> Bool

    @AppStorage(Prefs.Key.autoMode) private var autoMode = true
    @AppStorage(Prefs.Key.keepDisplayOn) private var keepDisplayOn = false
    @AppStorage(Prefs.Key.batteryLimit) private var batteryLimit = 20
    @AppStorage(Prefs.Key.notifyOnFinish) private var notifyOnFinish = true
    @AppStorage(Prefs.Key.notifyMinMinutes) private var notifyMinMinutes = 2
    @AppStorage(Prefs.Key.lidMode) private var lidMode = false
    @AppStorage(Prefs.Key.checkForUpdates) private var checkForUpdates = true
    @AppStorage(Prefs.Key.showTimer) private var showTimer = true

    @State private var agentText = Prefs.agentNames.joined(separator: ", ")
    @State private var claudeHooksInstalled = ClaudeHooks.isInstalled()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var codexCopied = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Agents") {
                Toggle("Stay awake while agents are working", isOn: $autoMode)
                TextField("Agent programs", text: $agentText)
                    .onSubmit(saveAgents)
                caption("Comma-separated process names. Without hooks, an agent counts as working while it's using CPU or receiving a reply from its model.")
            }

            Section("Agent hooks") {
                LabeledContent("Claude Code") {
                    Button(claudeHooksInstalled ? "Remove Hooks" : "Install Hooks", action: toggleClaudeHooks)
                }
                caption("Hooks tell Agent Mode exactly when Claude Code starts and stops working. They're added to ~/.claude/settings.json, and a backup is saved next to it.")
                LabeledContent("Codex") {
                    Button(codexCopied ? "Copied" : "Copy Config Line") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ClaudeHooks.codexConfigLine, forType: .string)
                        codexCopied = true
                    }
                }
                caption("Paste it into ~/.codex/config.toml. Codex allows only one notify program, so it replaces any notify line you already have.")
            }

            Section("Notifications") {
                Toggle("Notify when an agent finishes or needs you", isOn: $notifyOnFinish)
                Stepper("Only for tasks longer than \(notifyMinMinutes) min", value: $notifyMinMinutes, in: 0...120)
                    .disabled(!notifyOnFinish)
            }

            Section("Power") {
                Toggle("Keep display on too", isOn: $keepDisplayOn)
                Picker("Let the Mac sleep when battery is at", selection: $batteryLimit) {
                    Text("Never").tag(0)
                    ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                Toggle("Stay awake with the lid closed", isOn: Binding(
                    get: { lidMode },
                    set: { lidMode = setLidMode($0) }))
                caption("Needs your admin password once. Turns off when agents finish, the battery hits the limit above, or the Mac gets hot. Don't put a running Mac in a bag.")
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("Show working time in the menu bar", isOn: $showTimer)
                Toggle("Check for updates", isOn: $checkForUpdates)
                LabeledContent("Version", value: Prefs.version)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
        .onDisappear(perform: saveAgents)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func saveAgents() {
        let names = agentText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        Prefs.agentNames = names.isEmpty ? Prefs.defaultAgentNames : names
        agentText = Prefs.agentNames.joined(separator: ", ")
    }

    private func toggleClaudeHooks() {
        do {
            if claudeHooksInstalled { try ClaudeHooks.uninstall() } else { try ClaudeHooks.install() }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't update Claude Code settings: \(error.localizedDescription)"
        }
        claudeHooksInstalled = ClaudeHooks.isInstalled()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change Launch at Login: \(error.localizedDescription). Move Agent Mode to /Applications and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
