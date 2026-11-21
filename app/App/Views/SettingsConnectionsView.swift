import SwiftUI
import AppKit

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
    /// The machine whose accounts the rows show and act on; nil is this Mac.
    var machineID: String? = nil
    var initialScope = "global"
    var focus: ConnectionSettingsFocus = .providers
    var embedded = false
    var onConnected: ((String) -> Void)?
    @State private var keyDrafts: [String: String] = [:]
    @State private var expandedKeyFolds: [String: Bool] = [:]
    @State private var answer = ""
    @Environment(\.wovenTheme) private var theme
    private var agent: AgentSettingsStore { model.connections }
    private var target: String? { machineID ?? model.thisMachineID }
    private var connections: MachineProviderConnections { agent.connections(on: target) }
    /// A sign-in in progress on this page's machine.
    private var signInProvider: String? { agent.signInMachineID == target ? agent.signInProvider : nil }

    var body: some View {
        focusedContent(focus)
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .task(id: target) { if !embedded { agent.changeScope(initialScope) }; agent.loadAccounts(on: target) }
        .onDisappear { if !embedded { agent.cancel() } }
        // A key or answer typed for one machine is never saved to another.
        .onChange(of: target) { _, _ in keyDrafts = [:]; expandedKeyFolds = [:]; answer = "" }
        .onChange(of: agent.signInOutcome) { _, outcome in
            guard focus == .providers, let outcome, outcome.error == nil,
                  outcome.notice?.hasPrefix("Connected.") == true else { return }
            onConnected?(outcome.provider)
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
                    .clipShape(DesktopShapes.card)
            }
            if signInProvider == nil, let notice = agent.notice { SettingsNote(notice) }
            if signInProvider == nil, let error = agent.error { SettingsError(error) }
            if agent.busy && signInProvider == nil {
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
        let accounts = ids.flatMap { connections.accounts[$0] ?? [] }
        // A saved label is not proof of access: a Claude profile still needs its native sign-in.
        let usable = ids.contains { connections.availableModelProviderIDs.contains($0) }
        return SettingsSummaryRow(
            title,
            value: accounts.isEmpty ? "Not connected" : accounts.map(\.label).joined(separator: " · "),
            tone: usable ? .good : accounts.isEmpty ? .neutral : .warning,
            content: content
        )
    }

    /// The selected provider is chosen on its own row, next to its key.
    private func searchRow(_ provider: ProviderConnectionID) -> some View {
        let hasKey = !(connections.accounts[provider.id] ?? []).isEmpty
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
                        .foregroundStyle(selected ? WovenPalette.primary : WovenPalette.mutedForeground)
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
            get: { expandedKeyFolds[id] ?? !(connections.accounts[id] ?? []).isEmpty },
            set: { expandedKeyFolds[id] = $0 }
        )) {
            apiKeyContent(id).padding(.top, 4)
        } label: {
            Text(title).font(.settingsBody).foregroundStyle(WovenPalette.mutedForeground)
        }
    }

    private func subscriptionContent(_ id: String, title: String) -> some View {
        let stored = connections.accounts[id] ?? []
        let accounts = stored.filter(\.isSelected) + stored.filter { !$0.isSelected }
        return VStack(alignment: .leading, spacing: 6) {
            SettingsRow(title: title, detail: connections.connectionLabel(id)) {
                if accounts.isEmpty {
                    Button(id == "claude-subscription" ? "Sign in with Claude" : "Sign in") { agent.signIn(id, on: target) }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                }
            }
            ForEach(accounts) { account in
                SettingsRow(title: account.label) {
                    Button("Reconnect") { Task { await agent.reconnectAccount(account.id, provider: id, on: target) } }
                    Button("Remove") { Task { await agent.removeAccount(account.id, provider: id, on: target) } }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
            }
            if id == "claude-subscription" {
                SettingsNote("Claude signs in on each machine.")
            }
            signInStatus(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each provider keeps one key: Remove it to add another.
    private func apiKeyContent(_ id: String) -> some View {
        let accounts = connections.accounts[id] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(accounts) { account in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.createdAt.map { "Added " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Existing connection")
                            .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                        HStack {
                            Spacer()
                            Button("Remove") { Task { await agent.removeAccount(account.id, provider: id, on: target) } }
                        }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
                    }
                } label: {
                    HStack {
                        Text(account.label)
                        Spacer()
                        Text("Credential saved").font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                    }
                }
            }
            if accounts.isEmpty {
                keyEntry(id)
            }
            signInStatus(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func signInStatus(_ id: String) -> some View {
        if signInProvider == id { signInSection }
        else { completedSignInSection(for: id) }
    }

    private func keyEntry(_ id: String) -> some View {
        HStack {
            SecureField("Add API key", text: Binding(get: { keyDrafts[id] ?? "" }, set: { keyDrafts[id] = $0 }))
                .wovenInput().accessibilityLabel("\(id) API key")
            Button("Save key") {
                Task { @MainActor in
                    guard await agent.saveKey(keyDrafts[id] ?? "", provider: id, on: target) else { return }
                    keyDrafts[id] = nil
                    if let onConnected, ProviderConnectionID(rawValue: id)?.isSearchProvider != true { onConnected(id) }
                    else { agent.loadAccounts(on: target) }
                }
            }.disabled((keyDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(agent.busy)
    }
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSignInHandoff(url: agent.signInURL, code: agent.signInURL == nil ? nil : agent.signInCode)
            if let prompt = agent.prompt {
                Text(prompt).font(.settingsBody)
                HStack { TextField("Authorization code or redirect URL", text: $answer).wovenInput(); Button("Continue") { agent.respond(answer); answer = "" } }
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
