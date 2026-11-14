import SwiftUI
import WovenMatterClient

struct BotSettingsBots: View {
    let state: BotSettingsState
    @State private var live: [PiBotSummary]?
    @State private var profiles: [PiBotProfile]?
    @State private var deleted: [PiBotDeletedBot]?
    @State private var restoring: String?
    @State private var purging: String?
    @State private var refreshes = 0
    @State private var environments: [String: PiBotEnvironment] = [:]

    var body: some View {
        Group {
            if let live, let profiles {
                botsSection(live, profiles: profiles)
                BotSettingsMemory(state: state, bots: live)
                containersSection(live)
                if let deleted, !deleted.isEmpty { deletedSection(deleted) }
            } else { SettingsEmpty("Loading…") }
        }
        .task(id: "\(state.bots.connection.rawValue):\(state.bots.settingsRevision)") {
            guard state.bots.isConnected else { return }
            await state.load { try await refresh($0) }
        }
    }

    private func refresh(_ client: PiBotClient) async throws {
        refreshes += 1
        let current = refreshes
        async let active = client.bots()
        async let listed = client.profiles()
        async let removed = client.deletedBots()
        let result = try await (active, listed, removed)
        // An older read that finishes late must not undo a newer change.
        guard current == refreshes else { return }
        live = result.0; profiles = result.1.profiles; deleted = result.2
        await state.bots.refreshOnboarding(onError: { state.error = $0 })
    }

    private func act(_ work: @escaping @MainActor (PiBotClient) async throws -> Void) {
        Task {
            await state.run { client in
                try await work(client)
                try await refresh(client)
                await state.bots.reload()
            }
        }
    }

    private func botsSection(_ live: [PiBotSummary], profiles: [PiBotProfile]) -> some View {
        let layout = PiBotTeamLayout(live)
        return SettingsSection(title: "Bots", detail: "Each bot's name, profile, and team. Teams are optional.") {
            SettingsRow(title: "Orchestrator", detail: "Optional. Oversees every bot and team; Admin Bot stays apart.") {
                BotSettingsReferencePicker(selection: live.first(where: \.orchestrator)?.id ?? "",
                    options: [.init("", "None")] + live.filter { !$0.isAdmin }.map { .init($0.id, $0.name) },
                    label: "Orchestrator") { id in act { try await $0.setOrchestrator(botID: id.isEmpty ? nil : id) } }
            }
            ForEach(layout.rows) { row in
                botRow(row.bot, all: live, profiles: profiles).padding(.leading, row.isMember ? 16 : 0)
            }
            if let admin = layout.admin { botRow(admin, all: live, profiles: profiles) }
            SettingsHelp {
                SettingsNote("Teams are one level deep: a manager hands work to the bots on its team. An orchestrator sits above every team.")
                SettingsNote("Admin Bot's name is fixed. Rename any other bot here, or by asking it or Admin Bot.")
            }
        }
    }

    private func botRow(_ bot: PiBotSummary, all: [PiBotSummary], profiles: [PiBotProfile]) -> some View {
        SettingsSummaryRow(bot.name, value: botSummary(bot, all: all, profiles: profiles)) {
            name(bot, all: all)
            SettingsRow(title: "Profile") { profilePicker(bot, profiles: profiles) }
            if bot.isAdmin {
                SettingsRow(title: "Team") {
                    Text("Never on a team").font(.settingsBody).foregroundStyle(WovenPalette.mutedForeground)
                }
            } else {
                SettingsRow(title: "Team") { teamPicker(bot, all: all) }
                handoffPicker(bot, all: all)
            }
        }
    }

    private func botSummary(_ bot: PiBotSummary, all: [PiBotSummary], profiles: [PiBotProfile]) -> String {
        let profile = bot.defaultProfile == true ? "Default profile"
            : profiles.first { $0.id == bot.profileId }?.name ?? "Default profile"
        var parts = [bot.role, profile]
        if bot.orchestrator { parts.append("Orchestrator") }
        else if bot.manager { parts.append("Manager") }
        else if let manager = all.first(where: { $0.id == bot.managerId }) { parts.append("On \(manager.name)'s team") }
        return parts.joined(separator: " · ")
    }

    private func name(_ bot: PiBotSummary, all: [PiBotSummary]) -> some View {
        BotSettingsBotName(bot: bot, members: all.filter { $0.managerId == bot.id }) { name in
            act { try await $0.renameBot(id: bot.id, name: name) }
        }
    }

    @ViewBuilder private func handoffPicker(_ bot: PiBotSummary, all: [PiBotSummary]) -> some View {
        let members = all.filter { $0.managerId == bot.id }
        if !bot.isAdmin, bot.manager, !members.isEmpty {
            SettingsRow(title: "Hand team to") {
                BotSettingsReferencePicker(selection: "", options: [.init("", "Choose a member…")] + members.map { .init($0.id, $0.name) },
                    label: "Hand \(bot.name)'s team to") { id in
                    if !id.isEmpty { act { try await $0.replaceManager(managerID: bot.id, newManagerID: id) } }
                }
            }
        }
    }

    private func profilePicker(_ bot: PiBotSummary, profiles: [PiBotProfile]) -> some View {
        BotSettingsReferencePicker(selection: bot.defaultProfile == true ? "" : bot.profileId ?? "",
            options: [.init("", "Default (\(profiles.first(where: \.isDefault)?.name ?? "none"))")]
                + profiles.map { .init($0.id, $0.name) }, label: "Profile for \(bot.name)") { id in
            act { try await $0.setProfile(botID: bot.id, profileID: id.isEmpty ? nil : id) }
        }
    }

    private func teamPicker(_ bot: PiBotSummary, all: [PiBotSummary]) -> some View {
        BotSettingsReferencePicker(selection: bot.placement,
            options: [.init("none", "No team"), .init("manager", "Manager")]
                + all.filter { !$0.isAdmin && $0.manager && $0.id != bot.id && !bot.orchestrator }
                    .map { .init($0.id, "On \($0.name)'s team") }, label: "Team for \(bot.name)") { place(bot, placement: $0) }
    }

    private func place(_ bot: PiBotSummary, placement: String) {
        let work: @MainActor () -> Void = {
            act { client in
                if placement == "manager" { try await client.setManager(botID: bot.id, manager: true); return }
                if bot.manager { try await client.setManager(botID: bot.id, manager: false) }
                if placement != "none" { try await client.setTeam(botID: bot.id, managerID: placement) }
                else if bot.managerId != nil { try await client.setTeam(botID: bot.id, managerID: nil) }
            }
        }
        if placement != "manager", bot.manager, live?.contains(where: { $0.managerId == bot.id }) == true {
            state.confirm("\(bot.name)'s team will be ungrouped. Continue?", action: "Continue", destructive: false, work: work)
        } else { work() }
    }

    /// Each bot's container: its state and previews, Stop, and Rebuild, which recreates it
    /// from a clean image and keeps its storage.
    private func containersSection(_ live: [PiBotSummary]) -> some View {
        SettingsSection(title: "Containers", detail: "A stopped bot starts again on its next tool call.") {
            ForEach(live.filter { !$0.isAdmin }) { bot in
                SettingsRow(title: bot.name, detail: environments[bot.id]?.stateText) {
                    if environments[bot.id]?.state == "running" {
                        Button { act { try await $0.stopBot(id: bot.id) } } label: { BotSettingsActionLabel(title: "Stop", glyph: .close) }
                            .accessibilityLabel("Stop \(bot.name)")
                    }
                    Button { rebuild(bot) } label: { BotSettingsActionLabel(title: "Rebuild", glyph: .rotate) }
                        .accessibilityLabel("Rebuild \(bot.name)")
                }
                ForEach(environments[bot.id]?.previews ?? [], id: \.port) { preview in
                    SettingsRow(title: "Port \(preview.port)", detail: preview.url) {
                        Button("Stop sharing") { act { try await $0.stopPreview(botID: bot.id, port: preview.port) } }
                    }
                    .padding(.leading, 16)
                }
            }
            SettingsHelp {
                SettingsNote("Rebuild recreates a bot's container from a clean image. Its files, restart list, browser profile, memory, and conversations stay.")
            }
        }
        .task(id: "\(state.bots.connection.rawValue):\(state.bots.environmentRevision):\(refreshes)") {
            guard state.bots.isConnected else { return }
            for bot in live where !bot.isAdmin {
                await state.load { environments[bot.id] = try await $0.environment(botID: bot.id) }
            }
        }
    }

    private func rebuild(_ bot: PiBotSummary) {
        state.confirm("Rebuild \(bot.name) from a clean image?\n\nRunning work stops. Its storage stays.", action: "Rebuild", destructive: false) {
            act { client in try await client.rebuildBot(id: bot.id) }
        }
    }

    private func deletedSection(_ deleted: [PiBotDeletedBot]) -> some View {
        SettingsSection(title: "Deleted bots", detail: "Deleted bots keep their conversations and threads until you delete them permanently.") {
            ForEach(deleted) { bot in
                SettingsRow(title: bot.name, detail: "Deleted \(deletedDate(bot.deletedAt))") {
                    Button { purge(bot) } label: {
                        BotSettingsActionLabel(title: purging == bot.id ? "Deleting…" : "Delete permanently", glyph: .trash)
                    }.accessibilityLabel("Delete \(bot.name) permanently")
                    Button { restore(bot) } label: {
                        BotSettingsActionLabel(title: restoring == bot.id ? "Restoring…" : "Restore", glyph: .rotate)
                    }.accessibilityLabel("Restore \(bot.name)")
                }
            }
        }
    }

    private func deletedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }

    private func restore(_ bot: PiBotDeletedBot) {
        restoring = bot.id
        Task {
            defer { restoring = nil }
            await state.run { client in
                _ = try await client.restoreBot(id: bot.id)
                try await refresh(client)
                await state.bots.reload()
            }
        }
    }

    private func purge(_ bot: PiBotDeletedBot) {
        state.confirm("Delete \(bot.name) permanently?\n\nThis removes its conversations, threads, memory and notes, its settings, and its workspace and container.\n\nThis can't be undone.", action: "Delete permanently") {
            purging = bot.id
            Task {
                defer { purging = nil }
                await state.run { client in
                    let result = try await client.purgeBot(id: bot.id)
                    if let environment = result.environment, !environment.removed {
                        state.error = "\(bot.name) was deleted permanently, but its workspace was not removed: \(environment.error ?? "unknown error")"
                    }
                    try await refresh(client)
                }
            }
        }
    }
}

private struct BotSettingsBotName: View {
    let bot: PiBotSummary
    let members: [PiBotSummary]
    let onRename: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    private var note: String? {
        if bot.isAdmin { return "Settings and other bots" }
        if bot.orchestrator && !(bot.manager && !members.isEmpty) { return "Oversees every bot and team" }
        if bot.manager { return members.isEmpty ? "No members yet" : "Team: " + members.map(\.name).joined(separator: ", ") }
        return nil
    }

    var body: some View {
        if let draft, !bot.isAdmin {
            SettingsRow(title: "Name") {
                TextField("", text: Binding(get: { self.draft ?? "" }, set: { self.draft = String($0.prefix(80)) }))
                    .wovenInput().frame(width: 220).accessibilityLabel("New name for \(bot.name)")
                    .focused($focused).onSubmit { save() }.onExitCommand { self.draft = nil }
                Button("Save") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { self.draft = nil }
            }
            .task {
                // The field has to be in the window before it can take focus.
                await Task.yield()
                focused = true
            }
        } else {
            SettingsRow(title: "Name", detail: note) {
                if bot.isAdmin {
                    Text(bot.name).font(.settingsBody).foregroundStyle(WovenPalette.mutedForeground)
                } else {
                    Button("Rename") { draft = bot.name }
                        .accessibilityLabel("Rename \(bot.name)")
                }
            }
        }
    }

    private func save() {
        let name = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if name != bot.name { onRename(name) }
        draft = nil
    }
}
