import SwiftUI
import WovenMatterClient

/// Settings → Bots → Resources for one machine: the RAM pool, each bot's RAM, and one
/// disk cap. On a Mac they size the VM; on Linux, the engine's slice and disk image.
struct SettingsBotsResourcesView: View {
    @Bindable var bots: BotsModel
    let machineID: String
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var draft: BotResourceSettings?
    @State private var saving = false
    @State private var error: String?

    private var machine: BotMachine? { bots.machines.first { $0.id == machineID } }

    var body: some View {
        SettingsPage(title: "Resources", detail: machine.map { "What bots on \($0.displayName) may use." },
                     reservesRailControlSpace: reservesRailControlSpace, backTitle: "Bots", onBack: onBack) {
            if let machine, let capacity = machine.capacity {
                let settings = draft ?? machine.resources ?? BotResourcePolicy.defaults(for: capacity)
                memoryCard(settings, capacity)
                diskCard(settings, capacity)
                let warnings = BotResourcePolicy.warnings(settings, capacity)
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
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
            } else {
                SettingsEmpty(machine == nil ? "That machine isn't connected." : "Loading this machine's memory and disk…")
            }
        }
        .font(.system(size: 13))
        .task { await bots.refresh() }
    }

    private func memoryCard(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> some View {
        SettingsCard(title: "Memory", detail: "This device has \(BotResourcePolicy.format(capacity.memoryBytes)) of memory. Bots share one pool; each bot is limited on its own too.") {
            VStack(alignment: .leading, spacing: 12) {
                picker("Memory for all bots", selection: settings.poolBytes,
                       choices: BotResourcePolicy.poolChoices(capacity)) { value in
                    var next = settings; next.poolBytes = value
                    // A bot can never have more than the pool.
                    if let pool = value, let perBot = next.perBotBytes, perBot > pool { next.perBotBytes = pool }
                    draft = next
                }
                picker("Memory for each bot", selection: settings.perBotBytes,
                       choices: BotResourcePolicy.perBotChoices(pool: settings.poolBytes, capacity)) { value in
                    var next = settings; next.perBotBytes = value; draft = next
                }
            }
        }
    }

    private func diskCard(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> some View {
        SettingsCard(title: "Disk", detail: "\(BotResourcePolicy.format(capacity.diskFreeBytes)) free of \(BotResourcePolicy.format(capacity.diskTotalBytes)). One cap covers every bot's files. Raising it applies at once; lowering it stops at what bots already use.") {
            picker("Disk for all bots", selection: settings.diskBytes, choices: BotResourcePolicy.diskChoices(capacity)) { value in
                var next = settings; next.diskBytes = value; draft = next
            }
        }
    }

    private func picker(_ title: String, selection: Int64?, choices: [Int64], onChange: @escaping (Int64?) -> Void) -> some View {
        // A stored value outside today's choices (another device set it) still shows.
        let options: [Int64?] = [nil] + (choices.contains(selection ?? -1) || selection == nil ? choices : (choices + [selection!]).sorted())
        return Picker(title, selection: Binding(get: { selection }, set: onChange)) {
            ForEach(options, id: \.self) { value in
                Text(BotResourcePolicy.format(value)).tag(value)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 360, alignment: .leading)
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
