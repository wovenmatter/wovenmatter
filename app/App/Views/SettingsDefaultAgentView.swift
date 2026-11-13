import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct SettingsDefaultAgentView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    var onOpenAccounts: (String) -> Void = { _ in }
    private var agent: DefaultAgentSettingsModel { model.connections }
    @State private var settingsScope = "global"
    @State private var syncError: String?
    @State private var browsingAllModels = false
    @State private var setupProvider: String?
    @State private var setupRequest = UUID()
    @State private var savingScope = false

    private var workspaces: [RemoteWorkspaceConfiguration] { model.remoteWorkspaces.workspaces }
    private var remote: RemoteWorkspaceConfiguration? {
        workspaces.first { $0.id.uuidString.lowercased() == agent.scope }
    }
    private var editable: Bool { !agent.inherits }
    /// With no remote workspace there is nothing to choose, unless this Mac keeps its own settings.
    private var showsWorkspacePicker: Bool {
        !workspaces.isEmpty || settingsScope != "global" || agent.settings.workspaces["local"] != nil
    }

    var body: some View {
        settingsPage
            .task {
                settingsScope = initialScope
                selectScope(initialScope)
                requestSDKStatus()
                if let provider = model.pendingDefaultAgentModelProvider {
                    model.pendingDefaultAgentModelProvider = nil
                    connected(provider)
                }
            }
            .onDisappear { agent.cancel() }
    }

    private var settingsPage: some View {
        SettingsPage(
            title: AgentRuntimeKind.defaultAgent.displayName,
            detail: "An agent for every workspace, powered by the Pi Durable SDK.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            if showsWorkspacePicker { scopeSection }
            SettingsSection {
                SettingsSummaryLink(title: "Subscriptions & API Keys",
                    detail: "Sign in to the providers whose models Pi Durable uses.", value: accountsSummary,
                    tone: agent.availableModelProviderIDs.isEmpty ? .warning : .good) {
                    onOpenAccounts(agent.scope)
                }
            }
            SettingsAgentModelsView(agent: agent, editable: editable,
                browsingAllModels: browsingAllModels, setupProvider: setupProvider, setupRequest: setupRequest,
                setBrowsingAllModels: { showCatalog($0) },
                selectDefault: selectDefault)
            SettingsAgentDefaultsSection(model: model, runtime: .defaultAgent, scope: agent.scope,
                showsModel: false)
            moreSection
            if let error = syncError { SettingsError(error) }
        }
    }

    private var accountsSummary: String {
        let count = agent.availableModelProviderIDs.count
        return count == 0 ? "None connected" : "\(count) connected"
    }

    private var moreSection: some View {
        SettingsSection(title: "More") {
            SettingsSummaryRow("Code mode", value: agent.configuration.resolvedCodeMode.title) {
                SettingsRow(title: "Mode") {
                    SettingsPicker("Code mode", selection: Binding(get: { agent.configuration.resolvedCodeMode }, set: {
                        var config = agent.configuration; config.codeMode = $0; agent.configuration = config
                    }), options: BuiltInCodeMode.allCases) { $0.title }
                    .disabled(!editable)
                }
                SettingsNote("Runs JavaScript that calls the agent’s tools, and each call keeps its normal permissions. On adds code mode alongside the other tools. Only routes all tool calls through code mode. Off uses standard tool calls. Changes apply between turns.")
            }
            SettingsSummaryRow("Subagents", value: "Up to \(agent.configuration.resolvedSubagentConcurrency)") {
                SettingsRow(title: "Active per conversation", detail: "Applies to new conversations. The parent agent does not count.") {
                    SettingsPicker("Maximum active subagents per conversation", selection: Binding(
                        get: { agent.configuration.resolvedSubagentConcurrency },
                        set: {
                            var config = agent.configuration
                            config.subagentConcurrency = $0
                            agent.configuration = config
                        }
                    ), options: Array(DefaultAgentSettings.subagentConcurrencyRange), popoverWidth: 120) { String($0) }
                    .disabled(!editable)
                }
            }
            SettingsSummaryRow("Software", value: softwareSummary) {
                SettingsDefaultAgentSDKView(connections: agent, remoteWorkspaces: model.remoteWorkspaces)
            }
            SettingsSummaryRow("Synchronization", value: syncError == nil ? "Automatic" : "Needs attention",
                tone: syncError == nil ? nil : .warning) {
                SettingsRow(title: "Shared settings", detail: "Offline workspaces receive changes when they reconnect.") {
                    Button("Retry synchronization") { synchronize() }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
        }
    }

    private var softwareSummary: String {
        let state = agent.sdks.state(for: agent.scope == "global" ? "local" : agent.scope)
        if state.busy { return "Checking" }
        guard let sdks = state.status?.sdks else { return "Not checked" }
        return sdks.contains { $0.updateAvailable || $0.consistent == false } ? "Update available" : "Up to date"
    }

    private func requestSDKStatus() {
        let target = agent.scope == "global" ? "local" : agent.scope
        let state = agent.sdks.state(for: target)
        guard state.status == nil, !state.busy else { return }
        agent.sdks.request(.init(workspaceID: UUID(uuidString: target), request: .init(action: .status)),
                           connections: agent, remoteWorkspaces: model.remoteWorkspaces)
    }

    private var scopeSection: some View {
        SettingsSection {
            SettingsWorkspacePicker(title: "Applies to",
                scope: Binding(get: { settingsScope }, set: { settingsScope = $0; selectScope($0) }),
                workspaces: workspaces)
            if settingsScope != "global" {
                SettingsToggleRow(
                    title: "Use shared chat settings",
                    detail: agent.inherits
                        ? "Model, thinking, permissions, and tool preferences follow All workspaces. Accounts stay independent."
                        : "Chat settings apply only to this workspace. Accounts stay independent.",
                    isOn: Binding(get: { agent.inherits }, set: { setSharing($0) })
                )
            }
        }
        .disabled(savingScope)
    }

    private func setSharing(_ shared: Bool) {
        let scope = agent.scope
        let workspace = scope == "local"
            ? model.localACPWorkspaceLaunchConfiguration.map { "local:" + $0.rootURL.standardizedFileURL.path }
            : "remote:" + scope
        guard scope != "global", let workspace else { return }
        savingScope = true; syncError = nil
        Task { @MainActor in
            defer { savingScope = false }
            do {
                _ = try await model.setAgentDefaultsSharing(runtime: .defaultAgent, workspace: workspace, shared: shared)
                guard agent.scope == scope else { return }
                agent.setInherits(shared)
                agent.loadCatalog(remote: remote, includeAllModels: browsingAllModels)
            } catch { syncError = error.localizedDescription }
        }
    }

    private func connected(_ provider: String) {
        settingsScope = agent.inherits ? "global" : settingsScope
        if agent.scope != settingsScope { agent.changeScope(settingsScope) }
        setupProvider = nil
        browsingAllModels = true
        agent.loadCatalog(remote: remote, includeAllModels: true, provider: provider)
        setupProvider = provider
        setupRequest = UUID()
    }

    private func selectDefault(_ id: String?) {
        let targetScope = agent.scope
        let workspace = targetScope == "global" ? nil : targetScope == "local"
            ? model.localACPWorkspaceLaunchConfiguration.map { "local:" + $0.rootURL.standardizedFileURL.path }
            : "remote:" + targetScope
        Task {
            do {
                _ = try await model.saveAgentSelectionDefault(runtime: .defaultAgent, workspace: workspace,
                    field: .model, selections: SessionSelections(model: id))
                guard agent.scope == targetScope else { return }
                var config = agent.configuration
                config.defaultModel = id
                if let id, !config.models.contains(id) { config.models.append(id) }
                agent.configuration = config
            } catch { syncError = error.localizedDescription }
        }
    }

    private func selectScope(_ scope: String) {
        browsingAllModels = false
        setupProvider = nil
        agent.changeScope(scope)
        agent.loadAccounts()
        agent.loadCatalog(remote: remote, includeAllModels: false)
        requestSDKStatus()
    }

    private func showCatalog(_ includeAllModels: Bool) {
        browsingAllModels = includeAllModels
        if !includeAllModels { setupProvider = nil }
        agent.loadCatalog(remote: remote, includeAllModels: includeAllModels)
    }

    private func synchronize() {
        syncError = nil
        model.refreshLocalACPRuntimesNow()
        Task {
            for workspace in model.remoteWorkspaces.workspaces {
                do { try await model.remoteWorkspaces.synchronizeDefaultAgent(workspace) }
                catch { syncError = "\(workspace.name): \(error.localizedDescription)" }
            }
        }
    }
}


/// Catalog metadata is indexed only when the source catalog changes. Preferences and
/// filters project that index; rendering a row never scans or classifies the catalog.
private struct SettingsAgentCatalogIndex {
    // Re-entering Settings recreates its view state. Retain one immutable value
    // snapshot of catalog metadata so an unchanged catalog is not classified again.
    // No scope, account, preference, filter, or selection state is shared here.
    @MainActor private static var latest: SettingsAgentCatalogIndex?

    struct Entry: Identifiable {
        let model: DefaultAgentSettingsModel.Model
        let lab: String
        var id: String { model.id }
        func matches(_ query: String) -> Bool {
            query.isEmpty || model.name.localizedCaseInsensitiveContains(query)
                || model.providerName.localizedCaseInsensitiveContains(query)
                || id.localizedCaseInsensitiveContains(query)
        }
    }
    private(set) var source: [DefaultAgentSettingsModel.Model] = []
    private(set) var entries: [Entry] = []
    private(set) var byID: [String: Entry] = [:]
    private(set) var providers: [String] = []
    private(set) var labs: [String] = []

    @MainActor mutating func update(_ models: [DefaultAgentSettingsModel.Model]) {
        guard source != models else { return }
        if let cached = Self.latest, cached.source == models {
            self = cached
            return
        }
        source = models
        var seen = Set<String>()
        entries = models.filter { seen.insert($0.id).inserted }.map {
            Entry(model: $0, lab: DefaultAgentModelCatalog.lab(id: $0.id, name: $0.name))
        }
        byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        providers = Array(Set(entries.map { $0.model.provider })).sorted()
        labs = Array(Set(entries.map(\.lab))).sorted()
        Self.latest = self
    }
}

/// The default model, the models offered in the composer, and fallbacks. The full provider
/// catalog loads only when the person opens Add models.
private struct SettingsAgentModelsView: View {
    let agent: DefaultAgentSettingsModel
    let editable: Bool
    let browsingAllModels: Bool
    let setupProvider: String?
    let setupRequest: UUID
    let setBrowsingAllModels: (Bool) -> Void
    let selectDefault: (String?) -> Void
    @State private var index = SettingsAgentCatalogIndex()
    @State private var filter = Filter()
    @State private var rows: [Row] = []
    @State private var matches: [Row] = []
    @State private var page = 0
    @State private var enabledPage = 0
    @State private var choosingDefault = false
    @State private var fallbackPage = 0
    @State private var showsBrowser = false
    // Pagination bounds the browser's data. The lazy section and row stacks below
    // defer offscreen native controls within SettingsPage's existing scroll viewport.
    private let pageSize = 40

    private struct Inputs: Equatable {
        let scope: String
        let catalog: [DefaultAgentSettingsModel.Model]
        let configuration: DefaultAgentSettings
        let effectiveDefaultModel: String?
    }
    private struct Filter: Equatable {
        var query = ""
        var connection = ""
        var lab = ""
        var subscriptionsOnly = false
    }
    private struct Row: Identifiable {
        let entry: SettingsAgentCatalogIndex.Entry
        let isDefault: Bool
        let visible: Bool
        let fallback: Int?
        let canMoveEarlier: Bool
        let canMoveLater: Bool
        var id: String { entry.id }
    }
    private var showingAllModels: Bool { browsingAllModels && agent.catalogIncludesAllModels }
    private var inputs: Inputs {
        let configuration = agent.configuration
        let defaultID = agent.effectiveDefaultModel
        let enabledIDs = Set(configuration.models + [defaultID].compactMap { $0 })
        // Keep cached full catalogs out of the initial view/index, including the
        // first render before the page's enabled-only load has been applied.
        let displayedCatalog = showingAllModels ? agent.catalog : agent.catalog.filter { enabledIDs.contains($0.id) }
        return Inputs(scope: agent.scope, catalog: displayedCatalog, configuration: configuration,
                      effectiveDefaultModel: defaultID)
    }
    private var enabledRows: [Row] { rows.filter(\.visible) }
    private var pageRows: ArraySlice<Row> {
        matches.dropFirst(page * pageSize).prefix(pageSize)
    }
    private var defaultLabel: String {
        guard let id = agent.configuration.defaultModel else { return "First available model" }
        return index.byID[id].map { "\($0.model.name) · \($0.model.providerName)" } ?? id
    }
    private func modelName(_ id: String) -> String {
        index.byID[id].map { "\($0.model.name) · \($0.model.providerName)" } ?? id
    }
    private var fallbackSummary: String {
        let count = agent.configuration.fallbackModels.count
        return count == 0 ? "None" : count == 1 ? "1 model" : "\(count) models"
    }

    var body: some View {
        SettingsSection(title: "Models") {
            SettingsRow(title: "Default model") {
                Button { choosingDefault = true } label: {
                    HStack(spacing: 8) {
                        Text(defaultLabel).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.settingsSecondary.weight(.semibold))
                            .foregroundStyle(WovenPalette.mutedForeground)
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!editable)
                .accessibilityLabel("Choose default model")
                .accessibilityValue(defaultLabel)
                .popover(isPresented: $choosingDefault, arrowEdge: .bottom) {
                    SettingsAgentDefaultModelChooser(agent: agent,
                        index: index, selection: agent.configuration.defaultModel,
                        browsingAllModels: browsingAllModels, includesAllModels: agent.catalogIncludesAllModels,
                        loading: agent.busy, error: agent.error, setBrowsingAllModels: setBrowsingAllModels
                    ) { id in
                        selectDefault(id)
                        choosingDefault = false
                    }
                }
            }
            SettingsSummaryRow("In the composer", value: enabledRows.count == 1 ? "1 model" : "\(enabledRows.count) models") {
                composerModels
            }
            SettingsSummaryRow("Fallbacks", value: fallbackSummary) {
                fallbacks
            }
        }
        .onChange(of: inputs, initial: true) { old, value in updatePresentation(from: old, to: value) }
        .onChange(of: filter) { _, _ in page = 0; filterRows() }
        .onChange(of: browsingAllModels) { _, _ in filter = Filter(); page = 0; filterRows() }
        .onChange(of: setupRequest) { _, _ in showsBrowser = true }
        .sheet(isPresented: $showsBrowser, onDismiss: { setBrowsingAllModels(false) }) {
            modelBrowser
        }
    }

    @ViewBuilder private var composerModels: some View {
        SettingsNote("Your default model is always available in the composer.")
        if enabledRows.count > pageSize {
            SettingsAgentCatalogPageControls(count: enabledRows.count, pageSize: pageSize, page: $enabledPage)
        }
        LazyVStack(spacing: 2) {
            ForEach(enabledRows.dropFirst(enabledPage * pageSize).prefix(pageSize)) { row in enabledRow(row) }
        }
        Button("Add models…") {
            showsBrowser = true
            setBrowsingAllModels(true)
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(!editable || agent.busy)
    }

    private func enabledRow(_ row: Row) -> some View {
        let item = row.entry.model
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.settingsRow)
                Text(row.isDefault ? "\(item.providerName) · Default" : item.providerName)
                    .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
            }
            Spacer(minLength: 8)
            Button { agent.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Move \(item.name) earlier").disabled(!row.canMoveEarlier)
            Button { agent.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Move \(item.name) later").disabled(!row.canMoveLater)
            if !row.isDefault {
                Button("Remove") { agent.setVisible(item.id, visible: false) }
                    .accessibilityLabel("Remove \(item.name) from the composer")
            }
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(!editable)
    }

    @ViewBuilder private var fallbacks: some View {
        SettingsNote("Used in this order if the current model loses access or reaches its limit.")
        if agent.configuration.fallbackModels.count > pageSize {
            SettingsAgentCatalogPageControls(count: agent.configuration.fallbackModels.count, pageSize: pageSize, page: $fallbackPage)
        }
        ForEach(agent.configuration.fallbackModels.dropFirst(fallbackPage * pageSize).prefix(pageSize), id: \.self) { id in
            HStack(spacing: 6) {
                Text(modelName(id)).font(.settingsRow)
                Spacer()
                Button { agent.moveFallback(id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Move \(index.byID[id]?.model.name ?? id) earlier")
                    .disabled(agent.configuration.fallbackModels.first == id)
                Button { agent.moveFallback(id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Move \(index.byID[id]?.model.name ?? id) later")
                    .disabled(agent.configuration.fallbackModels.last == id)
                Button("Remove") { agent.setFallback(id, enabled: false) }
                    .accessibilityLabel("Remove \(index.byID[id]?.model.name ?? id) from fallbacks")
            }
            .frame(minHeight: SettingsMetrics.rowHeight)
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(!editable)
        }
        let available = enabledRows.filter { $0.fallback == nil }
        Menu("Add fallback") {
            ForEach(available) { row in
                Button("\(row.entry.model.name) · \(row.entry.model.providerName)") {
                    agent.setFallback(row.entry.id, enabled: true)
                }
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(!editable || available.isEmpty)
    }

    /// Filters, paging and every provider model live here, out of the settings page itself.
    private var modelBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add models").font(.settingsTitle)
                Spacer()
                Button("Done") { showsBrowser = false }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            if let provider = setupProvider {
                SettingsNote("Connected. Choose models for chat from \(ProviderConnectionID(rawValue: provider)?.name ?? provider).")
            }
            SettingsAgentCatalogBrowseControls(agent: agent,
                requested: browsingAllModels, includesAllModels: agent.catalogIncludesAllModels,
                loading: agent.busy, error: agent.error, setBrowsingAllModels: setBrowsingAllModels)
            if showingAllModels {
                TextField("Find a model or provider", text: $filter.query).quietTextInput()
                HStack(spacing: 8) {
                    SettingsPicker("Connection", selection: $filter.connection, options: [""] + index.providers) {
                        $0.isEmpty ? "All connection types" : connectionName($0)
                    }
                    SettingsPicker("Lab", selection: $filter.lab, options: [""] + index.labs) {
                        $0.isEmpty ? "All labs" : $0
                    }
                    Spacer(minLength: 8)
                    Toggle("Subscriptions only", isOn: $filter.subscriptionsOnly).fixedSize()
                }
            }
            ScrollView {
                if matches.isEmpty {
                    if showingAllModels {
                        Text("No models match these filters.")
                            .font(.settingsBody).foregroundStyle(WovenPalette.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(pageRows) { row in browserRow(row) }
                    }
                }
            }
            .scrollIndicators(.never)
            if matches.count > pageSize {
                SettingsAgentCatalogPageControls(count: matches.count, pageSize: pageSize, page: $page)
            }
        }
        .padding(24)
        .frame(width: 600, height: 620)
        .foregroundStyle(WovenPalette.foreground)
        .background(WovenPalette.background)
        .toggleStyle(SettingsSwitchToggleStyle())
        .environment(\.settingsFilledControls, true)
    }

    private func browserRow(_ row: Row) -> some View {
        let item = row.entry.model
        return Toggle(isOn: Binding(get: { row.visible }, set: { agent.setVisible(item.id, visible: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.settingsRow)
                Text(row.isDefault ? "\(item.providerName) · Default" : item.providerName)
                    .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
            }
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
        .disabled(row.isDefault || !editable)
    }

    private func updatePresentation(from old: Inputs, to value: Inputs) {
        index.update(value.catalog)
        // Catalogs differ by scope and enabled connection. Never leave a native
        // picker bound to a value that no longer has a corresponding option.
        if !filter.connection.isEmpty && !index.providers.contains(filter.connection) {
            filter.connection = ""
            page = 0
        }
        if !filter.lab.isEmpty && !index.labs.contains(filter.lab) {
            filter.lab = ""
            page = 0
        }
        // A configured subset cannot establish the runtime's implicit default.
        // The model resolves it from an explicit selection or known full metadata.
        let defaultID = value.effectiveDefaultModel
        var seen = Set<String>()
        var visibleIDs = value.configuration.models.filter { index.byID[$0] != nil && seen.insert($0).inserted }
        if let defaultID, seen.insert(defaultID).inserted { visibleIDs.insert(defaultID, at: 0) }
        let positions = Dictionary(uniqueKeysWithValues: visibleIDs.enumerated().map { ($0.element, $0.offset) })
        let fallbacks = Dictionary(value.configuration.fallbackModels.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { min($0, $1) })
        let ordered = visibleIDs.compactMap { index.byID[$0] } + index.entries.filter { !seen.contains($0.id) }
        rows = ordered.map { entry in
            let position = positions[entry.id]
            return Row(entry: entry, isDefault: entry.id == defaultID, visible: position != nil,
                       fallback: fallbacks[entry.id], canMoveEarlier: position.map { $0 > 0 } ?? false,
                       canMoveLater: position.map { $0 + 1 < visibleIDs.count } ?? false)
        }
        if old.scope != value.scope { page = 0; enabledPage = 0; fallbackPage = 0; choosingDefault = false }
        fallbackPage = min(fallbackPage, max(0, (value.configuration.fallbackModels.count - 1) / pageSize))
        enabledPage = min(enabledPage, max(0, (enabledRows.count - 1) / pageSize))
        filterRows()
    }

    private func filterRows() {
        matches = rows.filter { row in
            guard showingAllModels else { return row.visible }
            return row.entry.matches(filter.query)
                && (filter.connection.isEmpty || row.entry.model.provider == filter.connection)
                && (filter.lab.isEmpty || row.entry.lab == filter.lab)
                && (!filter.subscriptionsOnly || ["openai-codex", "claude-subscription", "xai"].contains(row.entry.model.provider))
        }
        page = min(page, max(0, (matches.count - 1) / pageSize))
    }

    private func connectionName(_ provider: String) -> String {
        switch provider {
        case "openai-codex": "ChatGPT subscription"
        case "openai": "OpenAI API key"
        case "claude-subscription": "Claude subscription"
        case "anthropic": "Claude API key"
        case "xai": "Grok subscription"
        case "xai-api": "xAI API key"
        case "openrouter": "OpenRouter"
        case "opencode-go": "OpenCode Go"
        default: agent.localServers.first { $0.id == provider }.map { "Local · \($0.name)" } ?? provider
        }
    }
}

/// Loading the full inventory is always an explicit user action, including when
/// the default chooser is open. Existing enabled model controls remain usable.
private struct SettingsAgentCatalogBrowseControls: View {
    @Bindable var agent: DefaultAgentSettingsModel
    let requested: Bool
    let includesAllModels: Bool
    let loading: Bool
    let error: String?
    var offersEnabledModels = false
    let setBrowsingAllModels: (Bool) -> Void

    private var availableProviders: [String] {
        agent.configuration.providers.filter { provider in
            agent.availableModelProviderIDs.contains(provider) || agent.localServers.contains { $0.id == provider }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if availableProviders.isEmpty {
                SettingsNote("Add an account in Settings → Subscriptions & API Keys to browse models.")
            } else {
                SettingsPicker("Provider", selection: Binding(get: { agent.browsingProvider }, set: {
                    agent.browsingProvider = $0
                    setBrowsingAllModels(true)
                }), options: availableProviders) { provider in
                    ProviderConnectionID.allCases.first { $0.id == provider }?.name ?? provider
                }
            }
            HStack(spacing: 8) {
                if requested {
                    Button("Refresh models") { agent.refreshCatalog() }.disabled(loading)
                    if offersEnabledModels { Button("Show enabled models") { setBrowsingAllModels(false) } }
                    if !includesAllModels {
                        if loading {
                            ProgressView().controlSize(.small)
                            Text("Loading models…").font(.settingsBody).foregroundStyle(WovenPalette.mutedForeground)
                        } else {
                            Button("Retry") { setBrowsingAllModels(true) }
                        }
                    }
                } else {
                    Button("Browse provider models") { setBrowsingAllModels(true) }.disabled(loading || availableProviders.isEmpty)
                }
            }.buttonStyle(SettingsQuietButtonStyle())
            if requested && !includesAllModels && !loading, let error {
                SettingsError(error)
            }
        }
    }
}

private struct SettingsAgentCatalogPageControls: View {
    let count: Int
    let pageSize: Int
    @Binding var page: Int
    var body: some View {
        HStack {
            Text("\(min(page * pageSize + 1, count))–\(min((page + 1) * pageSize, count)) of \(count) models")
                .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground).monospacedDigit()
            Spacer()
            if count > pageSize {
                Button("Previous") { page -= 1 }.disabled(page == 0)
                Button("Next") { page += 1 }.disabled((page + 1) * pageSize >= count)
            }
        }.buttonStyle(SettingsQuietButtonStyle())
    }
}

/// Created only when the user opens the selector. Search covers the entire index,
/// but the native list receives one bounded page and retains keyboard selection.
private struct SettingsAgentDefaultModelChooser: View {
    @Bindable var agent: DefaultAgentSettingsModel
    @Environment(\.dismiss) private var dismiss
    let index: SettingsAgentCatalogIndex
    let selection: String?
    let browsingAllModels: Bool
    let includesAllModels: Bool
    let loading: Bool
    let error: String?
    let setBrowsingAllModels: (Bool) -> Void
    let select: (String?) -> Void
    @State private var query = ""
    @State private var matches: [SettingsAgentCatalogIndex.Entry] = []
    @State private var page = 0
    @State private var selectedID: String?
    @State private var locatedInitialSelection = false
    private let pageSize = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Default model").font(.settingsSection)
            Button("Use first available model") { select(nil) }.buttonStyle(SettingsQuietButtonStyle())
            SettingsAgentCatalogBrowseControls(agent: agent,
                requested: browsingAllModels, includesAllModels: includesAllModels,
                loading: loading, error: error, offersEnabledModels: true, setBrowsingAllModels: setBrowsingAllModels)
            if browsingAllModels && includesAllModels {
                TextField("Find a model or provider", text: $query).quietTextInput()
            }
            if matches.isEmpty {
                Text(browsingAllModels && includesAllModels ? "No models match this search." : "No enabled models to display.")
                    .font(.settingsBody).foregroundStyle(WovenPalette.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                List(selection: $selectedID) {
                    ForEach(matches.dropFirst(page * pageSize).prefix(pageSize)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.model.name).font(.settingsBody)
                            Text(entry.model.providerName).font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                        }
                        .tag(entry.id)
                    }
                }
                .listStyle(.plain)
                .scrollIndicators(.never)
                .frame(height: 260)
            }
            SettingsAgentCatalogPageControls(count: matches.count, pageSize: pageSize, page: $page)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use model") { if let selectedID { select(selectedID) } }
                    .disabled(selectedID == nil || !matches.dropFirst(page * pageSize).prefix(pageSize).contains { $0.id == selectedID })
                    .keyboardShortcut(.defaultAction)
            }.buttonStyle(SettingsQuietButtonStyle())
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            selectedID = selection
            filterModels()
            locateInitialSelection()
        }
        .onChange(of: query) { _, _ in page = 0; filterModels() }
        .onChange(of: browsingAllModels) { _, _ in query = ""; page = 0; filterModels() }
        .onChange(of: index.source) { _, _ in filterModels(); locateInitialSelection() }
        .onExitCommand { dismiss() }
    }
    private func filterModels() {
        matches = index.entries.filter { $0.matches(query) }
        page = min(page, max(0, (matches.count - 1) / pageSize))
    }
    private func locateInitialSelection() {
        guard !locatedInitialSelection, query.isEmpty, selectedID == selection,
              let selectedID, let position = matches.firstIndex(where: { $0.id == selectedID }) else { return }
        page = position / pageSize
        locatedInitialSelection = true
    }
}
