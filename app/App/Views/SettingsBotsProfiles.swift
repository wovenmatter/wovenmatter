import SwiftUI

struct BotSettingsProfiles: View {
    let state: BotSettingsState
    @State private var profiles: [PiBotProfile]?
    @State private var catalog: PiBotModelCatalog?
    @State private var editing: String?
    @State private var titleDraft: PiBotRoles?
    @State private var refreshes = 0

    var body: some View {
        Group {
            if let profiles, let catalog {
                profilesSection(profiles, providers: catalog.providers, reasoningLevels: catalog.reasoningLevels)
                titlesSection(catalog)
                availableSection(catalog.providers)
            } else { SettingsEmpty("Loading…") }
        }
        .task(id: "\(state.bots.isConnected):\(state.bots.settingsRevision)") {
            guard state.bots.isConnected else { return }
            await state.load { try await refresh() }
        }
    }

    private var live: [PiBotSummary] { state.bots.bots }

    private func refresh() async throws {
        refreshes += 1
        let current = refreshes
        async let listed = state.bots.profiles()
        async let models = state.bots.modelCatalog()
        let result = try await (listed, models)
        // An older read that finishes late must not undo a newer save.
        guard current == refreshes else { return }
        profiles = result.0; catalog = result.1
        await state.bots.refreshOnboarding(onError: { state.error = $0 })
    }

    private func profilesSection(_ profiles: [PiBotProfile], providers: [PiBotProviderModels], reasoningLevels: [String]) -> some View {
        SettingsSection(title: "Profiles", detail: "New bots use the default. Changes apply from each bot's next reply.") {
            ForEach(profiles) { profile in
                if editing == profile.id {
                    editor(profile, providers: providers, reasoningLevels: reasoningLevels)
                } else { profileRow(profile) }
            }
            if editing == "" { editor(nil, providers: providers, reasoningLevels: reasoningLevels) }
            else {
                Button { editing = "" } label: { BotSettingsActionLabel(title: "New profile", glyph: .plus) }
                    .disabled(editing != nil)
            }
            SettingsHelp {
                SettingsNote("A profile is a main model for a bot's channel and threads. The main model can run subagents on itself or on the models in its pool.")
            }
        }
    }

    private func editor(_ profile: PiBotProfile?, providers: [PiBotProviderModels], reasoningLevels: [String]) -> some View {
        BotSettingsProfileEditor(profile: profile, providers: providers, reasoningLevels: reasoningLevels, onSave: { draft in
            await state.run {
                profiles = try await state.bots.saveProfile(draft, create: profile == nil)
                editing = nil
                try await refresh()
            }
        }, onCancel: { editing = nil }).id(profile?.id ?? "new")
    }

    private func profileRow(_ profile: PiBotProfile) -> some View {
        let users = live.filter { $0.profileId == profile.id }.map(\.name)
        let fallbacks = profile.fallbacks
        return SettingsSummaryRow(profile.name, value: (profile.isDefault ? "Default · " : "") + (profile.main.isEmpty ? "No model yet" : profile.main)) {
            SettingsValueRow(label: "Reasoning", value: profile.reasoning.capitalized)
            SettingsValueRow(label: "Fallbacks", value: fallbacks.isEmpty ? "None" : fallbacks.joined(separator: " → "))
            SettingsValueRow(label: "Model pool", value: profile.pool.isEmpty ? "Main model only" : "Main model + " + profile.pool.map(\.model).joined(separator: ", "))
            SettingsValueRow(label: "Memory extraction", value: profile.memoryModel ?? "Active main model")
            SettingsValueRow(label: "Used by", value: users.isEmpty ? "No bots" : users.joined(separator: ", "))
            HStack(spacing: 8) {
                Button("Edit") { editing = profile.id }.disabled(editing != nil)
                if !profile.isDefault {
                    Button("Make default") {
                        Task {
                            await state.run {
                                profiles = try await state.bots.setDefaultProfile(id: profile.id)
                                try await refresh()
                            }
                        }
                    }
                    Button { delete(profile) } label: { BotSettingsActionLabel(title: "Delete", glyph: .trash) }
                        .accessibilityLabel("Delete profile \(profile.name)")
                }
            }
            .padding(.top, 4)
        }
    }

    private func delete(_ profile: PiBotProfile) {
        let count = live.filter { $0.profileId == profile.id }.count
        let note = count > 0 ? " \(count) bot(s) on it move to the default profile." : ""
        state.confirm("Delete profile \(profile.name)?\(note)", action: "Delete") {
            Task {
                await state.run {
                    profiles = try await state.bots.deleteProfile(id: profile.id)
                    try await refresh()
                }
            }
        }
    }

    private func titlesSection(_ catalog: PiBotModelCatalog) -> some View {
        let roles = titleDraft ?? catalog.roles
        return SettingsSection(title: "Thread titles", detail: "One model names every bot's threads from their first message.") {
            SettingsRow(title: "Model") {
                BotSettingsModelPicker(providers: catalog.providers, selection: Binding(
                    get: { (titleDraft ?? catalog.roles).titles },
                    set: { titleDraft = PiBotRoles(titles: $0, titlesReasoning: roles.titlesReasoning) }), label: "Title model",
                    emptyLabel: "Default profile's main model")
            }
            SettingsRow(title: "Reasoning") {
                SettingsPicker("Title reasoning", selection: Binding(
                    get: { roles.titlesReasoning },
                    set: { titleDraft = PiBotRoles(titles: roles.titles, titlesReasoning: $0) }
                ), options: catalog.reasoningLevels) { $0.capitalized }
            }
            if roles != catalog.roles {
                HStack(spacing: 8) {
                    Button("Save") {
                        Task {
                            await state.run {
                                let saved = try await state.bots.setRoles(roles)
                                refreshes += 1 // Older reads still hold the previous roles.
                                self.catalog?.roles = saved
                                titleDraft = nil
                            }
                        }
                    }.buttonStyle(WovenPrimaryButtonStyle())
                    Button("Reset") { titleDraft = nil }
                }
            }
        }
    }

    private func availableSection(_ providers: [PiBotProviderModels]) -> some View {
        SettingsSection(title: "Available models", detail: "From Settings → Subscriptions & API Keys.") {
            if providers.isEmpty {
                SettingsEmpty("No providers are connected.")
                if let machineID = state.bots.hostMachineID { ManageAccountsLink(machineID: machineID) } else { ManageAccountsLink() }
            } else {
                ForEach(providers) { provider in
                    SettingsSummaryRow(provider.name, value: provider.models.count == 1 ? "1 model" : "\(provider.models.count) models") {
                        ForEach(provider.models) { model in
                            BotSettingsModelFacts(providers: providers, model: "\(provider.id)/\(model.id)", name: model.name)
                        }
                    }
                }
            }
        }
    }
}
