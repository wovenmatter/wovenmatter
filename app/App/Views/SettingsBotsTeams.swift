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
                botsCard(live, profiles: profiles)
                BotSettingsMemory(state: state, bots: live)
                rebuildCard(live)
                if let deleted, !deleted.isEmpty { deletedCard(deleted) }
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

    private func botsCard(_ live: [PiBotSummary], profiles: [PiBotProfile]) -> some View {
        let layout = PiBotTeamLayout(live)
        return SettingsCard(title: "Bots", detail: "Each bot's name, role, profile and team. Teams are optional and one level deep: a manager hands work to the bots on its team. An orchestrator is optional and oversees every bot and team. Admin Bot's name is fixed; rename any other bot here or by asking it or Admin Bot.") {
            SettingsField("Orchestrator") {
                SettingsNote("Optional. Sits above every team; Admin Bot stays apart.")
                BotSettingsReferencePicker(selection: live.first(where: \.orchestrator)?.id ?? "",
                    options: [.init("", "None")] + live.filter { !$0.isAdmin }.map { .init($0.id, $0.name) },
                    label: "Orchestrator") { id in act { try await $0.setOrchestrator(botID: id.isEmpty ? nil : id) } }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("Bot").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    Text("Profile").frame(width: 180, alignment: .leading)
                    Text("Team").frame(width: 180, alignment: .leading)
                }.font(.system(size: 11, weight: .semibold)).foregroundStyle(DashboardPalette.mutedForeground)
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(layout.rows) { row in
                    botRow(row.bot, all: live, profiles: profiles).padding(.leading, row.isMember ? 18 : 0)
                }
                if let admin = layout.admin { botRow(admin, all: live, profiles: profiles).padding(.top, 18) }
            }
        }
    }

    private func botRow(_ bot: PiBotSummary, all: [PiBotSummary], profiles: [PiBotProfile]) -> some View {
        SettingsInset {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    name(bot, all: all).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    profilePicker(bot, profiles: profiles)
                    VStack(alignment: .leading, spacing: 4) {
                        teamPicker(bot, all: all)
                        handoffPicker(bot, all: all)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    name(bot, all: all)
                    profilePicker(bot, profiles: profiles)
                    teamPicker(bot, all: all)
                    handoffPicker(bot, all: all)
                }
            }
        }
    }

    private func name(_ bot: PiBotSummary, all: [PiBotSummary]) -> some View {
        BotSettingsBotName(bot: bot, members: all.filter { $0.managerId == bot.id }) { name in
            act { try await $0.renameBot(id: bot.id, name: name) }
        }
    }

    @ViewBuilder private func handoffPicker(_ bot: PiBotSummary, all: [PiBotSummary]) -> some View {
        let members = all.filter { $0.managerId == bot.id }
        if !bot.isAdmin, bot.manager, !members.isEmpty {
            BotSettingsReferencePicker(selection: "", options: [.init("", "Hand team to…")] + members.map { .init($0.id, $0.name) },
                label: "Hand \(bot.name)'s team to") { id in
                if !id.isEmpty { act { try await $0.replaceManager(managerID: bot.id, newManagerID: id) } }
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

    @ViewBuilder private func teamPicker(_ bot: PiBotSummary, all: [PiBotSummary]) -> some View {
        if bot.isAdmin { SettingsNote("Never on a team").frame(width: 180, height: 36, alignment: .leading) }
        else {
            BotSettingsReferencePicker(selection: bot.placement,
                options: [.init("none", "No team"), .init("manager", "Manager")]
                    + all.filter { !$0.isAdmin && $0.manager && $0.id != bot.id && !bot.orchestrator }
                        .map { .init($0.id, "On \($0.name)'s team") }, label: "Team for \(bot.name)") { place(bot, placement: $0) }
        }
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
    private func rebuildCard(_ live: [PiBotSummary]) -> some View {
        SettingsCard(title: "Containers", detail: "A stopped bot starts again on its next tool call. Rebuild recreates a bot's container from a clean image; its files, restart list, browser profile, memory and conversations stay.") {
            ForEach(live.filter { !$0.isAdmin }) { bot in
                SettingsInset {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bot.name).font(.system(size: 13, weight: .medium))
                                if let environment = environments[bot.id] { SettingsNote(environment.stateText) }
                            }
                            Spacer()
                            if environments[bot.id]?.state == "running" {
                                Button { act { try await $0.stopBot(id: bot.id) } } label: { BotSettingsActionLabel(title: "Stop", glyph: .close) }
                                    .accessibilityLabel("Stop \(bot.name)")
                            }
                            Button { rebuild(bot) } label: { BotSettingsActionLabel(title: "Rebuild", glyph: .rotate) }
                                .accessibilityLabel("Rebuild \(bot.name)")
                        }
                        ForEach(environments[bot.id]?.previews ?? [], id: \.port) { preview in
                            HStack(spacing: 8) {
                                Text("Port \(preview.port)").font(.system(size: 12))
                                Text(preview.url).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
                                Spacer()
                                Button("Stop sharing") { act { try await $0.stopPreview(botID: bot.id, port: preview.port) } }
                            }
                        }
                    }
                }
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

    private func deletedCard(_ deleted: [PiBotDeletedBot]) -> some View {
        SettingsCard(title: "Deleted bots", detail: "Deleted bots keep their conversations and threads. Restore one to bring it back, or delete it permanently.") {
            ForEach(deleted) { bot in
                SettingsInset {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bot.name).font(.system(size: 13, weight: .medium))
                            SettingsNote("Deleted \(deletedDate(bot.deletedAt))")
                        }
                        Spacer()
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
            HStack {
                TextField("", text: Binding(get: { self.draft ?? "" }, set: { self.draft = String($0.prefix(80)) }))
                    .dashboardInput().accessibilityLabel("New name for \(bot.name)")
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
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(bot.name).font(.system(size: 13, weight: .medium))
                    SettingsPill(bot.role, tone: .neutral)
                }
                HStack(spacing: 5) {
                    if let note {
                        Text(note).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground)
                        if !bot.isAdmin { Text("·").foregroundStyle(DashboardPalette.mutedForeground) }
                    }
                    if !bot.isAdmin {
                        Button("Rename") { draft = bot.name }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .accessibilityLabel("Rename \(bot.name)")
                    }
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
