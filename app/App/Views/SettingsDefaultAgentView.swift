import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct SettingsDefaultAgentView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var agent = DefaultAgentSettingsModel()
    @State private var openAIMethod = "openai-codex"
    @State private var keyDrafts: [String: String] = [:]
    @State private var modelSearch = ""
    @State private var answer = ""
    @State private var syncError: String?
    @State private var confirmingCredentialReset = false

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
                    Button("Reset workspace credentials") { confirmingCredentialReset = true }.disabled(agent.busy)
                }
            }.buttonStyle(SettingsQuietButtonStyle())
            modelsSection
        }
        .task { agent.changeScope(initialScope); agent.refresh(remote: remote) }
        .onDisappear { agent.cancel() }
        .confirmationDialog("Reset Default Agent credentials in this workspace?", isPresented: $confirmingCredentialReset) {
            Button("Reset credentials", role: .destructive) { agent.refresh(remote: remote, action: "reset") }
        } message: {
            Text("Independent workspace sign-ins will be removed. Shared keys and sign-ins from this Mac will be restored. Files and conversations are kept.")
        }
    }
    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Settings for", selection: Binding(get: { agent.scope }, set: { agent.changeScope($0); agent.refresh(remote: remote) })) {
                Text("All workspaces").tag("global")
                Text("Local agent workspace").tag("local")
                ForEach(model.remoteWorkspaces.workspaces) { workspace in Text(workspace.name).tag(workspace.id.uuidString.lowercased()) }
            }.frame(maxWidth: 440, alignment: .leading)
            if agent.scope != "global" {
                Toggle("Use settings from All workspaces", isOn: Binding(get: { agent.inherits }, set: { agent.setInherits($0) }))
                Text(agent.inherits ? "Providers, keys, search, and model preferences follow your global settings. Subscription sign-ins can also be connected in this workspace." : "This workspace has its own preferences. Saved API keys are reused unless replaced here.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Providers").font(.headline)
            Picker("OpenAI connection", selection: $openAIMethod) {
                Text("ChatGPT subscription").tag("openai-codex")
                Text("OpenAI API key").tag("openai")
            }.pickerStyle(.segmented).frame(maxWidth: 420)
            Text("Both OpenAI connections can be enabled at the same time.").font(.callout).foregroundStyle(.secondary)
            providerRow(openAIMethod, title: "OpenAI")
            providerRow("openrouter", title: "OpenRouter")
            providerRow("opencode-go", title: "OpenCode Go")
            providerRow("xai", title: "Grok subscription")
            signInSection
        }
    }
    @ViewBuilder private func providerRow(_ id: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(title, isOn: Binding(get: { agent.configuration.providers.contains(id) }, set: { enabled in
                    var config = agent.configuration; config.providers.removeAll { $0 == id }; if enabled { config.providers.append(id) }; agent.configuration = config
                })).disabled(!editable)
                Spacer()
                Text(agent.providers.first { $0.id == id }?.connected == true ? "Credentials present" : "Sign-in required").font(.callout).foregroundStyle(.secondary)
                if id == "openai-codex" || id == "xai" {
                    Button("Sign in") { agent.refresh(remote: remote, login: id) }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                    Button(remote == nil ? "Sign out" : "Use shared sign-in") { agent.signOut(id, remote: remote) }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                }
            }
            if id != "openai-codex" && id != "xai" { keyEntry(id) }
        }.padding(.vertical, 4)
    }
    private func keyEntry(_ id: String) -> some View {
        HStack {
            SecureField("API key", text: Binding(get: { keyDrafts[id] ?? "" }, set: { keyDrafts[id] = $0 }))
                .textFieldStyle(.roundedBorder).accessibilityLabel("\(id) API key")
            Button("Save key") {
                agent.saveKey(keyDrafts[id] ?? "", provider: id); keyDrafts[id] = nil
                agent.refresh(remote: remote); synchronize()
            }.disabled((keyDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Remove") { agent.saveKey("", provider: id); agent.refresh(remote: remote); synchronize() }
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable || agent.busy)
    }
    @ViewBuilder private var signInSection: some View {
        if let url = agent.signInURL {
            HStack {
                Link("Continue sign-in in browser", destination: url)
                if let code = agent.signInCode { Text(code).monospaced().textSelection(.enabled) }
            }
        }
        if let prompt = agent.prompt {
            Text(prompt).font(.callout)
            if agent.promptOptions.isEmpty {
                HStack { TextField("Authorization code or redirect URL", text: $answer).textFieldStyle(.roundedBorder); Button("Continue") { agent.respond(answer); answer = "" } }
            } else {
                HStack { ForEach(agent.promptOptions, id: \.id) { option in Button(option.label) { agent.respond(option.id) } } }
            }
        }
    }
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Web search").font(.headline)
            HStack { Text("Exa"); Spacer(); Text(agent.searchConfigured ? "Key configured" : "Add a key to enable search").font(.callout).foregroundStyle(.secondary) }
            keyEntry("exa")
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
                        Text(status.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(status.detail).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }
    }
}
