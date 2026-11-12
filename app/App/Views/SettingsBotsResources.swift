import SwiftUI
import WovenMatterClient

/// Settings → Bots → a machine → Resources: the memory pool, each bot's memory, and one
/// disk cap. On a Mac they size the VM; on Linux, the engine's slice and disk image.
struct SettingsBotsResourcesView: View {
    @Bindable var bots: BotsModel
    let machineID: String
    var reservesRailControlSpace = false
    var backTitle = "Bots"
    let onBack: () -> Void
    @State private var draft: BotResourceSettings?
    @State private var saving = false
    @State private var error: String?

    private var machine: BotMachine? { bots.machines.first { $0.id == machineID } }

    var body: some View {
        SettingsPage(title: "Resources", detail: machine.map { "What bots on \($0.kind == .thisMac ? "this Mac" : $0.displayName) may use." },
                     reservesRailControlSpace: reservesRailControlSpace, backTitle: backTitle, onBack: onBack) {
            if let machine, let capacity = machine.capacity {
                let settings = draft ?? machine.resources ?? BotResourcePolicy.defaults(for: capacity)
                memorySection(settings, capacity)
                diskSection(settings, capacity)
                SettingsSection {
                    ForEach(Array(BotResourcePolicy.warnings(settings, capacity).enumerated()), id: \.offset) { _, warning in
                        SettingsNote(BotResourcePolicy.text(warning))
                    }
                    HStack(spacing: 8) {
                        Button(saving ? "Applying…" : "Apply") { apply(settings, capacity) }
                            .buttonStyle(DashboardPrimaryButtonStyle())
                            .disabled(saving || draft == nil)
                        Button("Restore defaults") { draft = BotResourcePolicy.defaults(for: capacity) }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }
                    if let error { SettingsError(error) }
                }
            } else {
                SettingsEmpty(machine == nil ? "That machine isn't connected." : "Loading this machine's memory and disk…")
            }
        }
        .task { await bots.refresh() }
    }

    private func memorySection(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> some View {
        SettingsSection(title: "Memory", detail: "This device has \(BotResourcePolicy.format(capacity.memoryBytes)). Bots share one pool, and each bot has its own limit.") {
            SettingsRow(title: "All bots") {
                picker("Memory for all bots", selection: settings.poolBytes, choices: BotResourcePolicy.poolChoices(capacity)) { value in
                    var next = settings; next.poolBytes = value
                    // A bot can never have more than the pool.
                    if let pool = value, let perBot = next.perBotBytes, perBot > pool { next.perBotBytes = pool }
                    draft = next
                }
            }
            SettingsRow(title: "Each bot") {
                picker("Memory for each bot", selection: settings.perBotBytes,
                       choices: BotResourcePolicy.perBotChoices(pool: settings.poolBytes, capacity)) { value in
                    var next = settings; next.perBotBytes = value; draft = next
                }
            }
        }
    }

    private func diskSection(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> some View {
        SettingsSection(title: "Disk", detail: "\(BotResourcePolicy.format(capacity.diskFreeBytes)) free of \(BotResourcePolicy.format(capacity.diskTotalBytes)). One cap covers every bot's files.") {
            SettingsRow(title: "All bots") {
                picker("Disk for all bots", selection: settings.diskBytes, choices: BotResourcePolicy.diskChoices(capacity)) { value in
                    var next = settings; next.diskBytes = value; draft = next
                }
            }
            SettingsHelp {
                SettingsNote("Raising the cap applies at once. Lowering it stops at what bots already use.")
            }
        }
    }

    private func picker(_ title: String, selection: Int64?, choices: [Int64], onChange: @escaping @MainActor (Int64?) -> Void) -> some View {
        // A stored value outside today's choices (another device set it) still shows.
        let options: [Int64?] = [nil] + (choices.contains(selection ?? -1) || selection == nil ? choices : (choices + [selection!]).sorted())
        return SettingsPicker(title, selection: Binding(get: { selection }, set: { onChange($0) }), options: options) {
            BotResourcePolicy.format($0)
        }
    }

    private func apply(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await bots.send(.setResources(machineID: machineID, BotResourcePolicy.validated(settings, capacity)))
                draft = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
