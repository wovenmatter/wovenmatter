import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct SettingsDefaultAgentView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var reservesRailControlSpace = false
    let onBack: () -> Void
    private var agent: DefaultAgentSettingsModel { model.connections }
    @State private var syncError: String?
    @State private var browsingAllModels = false

    private var remote: RemoteWorkspaceConfiguration? {
        model.remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == agent.scope }
    }
    private var editable: Bool { !agent.inherits }
    var body: some View {
        SettingsPage(title: "Built-in Agent", detail: "A built-in agent for every workspace.", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            scopeSection
            connectionsSection
            searchSection
            if let notice = agent.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let error = agent.error ?? syncError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Refresh connections") { agent.refresh(remote: remote) }.disabled(agent.busy)
                    Button("Apply to workspaces") { synchronize() }
                    if agent.busy { ProgressView().controlSize(.small); Button("Cancel") { agent.cancel() } }
                }
                if remote != nil {
                    ConnectionsLink(title: "Manage workspace connections", scope: agent.scope)
                }
            }.buttonStyle(SettingsQuietButtonStyle())
            SettingsAgentModelsView(agent: agent, editable: editable,
                                    browsingAllModels: browsingAllModels, setBrowsingAllModels: showCatalog)
        }
        .task { selectScope(initialScope) }
        .onChange(of: agent.scope) { _, _ in browsingAllModels = false }
        .onDisappear { agent.cancel() }
    }
    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Settings for", selection: Binding(get: { agent.scope }, set: { selectScope($0) })) {
                Text("All workspaces").tag("global")
                Text("Local agent workspace").tag("local")
                ForEach(model.remoteWorkspaces.workspaces) { workspace in Text(workspace.name).tag(workspace.id.uuidString.lowercased()) }
            }.frame(maxWidth: 440, alignment: .leading)
            if agent.scope != "global" {
                Toggle("Use settings from All workspaces", isOn: Binding(get: { agent.inherits }, set: {
                    agent.setInherits($0)
                    agent.loadCatalog(remote: remote, includeAllModels: browsingAllModels)
                }))
                Text(agent.inherits ? "Providers, keys, search, and model preferences follow your global settings. Subscription sign-ins can also be connected in this workspace." : "This workspace has its own preferences. Saved API keys are reused unless replaced here.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var connectionsSection: some View {
        SettingsCard(title: "Providers") {
            ForEach(ProviderConnectionID.allCases.filter { $0 != .exa }) { provider in
                HStack {
                    Toggle(provider.name, isOn: Binding(get: { agent.configuration.providers.contains(provider.id) }, set: { enabled in
                        var config = agent.configuration
                        config.providers.removeAll { $0 == provider.id }
                        if enabled { config.providers.append(provider.id) }
                        agent.configuration = config
                        agent.loadCatalog(remote: remote, includeAllModels: browsingAllModels)
                    })).disabled(!editable)
                    Spacer()
                    ConnectionsLink(title: agent.connectionLabel(provider.id), scope: agent.scope)
                }
            }
            ForEach(agent.localServers) { server in
                HStack {
                    Toggle(server.name, isOn: Binding(get: { agent.configuration.providers.contains(server.id) }, set: { enabled in
                        var config = agent.configuration; config.providers.removeAll { $0 == server.id }
                        if enabled { config.providers.append(server.id) }; agent.configuration = config
                        agent.loadCatalog(remote: remote, includeAllModels: browsingAllModels)
                    })).disabled(!editable)
                    Spacer()
                    ConnectionsLink(title: "Manage server")
                }
            }
        }
    }
    private var searchSection: some View {
        SettingsCard(title: "Web search") {
            HStack { Text("Exa"); Spacer(); ConnectionsLink(title: agent.searchConfigured ? "Key configured" : "Connect Exa", scope: agent.scope) }
        }
    }
    private func selectScope(_ scope: String) {
        browsingAllModels = false
        agent.changeScope(scope)
        agent.loadCatalog(remote: remote, includeAllModels: false)
    }
    private func showCatalog(_ includeAllModels: Bool) {
        browsingAllModels = includeAllModels
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

private struct SettingsAgentModelsView: View {
    let agent: DefaultAgentSettingsModel
    let editable: Bool
    let browsingAllModels: Bool
    let setBrowsingAllModels: (Bool) -> Void
    @State private var index = SettingsAgentCatalogIndex()
    @State private var filter = Filter()
    @State private var rows: [Row] = []
    @State private var matches: [Row] = []
    @State private var page = 0
    @State private var choosingDefault = false
    @State private var fallbackPage = 0
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
    private var pageRows: ArraySlice<Row> {
        matches.dropFirst(page * pageSize).prefix(pageSize)
    }
    private var defaultLabel: String {
        guard let id = agent.configuration.defaultModel else { return "First available model" }
        return index.byID[id].map { "\($0.model.name) · \($0.model.providerName)" } ?? id
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text(showingAllModels ? "Models" : "Enabled models").font(.headline)
            HStack {
                Text("Default model")
                Button { choosingDefault = true } label: {
                    HStack(spacing: 8) {
                        Text(defaultLabel).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!editable)
                .accessibilityLabel("Choose default model")
                .accessibilityValue(defaultLabel)
                .popover(isPresented: $choosingDefault, arrowEdge: .bottom) {
                    SettingsAgentDefaultModelChooser(
                        index: index, selection: agent.configuration.defaultModel,
                        browsingAllModels: browsingAllModels, includesAllModels: agent.catalogIncludesAllModels,
                        loading: agent.busy, error: agent.error, setBrowsingAllModels: setBrowsingAllModels
                    ) { id in
                        var config = agent.configuration
                        config.defaultModel = id
                        agent.configuration = config
                        choosingDefault = false
                    }
                }
            }
            Text("Fallbacks run in the numbered order when a connection loses sign-in or available usage. Switching updates the model selector and shows a notification.").font(.callout).foregroundStyle(.secondary)
            if agent.configuration.fallbackModels.count > pageSize {
                SettingsAgentCatalogPageControls(count: agent.configuration.fallbackModels.count, pageSize: pageSize, page: $fallbackPage)
            }
            ForEach(agent.configuration.fallbackModels.dropFirst(fallbackPage * pageSize).prefix(pageSize), id: \.self) { id in
                HStack {
                    Text(index.byID[id].map { "\($0.model.name) · \($0.model.providerName)" } ?? id).font(.callout)
                    Spacer()
                    Button("Earlier") { agent.moveFallback(id, by: -1) }
                    Button("Later") { agent.moveFallback(id, by: 1) }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable)
            }
            Text(showingAllModels
                 ? "Your default model is always available in the composer. Turn on any other models you want to include."
                 : "Your default model is always available in the composer. Browse all models to add more.")
                .font(.callout).foregroundStyle(.secondary)
            SettingsAgentCatalogBrowseControls(
                requested: browsingAllModels, includesAllModels: agent.catalogIncludesAllModels,
                loading: agent.busy, error: agent.error, setBrowsingAllModels: setBrowsingAllModels)
            if showingAllModels {
                TextField("Find a model or provider", text: $filter.query).textFieldStyle(.roundedBorder)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { modelFilters }
                    VStack(alignment: .leading, spacing: 8) { modelFilters }
                }
            }
            if matches.isEmpty {
                Text(showingAllModels ? "No models match these filters." : "No enabled models to display.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                SettingsAgentCatalogPageControls(count: matches.count, pageSize: pageSize, page: $page)
                LazyVStack(spacing: 8) {
                    ForEach(pageRows) { row in modelRow(row) }
                }
                if matches.count > pageSize {
                    SettingsAgentCatalogPageControls(count: matches.count, pageSize: pageSize, page: $page)
                }
            }
        }
        .onChange(of: inputs, initial: true) { old, value in updatePresentation(from: old, to: value) }
        .onChange(of: filter) { _, _ in page = 0; filterRows() }
        .onChange(of: browsingAllModels) { _, _ in filter = Filter(); page = 0; filterRows() }
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
        if old.scope != value.scope { page = 0; fallbackPage = 0; choosingDefault = false }
        fallbackPage = min(fallbackPage, max(0, (value.configuration.fallbackModels.count - 1) / pageSize))
        filterRows()
    }

    @ViewBuilder private var modelFilters: some View {
        Picker("Connection", selection: $filter.connection) {
            Text("All connection types").tag("")
            ForEach(index.providers, id: \.self) { provider in Text(connectionName(provider)).tag(provider) }
        }
        Picker("Lab", selection: $filter.lab) {
            Text("All labs").tag("")
            ForEach(index.labs, id: \.self) { lab in Text(lab).tag(lab) }
        }
        Toggle("Subscriptions only", isOn: $filter.subscriptionsOnly).fixedSize()
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
    private func modelRow(_ row: Row) -> some View {
        let item = row.entry.model
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { row.visible }, set: { agent.setVisible(item.id, visible: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.callout)
                    Text(row.isDefault ? "\(item.providerName) · Default" : item.providerName).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(row.isDefault)
            Spacer(minLength: 8)
            Toggle(row.fallback.map { "Fallback \($0 + 1)" } ?? "Fallback", isOn: Binding(get: { row.fallback != nil }, set: { agent.setFallback(item.id, enabled: $0) })).fixedSize().disabled(!row.visible)
            Button { agent.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Move \(item.name) earlier").disabled(!row.canMoveEarlier)
            Button { agent.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Move \(item.name) later").disabled(!row.canMoveLater)
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable)
    }
}

/// Loading the full inventory is always an explicit user action, including when
/// the default chooser is open. Existing enabled model controls remain usable.
private struct SettingsAgentCatalogBrowseControls: View {
    let requested: Bool
    let includesAllModels: Bool
    let loading: Bool
    let error: String?
    let setBrowsingAllModels: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if requested {
                    Button("Show enabled models") { setBrowsingAllModels(false) }
                    if !includesAllModels {
                        if loading {
                            ProgressView().controlSize(.small)
                            Text("Loading models…").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Button("Retry") { setBrowsingAllModels(true) }
                        }
                    }
                } else {
                    Button("Browse all models") { setBrowsingAllModels(true) }.disabled(loading)
                }
            }.buttonStyle(SettingsQuietButtonStyle())
            if requested && !includesAllModels && !loading, let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
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
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
            Text("Default model").font(.headline)
            Button("Use first available model") { select(nil) }.buttonStyle(SettingsQuietButtonStyle())
            SettingsAgentCatalogBrowseControls(
                requested: browsingAllModels, includesAllModels: includesAllModels,
                loading: loading, error: error, setBrowsingAllModels: setBrowsingAllModels)
            if browsingAllModels && includesAllModels {
                TextField("Find a model or provider", text: $query).textFieldStyle(.roundedBorder)
            }
            if matches.isEmpty {
                Text(browsingAllModels && includesAllModels ? "No models match this search." : "No enabled models to display.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                List(selection: $selectedID) {
                    ForEach(matches.dropFirst(page * pageSize).prefix(pageSize)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.model.name).font(.callout)
                            Text(entry.model.providerName).font(.caption).foregroundStyle(.secondary)
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


struct SettingsSignInStatusCard: View {
    let statuses: [AgentSignInStatus]
    let checking: Bool
    let error: String?
    var scope = "global"
    let refresh: () -> Void
    var body: some View {
        SettingsCard(title: "Sign-in status", detail: "Check Built-in connections and independently installed harnesses.") {
            HStack {
                Button(checking ? "Checking sign-in status…" : "Refresh sign-in status", action: refresh)
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
            if let error { SettingsError(error) }
            ForEach(statuses) { status in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(status.name).font(.callout)
                        Spacer()
                        if ProviderConnectionID(rawValue: status.id) != nil || status.id.hasPrefix("local-server-") {
                            ConnectionsLink(title: status.label, scope: scope)
                        } else { Text(status.label).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(status.detail).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }
    }
}
