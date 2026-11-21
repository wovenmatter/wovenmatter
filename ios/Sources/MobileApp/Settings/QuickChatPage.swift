import SwiftUI
import WovenProtocol

/// Quick Chat on this device: its sign-ins, the models it offers, and the
/// defaults new chats start with. These are the device's own Pi Durable
/// settings (`piDurable.<device>`, `agentDefaults.piDurable.<device>`).
struct QuickChatPage: View {
    @Bindable var model: MobileModel
    let deviceID: String
    @State private var thinking: String?
    @State private var thinkingLevels: [SessionOption] = []
    @State private var error: String?

    private var agent: AgentSettingsStore { model.app.connections }
    private var connections: MachineProviderConnections { agent.connections(on: deviceID) }

    var body: some View {
        List {
            Section {
                SettingsLinkRow(title: "Subscriptions & API Keys", detail: "Sign in to the providers whose models Quick Chat uses.",
                                value: providersSummary, tone: connections.availableModelProviderIDs.isEmpty ? .warning : .good,
                                page: .providers)
                    .accessibilityIdentifier("quick-chat-providers")
            } header: {
                SettingsHeader(title: "Quick Chat", detail: "Quick questions, web search and artifacts on this \(ThisDevice.kind). Powered by Pi Durable.")
            }
            Section {
                SettingsLinkRow(title: "Default model", value: defaultModelName, page: .defaultModel)
                    .accessibilityIdentifier("quick-chat-default-model")
                SettingsLinkRow(title: "In the composer", value: agent.orderedModels.count == 1 ? "1 model" : "\(agent.orderedModels.count) models",
                                page: .composerModels)
                    .accessibilityIdentifier("quick-chat-composer-models")
            } header: {
                SettingsHeader(title: "Models")
            }
            if !thinkingLevels.isEmpty {
                Section {
                    Picker(selection: Binding(get: { thinking ?? "" }, set: saveThinking)) {
                        Text("Model’s default").tag("")
                        ForEach(thinkingLevels, id: \.id) { level in Text(level.name).tag(level.id) }
                    } label: {
                        Text("Thinking level").foregroundStyle(WovenPalette.foreground)
                    }
                    .tint(WovenPalette.mutedForeground)
                    .frame(minHeight: 44)
                    .settingsRow()
                    .accessibilityIdentifier("quick-chat-thinking")
                } header: {
                    SettingsHeader(title: "Defaults for new chats", detail: "You can change these in each chat.")
                }
            }
            if let error { SettingsCaption(error, isError: true) }
        }
        .settingsPage("Quick Chat")
        .task {
            agent.loadAccounts(on: deviceID)
            agent.loadCatalog(includeAllModels: true)
            await loadThinking()
        }
        .onChange(of: agent.configuration.defaultModel) { _, _ in Task { await loadThinking() } }
    }

    private var providersSummary: String {
        let count = connections.availableModelProviderIDs.count
        return count == 0 ? "None" : "\(count) connected"
    }

    private var defaultModelName: String {
        guard let id = agent.effectiveDefaultModel else { return "First available" }
        return agent.catalog.first { $0.id == id }?.name ?? id
    }

    /// The thinking levels Quick Chat last reported for its model; until a
    /// Quick Chat has started there are none to choose from.
    private func loadThinking() async {
        do {
            thinking = try await model.app.settings.agentSelectionDefaults(runtime: .defaultAgent, machineID: deviceID).resolved.thinking
            let options = try await model.app.settings.sessionOptions(runtime: .defaultAgent, machineID: deviceID,
                                                                       machines: model.app.machines, model: nil)
            thinkingLevels = options.thinkingLevels.map { SessionOption(id: $0, name: options.thinkingOptionMetadata[$0]?.name ?? $0) }
            error = nil
        } catch is RuntimeOptionsUnknown {
            thinkingLevels = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveThinking(_ value: String) {
        thinking = value.isEmpty ? nil : value
        Task {
            do {
                _ = try await model.app.settings.saveAgentSelectionDefault(runtime: .defaultAgent, machineID: deviceID, field: .thinking,
                                                                           selections: SessionSelections(thinking: value.isEmpty ? nil : value))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The model new Quick Chats start with, chosen from the connected providers' catalogs.
struct DefaultModelPage: View {
    @Bindable var model: MobileModel
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var agent: AgentSettingsStore { model.app.connections }

    var body: some View {
        List {
            Section {
                choice(title: "First available model", detail: nil, id: nil)
            }
            ForEach(ModelCatalogGroup.groups(agent.catalog, matching: search), id: \.provider) { group in
                Section {
                    ForEach(group.models) { item in choice(title: item.name, detail: nil, id: item.id) }
                } header: {
                    SettingsHeader(title: group.name)
                }
            }
            ModelCatalogStatus(agent: agent, search: search)
        }
        .searchable(text: $search, prompt: "Find a model")
        .settingsPage("Default model")
    }

    private func choice(title: String, detail: String?, id: String?) -> some View {
        let selected = agent.configuration.defaultModel == id
        return Button {
            select(id)
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(WovenPalette.foreground)
                Spacer()
                if selected { LucideIcon(glyph: .check, size: 18).foregroundStyle(WovenPalette.primary) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsRow()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The default is the defaults for new chats' model, and is always in the composer.
    private func select(_ id: String?) {
        let agent = agent
        Task {
            _ = try? await model.app.settings.saveAgentSelectionDefault(runtime: .defaultAgent, machineID: deviceID, field: .model,
                                                                        selections: SessionSelections(model: id))
            var configuration = agent.configuration
            configuration.defaultModel = id
            if let id, !configuration.models.contains(id) { configuration.models.append(id) }
            agent.configuration = configuration
        }
    }
}

/// The models offered in the Quick Chat composer, in order, and Add models.
struct ComposerModelsPage: View {
    @Bindable var model: MobileModel
    @State private var adding = false

    private var agent: AgentSettingsStore { model.app.connections }

    var body: some View {
        List {
            Section {
                ForEach(agent.orderedModels) { item in
                    let isDefault = item.id == agent.effectiveDefaultModel
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).foregroundStyle(WovenPalette.foreground)
                        Text(isDefault ? "\(item.providerName) · Default" : item.providerName)
                            .font(.footnote).foregroundStyle(WovenPalette.mutedForeground)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .settingsRow()
                    .deleteDisabled(isDefault)
                }
                .onDelete { offsets in
                    for id in offsets.map({ agent.orderedModels[$0].id }) { agent.setVisible(id, visible: false) }
                }
                .onMove { from, to in
                    var order = agent.orderedModels.map(\.id)
                    order.move(fromOffsets: from, toOffset: to)
                    var configuration = agent.configuration
                    configuration.models = order
                    agent.configuration = configuration
                }
                SettingsActionRow(title: "Add models") { adding = true }
                    .accessibilityIdentifier("composer-add-models")
            } header: {
                SettingsHeader(title: "In the composer", detail: "Your default model is always available in the composer.")
            }
        }
        .settingsPage("In the composer")
        .toolbar { if agent.orderedModels.count > 1 { EditButton() } }
        .sheet(isPresented: $adding) { AddModelsSheet(agent: agent) }
    }
}

/// Every model of the connected providers, to add to the composer or take out.
private struct AddModelsSheet: View {
    @Bindable var agent: AgentSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wovenTheme) private var theme
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(ModelCatalogGroup.groups(agent.catalog, matching: search), id: \.provider) { group in
                    Section {
                        ForEach(group.models) { item in row(item) }
                    } header: {
                        SettingsHeader(title: group.name)
                    }
                }
                ModelCatalogStatus(agent: agent, search: search)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a model")
            .settingsPage("Add models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .environment(\.wovenTheme, theme)
    }

    private func row(_ item: PiDurableModel) -> some View {
        let isDefault = item.id == agent.effectiveDefaultModel
        let shown = isDefault || agent.orderedModels.contains { $0.id == item.id }
        return Button {
            agent.setVisible(item.id, visible: !shown)
        } label: {
            HStack {
                Text(item.name).foregroundStyle(WovenPalette.foreground)
                Spacer()
                if shown { LucideIcon(glyph: .check, size: 18).foregroundStyle(WovenPalette.primary) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDefault)
        .settingsRow()
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}

/// A provider's models, for a catalog list grouped by provider.
struct ModelCatalogGroup {
    let provider: String
    let name: String
    let models: [PiDurableModel]

    static func groups(_ catalog: [PiDurableModel], matching search: String) -> [ModelCatalogGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matches = catalog.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.providerName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
        var order: [String] = []
        var byProvider: [String: [PiDurableModel]] = [:]
        for item in matches {
            if byProvider[item.provider] == nil { order.append(item.provider) }
            byProvider[item.provider, default: []].append(item)
        }
        return order.map { provider in
            let models = byProvider[provider] ?? []
            return ModelCatalogGroup(provider: provider, name: models.first?.providerName ?? provider,
                                     models: models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }
}

/// What a catalog list says while it loads, when nothing is connected, or when nothing matches.
private struct ModelCatalogStatus: View {
    let agent: AgentSettingsStore
    let search: String

    var body: some View {
        if agent.busy && agent.catalog.isEmpty {
            SettingsCaption("Loading models…")
        } else if let error = agent.error, agent.catalog.isEmpty {
            SettingsCaption(error, isError: true)
        } else if agent.catalog.isEmpty {
            SettingsCaption("Sign in to a model provider to choose its models.")
        } else if ModelCatalogGroup.groups(agent.catalog, matching: search).isEmpty {
            SettingsCaption("No models match.")
        }
    }
}
