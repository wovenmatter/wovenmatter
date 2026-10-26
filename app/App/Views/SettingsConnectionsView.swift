import SwiftUI
import AppKit
import WovenMatterClient
import WovenMatterCore

enum ConnectionSettingsFocus {
    case providers, webSearch

    var title: String {
        switch self {
        case .providers: "Connect Model Providers"
        case .webSearch: "Add Web Search"
        }
    }

    var detail: String {
        switch self {
        case .providers: "Sign in or add API keys for one or more providers."
        case .webSearch: "Add an Exa, Brave, or Firecrawl API key so Pi Durable can search the web."
        }
    }
}

struct SettingsConnectionsView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var focus: ConnectionSettingsFocus = .providers
    var embedded = false
    var onConnected: ((String) -> Void)?
    var onManageShared: (() -> Void)?
    let onBack: () -> Void
    @State private var keyDrafts: [String: String] = [:]
    @State private var keyLabels: [String: String] = [:]
    @State private var answer = ""
    @State private var confirmingCredentialReset = false
    @Environment(\.dashboardTheme) private var theme
    private var agent: DefaultAgentSettingsModel { model.connections }
    private var editable: Bool { true }
    private var remote: RemoteWorkspaceConfiguration? {
        model.remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == agent.scope }
    }
    var body: some View {
        focusedContent(focus)
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .task { if !embedded { agent.changeScope(initialScope) }; agent.loadAccounts() }
        .onDisappear { if !embedded { agent.cancel() } }
        .onChange(of: agent.signInOutcome) { _, outcome in
            guard focus == .providers, let outcome, outcome.error == nil,
                  outcome.notice?.hasPrefix("Connected.") == true else { return }
            onConnected?(outcome.provider)
        }
        .confirmationDialog("Reset Pi Durable credentials in this workspace?", isPresented: $confirmingCredentialReset) {
            Button("Reset credentials", role: .destructive) { agent.refresh(remote: remote, action: "reset") }
        } message: {
            Text("Encrypted workspace credentials will be reset and shared connections restored. Claude’s separate native sign-in, files, and conversations are kept.")
        }
    }

    private func focusedContent(_ focus: ConnectionSettingsFocus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if focus == .providers {
                VStack(spacing: 0) { providerRows }
                    .background(theme.palette.themeWhisper)
                    .clipShape(DashboardShapes.card)
            } else {
                VStack(spacing: 0) {
                    ForEach(ProviderConnectionID.searchProviders) { provider in
                        if provider != .exa { providerDivider }
                        providerRow(provider.name, detail: "API keys") {
                            connectionContent(provider.id).padding(.leading, 12)
                        }
                    }
                }
                .background(theme.palette.themeWhisper)
                .clipShape(DashboardShapes.card)
            }
            if focus == .providers, remote != nil {
                DisclosureGroup("Workspace account recovery") {
                    Button("Reset workspace credentials") { confirmingCredentialReset = true }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                }
            }
            if agent.signInProvider == nil, let notice = agent.notice { SettingsNote(notice) }
            if agent.signInProvider == nil, let error = agent.error { SettingsError(error) }
            if agent.busy && agent.signInProvider == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var providerRows: some View {
        Group {
            providerRow("OpenAI", detail: "ChatGPT subscriptions or API keys") {
                connectionGroup("openai-codex", title: "ChatGPT subscriptions", subscription: true)
                connectionGroup("openai", title: "API keys")
            }
            providerDivider
            providerRow("Anthropic", detail: "Claude subscriptions or API keys") {
                connectionGroup("claude-subscription", title: "Claude subscriptions", subscription: true)
                connectionGroup("anthropic", title: "API keys")
            }
            providerDivider
            providerRow("Grok · xAI", detail: "Grok subscriptions or xAI API keys") {
                connectionGroup("xai", title: "Grok subscriptions", subscription: true)
                connectionGroup("xai-api", title: "xAI API keys")
            }
            providerDivider
            providerRow("OpenRouter", detail: "API keys") { connectionContent("openrouter").padding(.leading, 12) }
            providerDivider
            providerRow("OpenCode", detail: "API keys") { connectionContent("opencode-go").padding(.leading, 12) }
        }
    }

    @ViewBuilder private var providerDivider: some View {
        Rectangle().fill(theme.palette.border).frame(height: 1).padding(.horizontal, 16)
    }

    private func providerRow<Content: View>(_ title: String, detail: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(content: content) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(providerSummary(title) ?? detail).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
            }.frame(minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    private func providerSummary(_ title: String) -> String? {
        let ids: [String]
        switch title {
        case "OpenAI": ids = ["openai-codex", "openai"]
        case "Anthropic": ids = ["claude-subscription", "anthropic"]
        case "Grok · xAI": ids = ["xai", "xai-api"]
        case "OpenRouter": ids = ["openrouter"]
        case "Exa search": ids = ["exa"]
        case "Brave Search": ids = ["brave"]
        case "Firecrawl": ids = ["firecrawl"]
        default: ids = ["opencode-go"]
        }
        let accounts = ids.flatMap { agent.effectiveAccounts[$0] ?? [] }
        return accounts.isEmpty ? nil : accounts.map(\.label).joined(separator: " · ")
    }
    private func connectionGroup(_ id: String, title: String, subscription: Bool = false) -> some View {
        DisclosureGroup(title) {
            connectionContent(id, subscription: subscription)
        }.padding(.leading, 12)
    }
    private func connectionContent(_ id: String, subscription: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let stored = agent.accounts[id] ?? []
            let accounts = stored.filter(\.isSelected) + stored.filter { !$0.isSelected }
            if agent.scope != "global" {
                if accounts.isEmpty, let shared = agent.sharedAccounts[id], !shared.isEmpty {
                    SettingsNote(id == "claude-subscription"
                        ? "Shared profile names · Claude sign-in is required on this machine."
                        : remote == nil ? "Using shared Pi Durable accounts" : "Shared fallback accounts")
                    ForEach(shared) { account in
                        Text(account.label).font(.system(size: 12.5, weight: .medium))
                    }
                    if let onManageShared {
                        Button("Manage shared accounts", action: onManageShared).buttonStyle(SettingsQuietButtonStyle())
                    }
                } else if !accounts.isEmpty {
                    SettingsNote("Workspace accounts · shared accounts are used when these are removed.")
                }
            }
            if id == "claude-subscription" {
                SettingsNote("Claude signs in on each machine. Only profile names are shared; Claude tokens are not synced.")
            }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.createdAt.map { "Added " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Existing connection")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Use first") { Task { await agent.selectAccount(account.id, provider: id, remote: remote) } }.disabled(account.isSelected)
                            Button("Move up") { Task { await agent.moveAccount(account.id, provider: id, offset: -1) } }.disabled(account.isSelected || index <= 1)
                            Button("Move down") { Task { await agent.moveAccount(account.id, provider: id, offset: 1) } }.disabled(account.isSelected || index == accounts.count - 1)
                            if subscription { Button("Reconnect") { Task { await agent.reconnectAccount(account.id, provider: id, remote: remote) } } }
                            Spacer()
                            Button("Remove") { Task { await agent.removeAccount(account.id, provider: id, remote: remote) } }
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
                Button("Use shared sign-in") { Task { await agent.signOut(id, remote: remote) } }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy || !editable)
            }
            if agent.signInProvider == id { signInSection }
            else { completedSignInSection(for: id) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.leading, 12)
    }
    private func keyEntry(_ id: String) -> some View {
        HStack {
            if focus != .webSearch {
                TextField("Label (optional)", text: Binding(get: { keyLabels[id] ?? "" }, set: { keyLabels[id] = $0 })).settingsInput().frame(maxWidth: 180)
            }
            SecureField("Add API key", text: Binding(get: { keyDrafts[id] ?? "" }, set: { keyDrafts[id] = $0 }))
                .settingsInput().accessibilityLabel("\(id) API key")
            Button("Save key") {
                Task { @MainActor in
                    guard await agent.saveKeyConfirmed(keyDrafts[id] ?? "", provider: id, label: (keyLabels[id] ?? "").isEmpty ? nil : keyLabels[id]) else { return }
                    keyDrafts[id] = nil
                    keyLabels[id] = nil
                    if let onConnected, ProviderConnectionID(rawValue: id)?.isSearchProvider != true { onConnected(id) }
                    else { agent.refresh(remote: remote) }
                }
            }.disabled((keyDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(!editable || agent.busy)
    }
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = agent.signInURL {
                HStack {
                    Link("Open sign-in page", destination: url)
                        .foregroundStyle(DashboardPalette.success)
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Link(destination: url) {
                    Text(url.absoluteString).font(.caption).multilineTextAlignment(.leading)
                }
                .foregroundStyle(DashboardPalette.success)
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
            if agent.error == nil, let notice = agent.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let error = agent.error { SettingsError(error) }
            if agent.busy {
                HStack { ProgressView().controlSize(.small); Text(agent.signInURL == nil ? "Preparing sign-in…" : "Waiting for sign-in…"); Button("Cancel") { agent.cancel() } }
            }
        }.buttonStyle(SettingsQuietButtonStyle())
    }
    @ViewBuilder
    private func completedSignInSection(for provider: String) -> some View {
        if let outcome = agent.signInOutcome, outcome.provider == provider {
            if let notice = outcome.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let error = outcome.error { SettingsError(error) }
        }
    }

}

struct ConnectionsLink: View {
    var title = "Manage accounts"
    var scope = "global"
    var body: some View {
        Button(title) {
            NotificationCenter.default.post(name: .init("wovenmatter.open-connections"), object: scope)
        }.buttonStyle(SettingsQuietButtonStyle())
    }
}
