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
    @State private var keyDrafts: [String: String] = [:]
    @State private var keyLabels: [String: String] = [:]
    @State private var expandedKeyFolds: [String: Bool] = [:]
    @State private var answer = ""
    @State private var confirmingCredentialReset = false
    @Environment(\.dashboardTheme) private var theme
    private var agent: DefaultAgentSettingsModel { model.connections }
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
        VStack(alignment: .leading, spacing: 2) {
            if embedded {
                connectionRows(focus)
            } else {
                // The guided setup window groups its rows on a surface; settings pages don't.
                VStack(alignment: .leading, spacing: 2) { connectionRows(focus) }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(theme.palette.themeWhisper)
                    .clipShape(DashboardShapes.card)
            }
            if focus == .providers, remote != nil {
                SettingsSummaryRow("Account recovery") {
                    SettingsRow(title: "Workspace credentials", detail: "Resets this workspace’s saved credentials and restores shared connections.") {
                        Button("Reset workspace credentials") { confirmingCredentialReset = true }
                            .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                    }
                }
            }
            if agent.signInProvider == nil, let notice = agent.notice { SettingsNote(notice) }
            if agent.signInProvider == nil, let error = agent.error { SettingsError(error) }
            if agent.busy && agent.signInProvider == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private func connectionRows(_ focus: ConnectionSettingsFocus) -> some View {
        if focus == .providers {
            providerRows
        } else {
            ForEach(ProviderConnectionID.searchProviders) { provider in searchRow(provider) }
        }
    }

    private var providerRows: some View {
        Group {
            providerRow("OpenAI", ids: ["openai-codex", "openai"]) {
                subscriptionContent("openai-codex", title: "ChatGPT subscription")
                apiKeyFold("openai", title: "Use an OpenAI API key")
            }
            providerRow("Anthropic", ids: ["claude-subscription", "anthropic"]) {
                subscriptionContent("claude-subscription", title: "Claude subscription")
                apiKeyFold("anthropic", title: "Use a Claude API key")
            }
            providerRow("Grok · xAI", ids: ["xai", "xai-api"]) {
                subscriptionContent("xai", title: "Grok subscription")
                apiKeyFold("xai-api", title: "Use an xAI API key")
            }
            providerRow("OpenRouter", ids: ["openrouter"]) { apiKeyContent("openrouter") }
            providerRow("OpenCode", ids: ["opencode-go"]) { apiKeyContent("opencode-go") }
        }
    }

    private func providerRow<Content: View>(_ title: String, ids: [String], @ViewBuilder content: () -> Content) -> some View {
        let accounts = ids.flatMap { agent.effectiveAccounts[$0] ?? [] }
        // A saved label is not proof of access: a shared Claude profile still needs sign-in here.
        let usable = ids.contains { agent.availableModelProviderIDs.contains($0) }
        return SettingsSummaryRow(
            title,
            value: accounts.isEmpty ? "Not connected" : accounts.map(\.label).joined(separator: " · "),
            tone: usable ? .good : accounts.isEmpty ? .neutral : .warning,
            content: content
        )
    }

    /// The selected provider is chosen on its own row, next to its key.
    private func searchRow(_ provider: ProviderConnectionID) -> some View {
        let hasKey = !(agent.effectiveAccounts[provider.id] ?? []).isEmpty
        let selected = agent.configuration.searchProvider == provider.id
        return HStack(alignment: .top, spacing: 12) {
            if embedded {
                Button {
                    var config = agent.configuration
                    config.searchProvider = provider.id
                    agent.configuration = config
                } label: {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.settingsText)
                        .foregroundStyle(selected ? DashboardPalette.primary : DashboardPalette.mutedForeground)
                        .frame(width: 20, height: SettingsMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(agent.inherits)
                .accessibilityLabel("Use \(provider.name) for web search")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            SettingsSummaryRow(
                provider.name,
                value: hasKey ? "Key saved" : "Not set",
                tone: hasKey ? .good : .neutral
            ) {
                apiKeyContent(provider.id)
            }
        }
    }

    private func apiKeyFold(_ id: String, title: String) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedKeyFolds[id] ?? !(agent.accounts[id] ?? []).isEmpty },
            set: { expandedKeyFolds[id] = $0 }
        )) {
            apiKeyContent(id).padding(.top, 4)
        } label: {
            Text(title).font(.settingsBody).foregroundStyle(DashboardPalette.mutedForeground)
        }
    }

    @ViewBuilder private func scopeNotes(_ id: String, accounts: [ProviderConnectionAccounts.Account], subscription: Bool) -> some View {
        if agent.scope != "global" {
            if accounts.isEmpty, let shared = agent.sharedAccounts[id], !shared.isEmpty {
                SettingsNote(id == "claude-subscription"
                    ? "Shared profile names · Claude sign-in is required on this machine."
                    : subscription ? "Using the shared Pi Durable account"
                    : remote == nil ? "Using shared Pi Durable accounts" : "Shared fallback accounts")
                ForEach(shared) { account in
                    Text(account.label).font(.settingsBody.weight(.medium))
                }
                if let onManageShared {
                    Button("Manage shared accounts", action: onManageShared).buttonStyle(SettingsQuietButtonStyle())
                }
            } else if !accounts.isEmpty {
                SettingsNote("Workspace accounts · shared accounts are used when these are removed.")
            }
        }
    }

    private func subscriptionContent(_ id: String, title: String) -> some View {
        let stored = agent.accounts[id] ?? []
        let accounts = stored.filter(\.isSelected) + stored.filter { !$0.isSelected }
        return VStack(alignment: .leading, spacing: 6) {
            scopeNotes(id, accounts: accounts, subscription: true)
            SettingsRow(title: title, detail: agent.connectionLabel(id)) {
                if accounts.isEmpty || remote != nil && id != "claude-subscription" {
                    Button(id == "claude-subscription" ? "Sign in with Claude" : "Sign in") {
                        if id == "claude-subscription" { agent.signInClaude(remote: remote) }
                        else { agent.refresh(remote: remote, login: id) }
                    }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                }
            }
            ForEach(accounts) { account in
                SettingsRow(title: account.label) {
                    Button("Reconnect") { Task { await agent.reconnectAccount(account.id, provider: id, remote: remote) } }
                    Button("Remove") { Task { await agent.removeAccount(account.id, provider: id, remote: remote) } }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
            }
            if id == "claude-subscription" {
                SettingsNote("Claude signs in on each machine. Only profile names are shared; Claude tokens are not synced.")
            }
            if remote != nil && ["openai-codex", "xai"].contains(id) {
                SettingsRow(title: "Shared sign-in", detail: "An independent workspace sign-in replaces the shared account.") {
                    Button("Use shared sign-in") { Task { await agent.signOut(id, remote: remote) } }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                }
            }
            signInStatus(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func apiKeyContent(_ id: String) -> some View {
        let stored = agent.accounts[id] ?? []
        let accounts = stored.filter(\.isSelected) + stored.filter { !$0.isSelected }
        return VStack(alignment: .leading, spacing: 6) {
            scopeNotes(id, accounts: accounts, subscription: false)
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.createdAt.map { "Added " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Existing connection")
                            .font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                        HStack {
                            Button("Use first") { Task { await agent.selectAccount(account.id, provider: id, remote: remote) } }.disabled(account.isSelected)
                            Button("Move up") { Task { await agent.moveAccount(account.id, provider: id, offset: -1) } }.disabled(account.isSelected || index <= 1)
                            Button("Move down") { Task { await agent.moveAccount(account.id, provider: id, offset: 1) } }.disabled(account.isSelected || index == accounts.count - 1)
                            Spacer()
                            Button("Remove") { Task { await agent.removeAccount(account.id, provider: id, remote: remote) } }
                        }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                    }
                } label: {
                    HStack {
                        Text(account.label)
                        Spacer()
                        Text(account.isSelected ? "Primary" : "Backup \(index)").font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                        Text("Credential saved").font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
            }
            if accounts.count < ProviderConnectionAccounts.limit {
                keyEntry(id)
            } else {
                Text("Four connections maximum. Remove one to add another.").font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
            }
            signInStatus(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func signInStatus(_ id: String) -> some View {
        if agent.signInProvider == id { signInSection }
        else { completedSignInSection(for: id) }
    }

    private func keyEntry(_ id: String) -> some View {
        HStack {
            if focus != .webSearch {
                TextField("Label (optional)", text: Binding(get: { keyLabels[id] ?? "" }, set: { keyLabels[id] = $0 })).dashboardInput().frame(maxWidth: 160)
            }
            SecureField("Add API key", text: Binding(get: { keyDrafts[id] ?? "" }, set: { keyDrafts[id] = $0 }))
                .dashboardInput().accessibilityLabel("\(id) API key")
            Button("Save key") {
                Task { @MainActor in
                    guard await agent.saveKeyConfirmed(keyDrafts[id] ?? "", provider: id, label: (keyLabels[id] ?? "").isEmpty ? nil : keyLabels[id]) else { return }
                    keyDrafts[id] = nil
                    keyLabels[id] = nil
                    if let onConnected, ProviderConnectionID(rawValue: id)?.isSearchProvider != true { onConnected(id) }
                    else { agent.refresh(remote: remote) }
                }
            }.disabled((keyDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
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
                    Text(url.absoluteString).font(.settingsSecondary).multilineTextAlignment(.leading)
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
                Text(prompt).font(.settingsBody)
                if agent.promptOptions.isEmpty {
                    HStack { TextField("Authorization code or redirect URL", text: $answer).dashboardInput(); Button("Continue") { agent.respond(answer); answer = "" } }
                } else {
                    HStack { ForEach(agent.promptOptions, id: \.id) { option in Button(option.label) { agent.respond(option.id) } } }
                }
            }
            if agent.error == nil, let notice = agent.notice { SettingsNote(notice) }
            if let error = agent.error { SettingsError(error) }
            if agent.busy {
                HStack { ProgressView().controlSize(.small); Text(agent.signInURL == nil ? "Preparing sign-in…" : "Waiting for sign-in…"); Button("Cancel") { agent.cancel() } }
            }
        }.buttonStyle(SettingsQuietButtonStyle())
    }
    @ViewBuilder
    private func completedSignInSection(for provider: String) -> some View {
        if let outcome = agent.signInOutcome, outcome.provider == provider {
            if let notice = outcome.notice { SettingsNote(notice) }
            if let error = outcome.error { SettingsError(error) }
        }
    }

}
