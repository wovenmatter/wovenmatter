import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct SettingsDefaultAgentView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var agent = DefaultAgentSettingsModel()
    @State private var modelSearch = ""
    @State private var syncError: String?

    private var remote: RemoteWorkspaceConfiguration? {
        model.remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == agent.scope }
    }
    private var editable: Bool { !agent.inherits }
    private var visibleCatalog: [DefaultAgentSettingsModel.Model] {
        let all = agent.orderedModels + agent.catalog.filter { candidate in !agent.orderedModels.contains { $0.id == candidate.id } }
        return modelSearch.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(modelSearch) || $0.providerName.localizedCaseInsensitiveContains(modelSearch) }
    }
    var body: some View {
        SettingsPage(title: "Default Agent", detail: "A built-in agent for every workspace.", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
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
            modelsSection
        }
        .task { agent.changeScope(initialScope); agent.refresh(remote: remote) }
        .onDisappear { agent.cancel() }
    }
    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Settings for", selection: Binding(get: { agent.scope }, set: { agent.changeScope($0); agent.refresh(remote: remote) })) {
                Text("All workspaces").tag("global")
                Text("Local agent workspace").tag("local")
                ForEach(model.remoteWorkspaces.workspaces) { workspace in Text(workspace.name).tag(workspace.id.uuidString.lowercased()) }
            }.frame(maxWidth: 440, alignment: .leading)
            if agent.scope != "global" {
                Toggle("Use settings from All workspaces", isOn: Binding(get: { agent.inherits }, set: {
                    agent.setInherits($0)
                    agent.refresh(remote: remote)
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
                        agent.refresh(remote: remote)
                    })).disabled(!editable)
                    Spacer()
                    ConnectionsLink(title: agent.connectionLabel(provider.id), scope: agent.scope)
                }
            }
            ForEach(LocalModelServerStore.servers) { server in
                HStack {
                    Toggle(server.name, isOn: Binding(get: { agent.configuration.providers.contains(server.id) }, set: { enabled in
                        var config = agent.configuration; config.providers.removeAll { $0 == server.id }
                        if enabled { config.providers.append(server.id) }; agent.configuration = config
                        agent.refresh(remote: remote)
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
    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models").font(.headline)
            Picker("Default model", selection: Binding(get: { agent.configuration.defaultModel ?? "" }, set: { var config = agent.configuration; config.defaultModel = $0.isEmpty ? nil : $0; agent.configuration = config })) {
                Text("First available model").tag("")
                ForEach(agent.orderedModels) { item in Text("\(item.name) · \(item.providerName)").tag(item.id) }
            }.disabled(!editable)
            Text("Fallbacks run in the numbered order when a connection loses sign-in or available usage. Switching updates the model selector and shows a notification.").font(.callout).foregroundStyle(.secondary)
            ForEach(agent.configuration.fallbackModels, id: \.self) { id in
                HStack {
                    Text(agent.catalog.first { $0.id == id }.map { "\($0.name) · \($0.providerName)" } ?? id).font(.callout)
                    Spacer()
                    Button("Earlier") { agent.moveFallback(id, by: -1) }
                    Button("Later") { agent.moveFallback(id, by: 1) }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable)
            }
            TextField("Find a model or provider", text: $modelSearch).textFieldStyle(.roundedBorder)
            LazyVStack(spacing: 8) {
                ForEach(visibleCatalog) { item in modelRow(item) }
            }
        }
    }
    private func modelRow(_ item: DefaultAgentSettingsModel.Model) -> some View {
        let visible = agent.configuration.models.isEmpty || agent.configuration.models.contains(item.id)
        let fallback = agent.configuration.fallbackModels.firstIndex(of: item.id)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { visible }, set: { agent.setVisible(item.id, visible: $0) })) {
                VStack(alignment: .leading, spacing: 2) { Text(item.name).font(.callout); Text(item.providerName).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Toggle(fallback.map { "Fallback \($0 + 1)" } ?? "Fallback", isOn: Binding(get: { fallback != nil }, set: { agent.setFallback(item.id, enabled: $0) })).fixedSize().disabled(!visible)
            Button { agent.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Move \(item.name) earlier")
            Button { agent.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Move \(item.name) later")
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable)
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


struct SettingsSignInStatusCard: View {
    let statuses: [AgentSignInStatus]
    let checking: Bool
    let error: String?
    var scope = "global"
    let refresh: () -> Void
    var body: some View {
        SettingsCard(title: "Sign-in status", detail: "Check Default Agent connections and independently installed harnesses.") {
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
