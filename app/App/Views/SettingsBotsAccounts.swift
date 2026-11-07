import SwiftUI
import WovenMatterClient

struct BotSettingsAccounts: View {
    let state: BotSettingsState
    let onOpenLink: (URL) -> Void
    @State private var notes: String?
    @State private var draft: String?

    var body: some View {
        BotSettingsAccountsList(state: state, onOpenLink: onOpenLink)
        SettingsCard(title: "Plans and budget", detail: "What you subscribe to and roughly what you're comfortable spending. Admin Bot reads this when it picks models. Guidance, not hard limits, and never put keys here.") {
            if let notes {
                BotSettingsTextEditor(text: Binding(get: { draft ?? notes }, set: { draft = $0 }),
                    label: "Account notes",
                    placeholder: "e.g. ChatGPT Pro ($200/mo), Claude Max ($100/mo), OpenRouter key: ~$50/month is fine")
                if let draft, draft != notes {
                    HStack {
                        Button("Save notes") {
                            Task {
                                await state.run { client in
                                    try await client.setAccountNotes(draft)
                                    self.notes = draft; self.draft = nil
                                }
                            }
                        }.buttonStyle(DashboardPrimaryButtonStyle())
                        Button("Reset") { self.draft = nil }
                    }
                }
            } else { SettingsEmpty("Loading…") }
        }
        .task(id: state.bots.connection) {
            guard state.bots.isConnected else { return }
            await state.load { notes = try await $0.accountNotes() }
        }
    }
}

struct BotSettingsLogin {
    let id: String
    let account: PiBotAccount
    let method: String?
    var progress = PiBotLoginProgress()
}

/// Shared by Accounts and the first onboarding step. Secrets are never read back.
struct BotSettingsAccountsList: View {
    let state: BotSettingsState
    let onOpenLink: (URL) -> Void
    var intro = true
    var onChanged: () async -> Void = {}
    @State private var accounts: [PiBotAccount]?
    @State private var login: BotSettingsLogin?

    var body: some View {
        if intro { SettingsNote("Keys are write-only: only their last four characters are ever shown.") }
        Group {
            if let accounts {
                let grouped = PiBotAccountGroups(accounts)
                ForEach(grouped.groups) { group in
                    SettingsCard(title: group.name) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(group.accounts) { account in
                                BotSettingsAccountRow(account: account, apiKeys: grouped.apiKeys(for: account),
                                    login: login?.account.id == account.id ? login : nil,
                                    onOpenLink: onOpenLink,
                                    onSave: { await saveKey(account, key: $0) },
                                    onSaveAlternate: { await saveKey($0, key: $1) },
                                    onRemove: { remove($0) },
                                    onSignIn: { start(account, method: $0) },
                                    onRespond: respond, onCancel: cancel, onClose: close)
                            }
                        }
                    }
                }
            } else { SettingsEmpty("Loading…") }
        }
        .disabled(state.disabled)
        .task(id: state.bots.connection) {
            if state.bots.isConnected { await state.load { try await refresh($0) } }
            else if login?.progress.status == .running {
                login?.progress.apply(.error("Connection lost. Start sign-in again."))
            }
        }
        // A sign-in nobody can see any more shouldn't keep running on the server.
        .onDisappear { abandonLogin() }
    }

    private func refresh(_ client: PiBotClient) async throws {
        accounts = try await client.accounts().accounts
        // The last sign-in going away, or the first arriving, changes what a bot's panel shows.
        await state.bots.refreshOnboarding(onError: { state.error = $0 })
        await onChanged()
    }

    private func saveKey(_ account: PiBotAccount, key: String) async -> Bool {
        let saved = await state.run { try await $0.setCredential(accountID: account.id, key: key) }
        if saved { await state.run { try await refresh($0) } }
        return saved
    }

    private func remove(_ account: PiBotAccount) {
        let verb = account.method == "oauth" ? "Sign out of" : "Remove the key for"
        state.confirm("\(verb) \(account.label)?", action: account.isKeyed ? "Remove" : "Sign out") {
            Task {
                await state.run { client in
                    try await client.removeCredential(accountID: account.id)
                    try await refresh(client)
                }
            }
        }
    }

    private func start(_ account: PiBotAccount, method: String?) {
        Task {
            await state.run { client in
                let id = try await client.startLogin(accountID: account.id, method: method)
                abandonLogin()
                login = BotSettingsLogin(id: id, account: account, method: method)
                state.bots.observeLogin(id) { event in
                    guard login?.id == id else { return }
                    login?.progress.apply(event)
                    if event == .done { Task { await state.load { try await refresh($0) } } }
                }
            }
        }
    }

    private func respond(_ promptID: String, value: String) {
        guard let login else { return }
        Task { await state.run { try await $0.respondToLogin(loginID: login.id, promptID: promptID, value: value) } }
    }

    private func close() {
        if let login { state.bots.stopObservingLogin(login.id) }
        login = nil
    }

    private func cancel() {
        guard let id = login?.id else { return }
        close()
        Task { await state.run { try await $0.cancelLogin(loginID: id) } }
    }

    private func abandonLogin() {
        guard let login else { return }
        let running = login.progress.status == .running
        close()
        guard running, let client = state.bots.connectedClient else { return }
        Task { try? await client.cancelLogin(loginID: login.id) }
    }
}

private struct BotSettingsAccountRow: View {
    let account: PiBotAccount
    let apiKeys: [PiBotAccount]
    let login: BotSettingsLogin?
    let onOpenLink: (URL) -> Void
    let onSave: (String) async -> Bool
    let onSaveAlternate: (PiBotAccount, String) async -> Bool
    let onRemove: (PiBotAccount) -> Void
    let onSignIn: (String?) -> Void
    let onRespond: (String, String) -> Void
    let onCancel: () -> Void
    let onClose: () -> Void
    @State private var keysExpanded = false

    var body: some View {
        SettingsInset {
            VStack(alignment: .leading, spacing: 8) {
                if account.isKeyed {
                    BotSettingsKeyAccountRow(account: account, onOpenLink: onOpenLink,
                                             onSave: onSave, onRemove: { onRemove(account) })
                } else {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.label).font(.system(size: 13, weight: .medium))
                            BotSettingsStatus(account: account)
                        }
                        Spacer(minLength: 8)
                        if account.isRemovable {
                            Button { onRemove(account) } label: {
                                BotSettingsActionLabel(title: "Sign out", glyph: .logOut)
                            }.accessibilityLabel("Sign out of \(account.label)")
                        }
                        Button { onSignIn(nil) } label: {
                            BotSettingsActionLabel(title: account.configured ? "Sign in again" : account.signInLabel ?? "Sign in", glyph: .logIn)
                        }.disabled(login != nil)
                    }
                    if let login {
                        BotSettingsLoginPanel(login: login, onOpenLink: onOpenLink, onRespond: onRespond,
                                              onCancel: onCancel, onClose: onClose, onRetry: onSignIn)
                    }
                    if !apiKeys.isEmpty {
                        DisclosureGroup(account.alternateKeyTitle, isExpanded: $keysExpanded) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(apiKeys) { key in
                                    BotSettingsKeyAccountRow(account: key, onOpenLink: onOpenLink,
                                        onSave: { await onSaveAlternate(key, $0) }, onRemove: { onRemove(key) })
                                }
                            }.padding(.top, 8)
                        }
                    }
                }
            }
        }
        .onAppear { keysExpanded = apiKeys.contains(where: \.configured) }
        .onChange(of: apiKeys) { _, keys in if keys.contains(where: \.configured) { keysExpanded = true } }
    }
}

struct BotSettingsKeyAccountRow: View {
    let account: PiBotAccount
    let onOpenLink: (URL) -> Void
    let onSave: (String) async -> Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label).font(.system(size: 13, weight: .medium))
                    BotSettingsStatus(account: account)
                }
                Spacer()
                if account.isRemovable {
                    Button(action: onRemove) { BotSettingsActionLabel(title: "Remove", glyph: .trash) }
                        .accessibilityLabel("Remove \(account.label)")
                }
            }
            BotSettingsKeyForm(label: account.keyLabel, placeholder: account.keyPlaceholder, onSave: onSave)
            BotSettingsAccountHelp(account: account, onOpenLink: onOpenLink)
        }
    }
}
