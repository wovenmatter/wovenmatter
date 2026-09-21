import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsConnectionsView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var openAIMethod = "openai-codex"
    @State private var keyDrafts: [String: String] = [:]
    @State private var answer = ""
    @State private var confirmingCredentialReset = false
    private var agent: DefaultAgentSettingsModel { model.connections }
    private var editable: Bool { !agent.inherits }
    private var remote: RemoteWorkspaceConfiguration? {
        model.remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == agent.scope }
    }
    var body: some View {
        SettingsPage(title: "Connections", detail: "Shared accounts for Default Agent, Usage, and Dictation.", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            Picker("Connections for", selection: Binding(get: { agent.scope }, set: { agent.changeScope($0); agent.refresh(remote: remote) })) {
                Text("Woven Matter · shared").tag("global")
                Text("Local workspace overrides").tag("local")
                ForEach(model.remoteWorkspaces.workspaces) { workspace in Text(workspace.name).tag(workspace.id.uuidString.lowercased()) }
            }
            if agent.scope != "global" {
                Toggle("Use global workspace defaults", isOn: Binding(get: { agent.inherits }, set: { agent.setInherits($0) }))
                Text("Dictation and app-wide Usage use the shared accounts. Workspace overrides apply to Default Agent.").font(.callout).foregroundStyle(.secondary)
            }
            connectionsSection
            searchSection
            SettingsCard(title: "Other usage accounts", detail: "These accounts remain owned by their independently installed harnesses.") {
                ForEach([ProviderKind.claude, .cursor]) { provider in
                    HStack {
                        Text(provider.displayName)
                        Spacer()
                        Button("Manage sign-in") { model.signInUsageProvider(provider) }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(model.signingInUsageProviders.contains(provider) || !model.isUsageProviderEnabled(provider))
                    }
                    if !model.isUsageProviderEnabled(provider) {
                        Text("Enable \(provider.displayName) tracking in Usage to manage its usage sign-in.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let notice = agent.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let error = agent.error { SettingsError(error) }
            HStack {
                Button("Refresh connections") { agent.refresh(remote: remote) }
                if remote != nil {
                    Button("Reset workspace credentials") { confirmingCredentialReset = true }.disabled(agent.busy)
                }
                if agent.busy { ProgressView().controlSize(.small); Button("Cancel") { agent.cancel() } }
            }.buttonStyle(SettingsQuietButtonStyle())
            Text("Subscription sign-ins and API keys remain separate. Disconnecting a shared account affects every feature using it. Disabling dictation or usage tracking keeps the account connected.").font(.callout).foregroundStyle(.secondary)
            LocalModelServerConnections()
        }
        .task { agent.changeScope(initialScope); agent.refresh(remote: remote) }
        .onDisappear { agent.cancel() }
        .confirmationDialog("Reset Default Agent credentials in this workspace?", isPresented: $confirmingCredentialReset) {
            Button("Reset credentials", role: .destructive) { agent.refresh(remote: remote, action: "reset") }
        } message: {
            Text("Independent workspace sign-ins will be removed. Shared keys and sign-ins from this Mac will be restored. Files and conversations are kept.")
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
                Text(title).font(.headline)
                Spacer()
                Text(agent.connectionLabel(id)).font(.callout).foregroundStyle(.secondary)
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
                .settingsInput().accessibilityLabel("\(id) API key")
            Button("Save key") {
                guard agent.saveKey(keyDrafts[id] ?? "", provider: id) else { return }
                keyDrafts[id] = nil
                agent.refresh(remote: remote); synchronize()
            }.disabled((keyDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Remove") { if agent.saveKey("", provider: id) { agent.refresh(remote: remote); synchronize() } }
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
                HStack { TextField("Authorization code or redirect URL", text: $answer).settingsInput(); Button("Continue") { agent.respond(answer); answer = "" } }
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
    private func synchronize() {
        Task {
            await DictationModel.shared.refreshAvailability()
            for workspace in model.remoteWorkspaces.workspaces {
                do { try await model.remoteWorkspaces.synchronizeDefaultAgent(workspace) }
                catch { agent.error = "\(workspace.name): \(error.localizedDescription)" }
            }
        }
    }
}

struct ConnectionsLink: View {
    var title = "Manage connections"
    var scope = "global"
    var body: some View {
        Button(title) {
            NotificationCenter.default.post(name: .init("wovenmatter.open-connections"), object: scope)
        }.buttonStyle(SettingsQuietButtonStyle())
    }
}
