import SwiftUI
import AppKit
import WovenMatterClient
import WovenMatterCore

struct SettingsConnectionsView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var keyDrafts: [String: String] = [:]
    @State private var keyLabels: [String: String] = [:]
    @State private var answer = ""
    @State private var confirmingCredentialReset = false
    private var agent: DefaultAgentSettingsModel { model.connections }
    private var editable: Bool { !agent.inherits }
    private var remote: RemoteWorkspaceConfiguration? {
        model.remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == agent.scope }
    }
    var body: some View {
        SettingsPage(title: "Connections", detail: "Shared accounts for Built-in, Usage, and Dictation.", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            Picker("Connections for", selection: Binding(get: { agent.scope }, set: {
                keyDrafts.removeAll()
                answer = ""
                agent.changeScope($0)
                agent.refresh(remote: remote)
            })) {
                Text("Woven Matter · shared").tag("global")
                Text("Local workspace overrides").tag("local")
                ForEach(model.remoteWorkspaces.workspaces) { workspace in Text(workspace.name).tag(workspace.id.uuidString.lowercased()) }
            }
            if agent.scope != "global" {
                Toggle("Use global workspace defaults", isOn: Binding(get: { agent.inherits }, set: {
                    keyDrafts.removeAll()
                    agent.setInherits($0)
                    agent.refresh(remote: remote)
                }))
                Text("Dictation and app-wide Usage use the shared accounts. Workspace overrides apply to Built-in.").font(.callout).foregroundStyle(.secondary)
            }
            connectionsSection
            searchSection
            if agent.signInProvider == nil, let notice = agent.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if agent.signInProvider == nil, let error = agent.error { SettingsError(error) }
            HStack {
                Button("Refresh connections") { agent.refresh(remote: remote) }.disabled(agent.busy)
                if remote != nil {
                    Button("Reset workspace credentials") { confirmingCredentialReset = true }.disabled(agent.busy)
                }
                if agent.busy && agent.signInProvider == nil { ProgressView().controlSize(.small); Button("Cancel") { agent.cancel() } }
            }.buttonStyle(SettingsQuietButtonStyle())
            Text("Subscription sign-ins and API keys remain separate. Disconnecting a shared account affects every feature using it. Disabling dictation or usage tracking keeps the account connected.").font(.callout).foregroundStyle(.secondary)
            LocalModelServerConnections()
        }
        .task { agent.changeScope(initialScope); agent.refresh(remote: remote) }
        .onDisappear { agent.cancel() }
        .confirmationDialog("Reset Built-in credentials in this workspace?", isPresented: $confirmingCredentialReset) {
            Button("Reset credentials", role: .destructive) { agent.refresh(remote: remote, action: "reset") }
        } message: {
            Text("Encrypted workspace credentials will be reset and shared connections restored. Claude’s separate native sign-in, files, and conversations are kept.")
        }
    }
    private var connectionsSection: some View {
        SettingsCard(title: "Model providers", detail: "Connect accounts for Built-in and Usage. Choose a preferred account and arrange backups for sign-in or usage exhaustion.") {
            DisclosureGroup("OpenAI") {
                connectionGroup("openai-codex", title: "ChatGPT subscriptions", subscription: true)
                connectionGroup("openai", title: "API keys")
            }
            DisclosureGroup("Anthropic") {
                connectionGroup("claude-subscription", title: "Claude subscriptions", subscription: true)
                connectionGroup("anthropic", title: "API keys")
            }
            DisclosureGroup("Grok · xAI") {
                connectionGroup("xai", title: "Grok subscriptions", subscription: true)
                connectionGroup("xai-api", title: "xAI API keys")
            }
            DisclosureGroup("OpenRouter") { connectionGroup("openrouter", title: "API keys") }
            DisclosureGroup("OpenCode") { connectionGroup("opencode-go", title: "API keys") }
            DisclosureGroup("Cursor") {
                Text(agent.cursorAccountStatus).font(.callout).foregroundStyle(.secondary)
                Button("Refresh status") { Task { await agent.refreshCursorStatus() } }.buttonStyle(SettingsQuietButtonStyle())
                Text("Usage limits only. Not available to Built-in.").font(.callout).foregroundStyle(.secondary)
                Text("One account on this Mac. Signing in replaces the current account.").font(.caption).foregroundStyle(.secondary)
                Button("Sign in to Cursor") { agent.signInCursor() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(agent.busy || remote != nil)
                if agent.signInProvider == "cursor" { signInSection }
            }
        }
    }
    private func connectionGroup(_ id: String, title: String, subscription: Bool = false) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 10) {
                let stored = agent.accounts[id] ?? []
                let accounts = stored.filter(\.isSelected) + stored.filter { !$0.isSelected }
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(account.createdAt.map { "Added " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Existing connection")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Use first") { agent.selectAccount(account.id, provider: id, remote: remote) }.disabled(account.isSelected)
                                Button("Move up") { agent.moveAccount(account.id, provider: id, offset: -1) }.disabled(account.isSelected || index <= 1)
                                Button("Move down") { agent.moveAccount(account.id, provider: id, offset: 1) }.disabled(account.isSelected || index == accounts.count - 1)
                                if subscription { Button("Reconnect") { agent.reconnectAccount(account.id, provider: id, remote: remote) } }
                                Spacer()
                                Button("Remove") { agent.removeAccount(account.id, provider: id, remote: remote) }
                            }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable || agent.busy)
                        }
                    } label: {
                        HStack {
                            Text(account.label)
                            Spacer()
                            Text(account.isSelected ? "Preferred" : "Backup \(index)").font(.caption).foregroundStyle(.secondary)
                            Text(account.isSelected && subscription ? agent.connectionLabel(id) : "Credential saved").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if id == "claude-subscription", accounts.count < 4 {
                    Text(agent.connectionLabel(id)).font(.callout).foregroundStyle(.secondary)
                    Button(accounts.isEmpty ? "Sign in with Claude" : "Add Claude account") { agent.signInClaude(remote: remote) }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy || !editable)
                } else if accounts.count < 4 {
                    if subscription {
                        Button(accounts.isEmpty ? "Sign in" : "Add account") { agent.refresh(remote: remote, login: id) }
                            .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy || !editable)
                    } else { keyEntry(id) }
                } else {
                    Text("Four connections maximum. Remove one to add another.").font(.caption).foregroundStyle(.secondary)
                }
                if remote != nil && ["openai-codex", "xai"].contains(id) {
                    Text("This workspace can own one independent sign-in, tried before its shared accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use shared sign-in") { agent.signOut(id, remote: remote) }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy || !editable)
                }
                if agent.signInProvider == id { signInSection }
            }.padding(.vertical, 8)
        }
    }
    private func keyEntry(_ id: String) -> some View {
        HStack {
            TextField("Label (optional)", text: Binding(get: { keyLabels[id] ?? "" }, set: { keyLabels[id] = $0 })).settingsInput().frame(maxWidth: 180)
            SecureField("Add API key", text: Binding(get: { keyDrafts[id] ?? "" }, set: { keyDrafts[id] = $0 }))
                .settingsInput().accessibilityLabel("\(id) API key")
            Button("Save key") {
                guard agent.saveKey(keyDrafts[id] ?? "", provider: id, label: (keyLabels[id] ?? "").isEmpty ? nil : keyLabels[id]) else { return }
                keyDrafts[id] = nil
                keyLabels[id] = nil
                agent.refresh(remote: remote)
            }.disabled((keyDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable || agent.busy)
    }
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = agent.signInURL {
                Link("Open sign-in page", destination: url)
                Text(url.absoluteString).font(.caption).textSelection(.enabled)
                if let code = agent.signInCode {
                    HStack {
                        Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Button("Copy code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                    }
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
            if let notice = agent.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let error = agent.error { SettingsError(error) }
            if agent.busy {
                HStack { ProgressView().controlSize(.small); Text(agent.signInURL == nil ? "Preparing sign-in…" : "Waiting for sign-in…"); Button("Cancel") { agent.cancel() } }
            }
        }.buttonStyle(SettingsQuietButtonStyle())
    }
    private var searchSection: some View {
        SettingsCard(title: "Web search") {
            DisclosureGroup("Exa") { connectionGroup("exa", title: "API keys") }
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
