import SwiftUI
import WovenMatterClient

struct BotSettingsProfiles: View {
    let state: BotSettingsState
    @State private var profiles: [PiBotProfile]?
    @State private var live: [PiBotSummary] = []
    @State private var catalog: PiBotModelCatalog?
    @State private var editing: String?
    @State private var titleDraft: PiBotRoles?
    @State private var refreshes = 0

    var body: some View {
        Group {
            if let profiles, let catalog {
                profilesCard(profiles, providers: catalog.providers)
                titlesCard(catalog)
                availableCard(catalog.providers)
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
        async let listed = client.profiles()
        async let active = client.bots()
        async let models = client.modelCatalog()
        let result = try await (listed, active, models)
        // An older read that finishes late must not undo a newer save.
        guard current == refreshes else { return }
        profiles = result.0.profiles; live = result.1; catalog = result.2
        await state.bots.refreshOnboarding(onError: { state.error = $0 })
    }

    private func profilesCard(_ profiles: [PiBotProfile], providers: [PiBotProviderModels]) -> some View {
        SettingsCard(title: "Profiles", detail: "A profile is a main model for a bot's channel and threads, which can run subagents on itself or on the models in its pool. New bots get the default. Changes apply from each bot's next reply.") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(profiles) { profile in
                    if editing == profile.id {
                        editor(profile, providers: providers)
                    } else { profileRow(profile) }
                }
                if editing == "" { editor(nil, providers: providers) }
                else {
                    Button { editing = "" } label: { BotSettingsActionLabel(title: "New profile", glyph: .plus) }
                        .disabled(editing != nil)
                }
            }
        }
    }

    private func editor(_ profile: PiBotProfile?, providers: [PiBotProviderModels]) -> some View {
        BotSettingsProfileEditor(profile: profile, providers: providers, onSave: { draft in
            await state.run { client in
                profiles = try await client.saveProfile(draft, create: profile == nil).profiles
                editing = nil
                try await refresh(client)
            }
        }, onCancel: { editing = nil }).id(profile?.id ?? "new")
    }

    private func profileRow(_ profile: PiBotProfile) -> some View {
        let users = live.filter { $0.profileId == profile.id }.map(\.name)
        return SettingsInset {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(profile.name).font(.system(size: 13, weight: .medium))
                    if profile.isDefault { SettingsPill("Default", tone: .neutral) }
                    Spacer()
                    if !profile.isDefault {
                        Button("Make default") {
                            Task {
                                await state.run { client in
                                    profiles = try await client.setDefaultProfile(id: profile.id).profiles
                                    try await refresh(client)
                                }
                            }
                        }
                        Button { delete(profile) } label: { DashboardLucideIcon(glyph: .trash, size: 14) }
                            .accessibilityLabel("Delete profile \(profile.name)")
                    }
                    Button("Edit") { editing = profile.id }.disabled(editing != nil)
                }
                SettingsNote(profile.main + ((profile.fallbacks ?? []).isEmpty ? " · no fallbacks" : " → " + (profile.fallbacks ?? []).joined(separator: " → ")))
                SettingsNote((profile.pool.isEmpty ? "Model pool: main model only" : "Model pool: main model + " + profile.pool.map(\.model).joined(separator: ", "))
                    + " · Memory extraction: \(profile.memoryModel ?? "active main model") · "
                    + (users.isEmpty ? "No bots" : "Used by " + users.joined(separator: ", ")))
            }
        }
    }

    private func delete(_ profile: PiBotProfile) {
        let count = live.filter { $0.profileId == profile.id }.count
        let note = count > 0 ? " \(count) bot(s) on it move to the default profile." : ""
        state.confirm("Delete profile \(profile.name)?\(note)", action: "Delete") {
            Task {
                await state.run { client in
                    profiles = try await client.deleteProfile(id: profile.id).profiles
                    try await refresh(client)
                }
            }
        }
    }

    private func titlesCard(_ catalog: PiBotModelCatalog) -> some View {
        let roles = titleDraft ?? catalog.roles
        return SettingsCard(title: "Thread titles", detail: "Names threads from their first message. One model for every bot; profiles don't change it.") {
            SettingsField("Title model") {
                BotSettingsModelPicker(providers: catalog.providers, selection: Binding(
                    get: { (titleDraft ?? catalog.roles).titles },
                    set: { titleDraft = PiBotRoles(titles: $0, titlesReasoning: roles.titlesReasoning) }), label: "Title model")
            }
            SettingsField("Title reasoning") {
                SettingsMenuPicker(selection: roles.titlesReasoning + " reasoning",
                    options: catalog.reasoningLevels.map { $0 + " reasoning" }) { value in
                    titleDraft = PiBotRoles(titles: roles.titles, titlesReasoning: String(value.dropLast(" reasoning".count)))
                }
            }
            if roles != catalog.roles {
                HStack {
                    Button("Save") {
                        Task {
                            await state.run { client in
                                self.catalog?.roles = try await client.setRoles(roles)
                                titleDraft = nil; state.configSaved()
                            }
                        }
                    }.buttonStyle(DashboardPrimaryButtonStyle())
                    Button("Reset") { titleDraft = nil }
                }
            }
        }
    }

    private func availableCard(_ providers: [PiBotProviderModels]) -> some View {
        SettingsCard(title: "Available models") {
            if providers.isEmpty { SettingsEmpty("No providers signed in. Add one under Accounts.") }
            else {
                ForEach(providers) { provider in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(provider.models) { model in
                                BotSettingsModelFacts(providers: providers, model: "\(provider.id)/\(model.id)", name: model.name)
                            }
                        }
                    } label: {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            Text(provider.models.count == 1 ? "1 model" : "\(provider.models.count) models").foregroundStyle(DashboardPalette.mutedForeground)
                        }.font(.system(size: 13))
                    }
                }
            }
        }
    }
}
