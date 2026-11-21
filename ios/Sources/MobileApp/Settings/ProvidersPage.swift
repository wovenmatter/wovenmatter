import SwiftUI
import WovenProtocol

/// A provider as Subscriptions & API Keys lists it: its subscription first,
/// where it has one, then its API key.
struct ProviderRow: Identifiable {
    let id: String
    let name: String
    var subscription: (id: String, title: String)? = nil
    let key: (id: String, title: String)

    var ids: [String] { [subscription?.id, key.id].compactMap { $0 } }
    var isSearch: Bool { ProviderConnectionID(rawValue: key.id)?.isSearchProvider == true }

    static let models: [ProviderRow] = [
        ProviderRow(id: "openai", name: "OpenAI", subscription: ("openai-codex", "ChatGPT subscription"),
                    key: ("openai", "Use an OpenAI API key")),
        ProviderRow(id: "anthropic", name: "Anthropic", subscription: ("claude-subscription", "Claude subscription"),
                    key: ("anthropic", "Use a Claude API key")),
        ProviderRow(id: "grok", name: "Grok · xAI", subscription: ("xai", "Grok subscription"),
                    key: ("xai-api", "Use an xAI API key")),
        ProviderRow(id: "openrouter", name: "OpenRouter", key: ("openrouter", "API key")),
        ProviderRow(id: "opencode", name: "OpenCode", key: ("opencode-go", "API key")),
    ]
    static let search: [ProviderRow] = ProviderConnectionID.searchProviders.map {
        ProviderRow(id: $0.id, name: $0.name, key: ($0.id, "API key"))
    }

    static func row(_ id: String) -> ProviderRow? { (models + search).first { $0.id == id } }
}

/// Subscriptions & API Keys for Quick Chat: this device's own sign-ins, kept
/// in its Keychain. Model providers, then web search, then model servers on
/// the tailnet.
struct ProvidersPage: View {
    @Bindable var model: MobileModel
    let deviceID: String

    private var agent: AgentSettingsStore { model.app.connections }
    private var connections: MachineProviderConnections { agent.connections(on: deviceID) }

    var body: some View {
        List {
            Section {
                ForEach(ProviderRow.models) { row in
                    let accounts = row.ids.flatMap { connections.accounts[$0] ?? [] }
                    SettingsLinkRow(title: row.name,
                                    value: accounts.isEmpty ? "Not connected" : accounts.map(\.label).joined(separator: " · "),
                                    tone: accounts.isEmpty ? .neutral : .good, page: .provider(row.id))
                        .accessibilityIdentifier("provider-\(row.id)")
                }
            } header: {
                SettingsHeader(title: "Model providers", detail: "Quick Chat uses the sign-ins and keys on this \(ThisDevice.kind).")
            }
            Section {
                ForEach(ProviderRow.search) { row in
                    let saved = !(connections.accounts[row.key.id] ?? []).isEmpty
                    let inUse = agent.configuration.searchProvider == row.key.id
                    SettingsLinkRow(title: row.name,
                                    value: saved ? (inUse ? "In use" : "Key saved") : "Not set",
                                    tone: saved ? .good : .neutral, page: .provider(row.id))
                        .accessibilityIdentifier("provider-\(row.id)")
                }
            } header: {
                SettingsHeader(title: "Web search", detail: "Quick Chat uses the provider chosen on its page.")
            }
            Section {
                ForEach(connections.localServers) { server in
                    SettingsLinkRow(title: server.name, value: server.models.count == 1 ? "1 model" : "\(server.models.count) models",
                                    page: .modelServer(server.id))
                }
                SettingsLinkRow(title: "Add a model server", page: .modelServer(nil))
                    .accessibilityIdentifier("add-model-server")
            } header: {
                SettingsHeader(title: "Model servers", detail: "An OpenAI-compatible server on your tailnet.")
            }
            if let error = agent.error, agent.signInProvider == nil {
                SettingsCaption(error, isError: true)
            }
        }
        .settingsPage("Subscriptions & API Keys")
        .task { agent.loadAccounts(on: deviceID) }
    }
}

/// One provider: its subscription with the sign-in done here, then its API
/// key (folded under the subscription when there is one). A key is never
/// shown after saving.
struct ProviderPage: View {
    @Bindable var model: MobileModel
    let deviceID: String
    let row: ProviderRow
    @State private var keyDraft = ""
    @State private var keyExpanded: Bool?
    @State private var answer = ""

    private var agent: AgentSettingsStore { model.app.connections }
    private var connections: MachineProviderConnections { agent.connections(on: deviceID) }
    private func accounts(_ id: String) -> [ProviderAccount] { connections.accounts[id] ?? [] }
    private var keySaved: Bool { !accounts(row.key.id).isEmpty }
    private var signingIn: Bool { agent.signInMachineID == deviceID && agent.signInProvider == row.subscription?.id }

    var body: some View {
        List {
            if let subscription = row.subscription {
                subscriptionSection(subscription)
                Section {
                    DisclosureGroup(isExpanded: Binding(get: { keyExpanded ?? keySaved }, set: { keyExpanded = $0 })) {
                        keyRows
                    } label: {
                        Text(row.key.title).foregroundStyle(WovenPalette.foreground).frame(minHeight: 44)
                    }
                    .tint(WovenPalette.mutedForeground)
                    .settingsRow()
                    .accessibilityIdentifier("provider-key-fold")
                }
            } else {
                Section { keyRows }
            }
            if row.isSearch {
                searchChoice
            }
            if !row.isSearch && row.ids.contains(where: { !accounts($0).isEmpty }) {
                Section {
                    SettingsLinkRow(title: "Choose models for Quick Chat", page: .composerModels)
                }
            }
            if !signingIn {
                if let error = agent.error {
                    SettingsCaption(error, isError: true)
                } else if let outcome = agent.signInOutcome, outcome.provider == row.subscription?.id {
                    if let error = outcome.error { SettingsCaption(error, isError: true) }
                }
            }
        }
        .settingsPage(row.name)
        .task { agent.loadAccounts(on: deviceID) }
        .onDisappear { agent.cancel() }
        .onChange(of: agent.signInOutcome) { _, outcome in
            guard let outcome, outcome.provider == row.subscription?.id, outcome.error == nil else { return }
            accountsChanged()
        }
    }

    @ViewBuilder private func subscriptionSection(_ subscription: (id: String, title: String)) -> some View {
        Section {
            if let account = accounts(subscription.id).first {
                SettingsControlRow(title: account.label, detail: subscription.title) {
                    SettingsStatusLabel(text: "Connected", tone: .good)
                }
                SettingsActionRow(title: "Reconnect") { agent.signIn(subscription.id, on: deviceID) }
                    .disabled(agent.busy)
                SettingsActionRow(title: "Remove", destructive: true) {
                    Task {
                        await agent.removeAccount(account.id, provider: subscription.id, on: deviceID)
                        accountsChanged()
                    }
                }
                .disabled(agent.busy)
            } else if !signingIn {
                SettingsControlRow(title: subscription.title) {
                    Button(subscription.id == "claude-subscription" ? "Sign in with Claude" : "Sign in") {
                        agent.signIn(subscription.id, on: deviceID)
                    }
                    .buttonStyle(WovenQuietButtonStyle())
                    .disabled(agent.busy)
                    .accessibilityIdentifier("provider-sign-in")
                }
            }
            if signingIn { signInLinks }
        } header: {
            SettingsHeader(title: subscription.title)
        }
        if signingIn { signInProgress }
    }

    /// The sign-in page's link and its one-time code.
    @ViewBuilder private var signInLinks: some View {
        if let url = agent.signInURL {
            Link(destination: url) {
                Text("Open sign-in page").foregroundStyle(WovenPalette.success)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .settingsRow()
            .accessibilityIdentifier("sign-in-open")
            SettingsControlRow(title: url.host() ?? url.absoluteString) {
                CopyButton(title: "Copy link", value: url.absoluteString)
            }
            if let code = agent.signInCode {
                SettingsControlRow(title: code) {
                    CopyButton(title: "Copy code", value: code)
                }
                .font(.title3.monospaced())
                .accessibilityIdentifier("sign-in-code")
            }
        }
    }

    /// A field for a code the sign-in page shows, then how the sign-in is going, with Cancel.
    @ViewBuilder private var signInProgress: some View {
        if let prompt = agent.prompt {
            Section {
                SettingsCaption(prompt)
                TextField("Code from the sign-in page", text: $answer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit(sendAnswer)
                    .wovenInput()
                    .settingsFieldRow()
                    .accessibilityIdentifier("sign-in-answer")
                SettingsPrimaryButton("Continue", action: sendAnswer)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        Section {
            SettingsActionRow(title: "Cancel") { agent.cancel() }
                .accessibilityIdentifier("sign-in-cancel")
        } footer: {
            Text(agent.signInURL == nil ? "Preparing sign-in…" : "Waiting for sign-in…")
                .font(.footnote).foregroundStyle(WovenPalette.mutedForeground)
        }
    }

    @ViewBuilder private var keyRows: some View {
        if keySaved {
            SettingsControlRow(title: "Key saved") {
                Button("Remove") {
                    Task {
                        await agent.removeAccount(row.key.id, provider: row.key.id, on: deviceID)
                        accountsChanged()
                    }
                }
                .buttonStyle(WovenQuietButtonStyle())
                .disabled(agent.busy)
                .accessibilityIdentifier("provider-key-remove")
            }
        } else {
            SecureField("API key", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(saveKey)
                .wovenInput()
                .settingsFieldRow()
                .accessibilityLabel("\(row.name) API key")
                .accessibilityIdentifier("provider-key")
            SettingsPrimaryButton("Save key", action: saveKey)
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.busy)
                .accessibilityIdentifier("provider-key-save")
        }
    }

    private var searchChoice: some View {
        let inUse = agent.configuration.searchProvider == row.key.id
        return Section {
            Button {
                var configuration = agent.configuration
                configuration.searchProvider = row.key.id
                agent.configuration = configuration
            } label: {
                HStack {
                    Text("Use for web search").foregroundStyle(WovenPalette.foreground)
                    Spacer()
                    if inUse { LucideIcon(glyph: .check, size: 18).foregroundStyle(WovenPalette.primary) }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsRow()
            .accessibilityAddTraits(inUse ? .isSelected : [])
            .accessibilityIdentifier("provider-use-for-search")
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            guard await agent.saveKey(key, provider: row.key.id, on: deviceID) else { return }
            keyDraft = ""
            keyExpanded = true
            accountsChanged()
        }
    }

    private func sendAnswer() {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        agent.respond(value)
        answer = ""
    }

    /// Quick Chat's readiness and the composer's notices follow the device's sign-ins.
    private func accountsChanged() {
        Task {
            await model.app.machines.refreshProviderSignIns(on: deviceID)
            await model.app.machines.readRuntimes(on: deviceID, checkForUpdates: false)
        }
    }
}

/// A model server on the tailnet: its address and key, checked against its
/// model list before it is saved. Nil adds one.
struct ModelServerPage: View {
    @Bindable var model: MobileModel
    let deviceID: String
    let serverID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var working = false
    @State private var error: String?

    private var agent: AgentSettingsStore { model.app.connections }
    private var server: LocalModelServer? { agent.connections(on: deviceID).localServers.first { $0.id == serverID } }

    var body: some View {
        List {
            Section {
                if let server {
                    SettingsControlRow(title: server.url) {
                        SettingsStatusLabel(text: server.models.count == 1 ? "1 model" : "\(server.models.count) models", tone: .good)
                    }
                } else {
                    TextField("Address, such as http://100.x.y.z:8000/v1", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .wovenInput()
                        .settingsFieldRow()
                        .accessibilityLabel("Server address")
                }
                SecureField(server == nil ? "API key" : "New API key, or leave empty", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .wovenInput()
                    .settingsFieldRow()
                    .accessibilityLabel("Server API key")
                SettingsPrimaryButton(server == nil ? "Connect" : "Check again") { connect() }
                    .disabled(working || (server == nil && (address.isEmpty || key.isEmpty)))
                if working { SettingsCaption("Checking the server…") }
                if let error { SettingsCaption(error, isError: true) }
            }
            if let server {
                Section {
                    SettingsActionRow(title: "Remove", destructive: true) {
                        Task {
                            do {
                                try await agent.removeLocalServer(server, on: deviceID)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .settingsPage(server?.name ?? "Model server")
    }

    private func connect() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await agent.connectLocalServer(url: server?.url ?? address, key: key, replacing: server, on: deviceID)
                key = ""
                if server == nil { dismiss() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
