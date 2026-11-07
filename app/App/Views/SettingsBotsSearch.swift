import SwiftUI
import WovenMatterClient

struct BotSettingsSearch: View {
    let state: BotSettingsState
    let onOpenLink: (URL) -> Void
    @State private var search: PiBotSearchSettings?

    var body: some View {
        SettingsCard(title: "Keys", detail: "Save one API key per provider. Select a saved key to use for web search.") {
            if let search {
                let configured = search.providers.filter(\.configured)
                if !configured.isEmpty {
                    Picker("Web search provider", selection: Binding(
                        get: { self.search?.selected?.id ?? "" }, set: { select($0) })) {
                        ForEach(configured) { provider in Text(provider.label).tag(provider.id) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    .accessibilityLabel("Saved key to use for web search")
                }
                ForEach(search.providers) { provider in
                    SettingsInset {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.label).font(.system(size: 13, weight: .medium))
                                    BotSettingsStatus(account: provider)
                                }
                                Spacer()
                                if provider.isRemovable {
                                    Button { remove(provider) } label: { BotSettingsActionLabel(title: "Remove", glyph: .trash) }
                                        .accessibilityLabel("Remove \(provider.label)")
                                }
                            }
                            BotSettingsKeyForm(label: "\(provider.label) API key", placeholder: provider.configured ? "Paste a new key to replace it" : "Paste API key") { key in
                                let saved = await state.run { try await $0.setCredential(accountID: provider.id, key: key) }
                                if saved { await state.run { try await refresh($0) } }
                                return saved
                            }
                            BotSettingsAccountHelp(account: provider, onOpenLink: onOpenLink)
                        }
                    }
                }
            } else { SettingsEmpty("Loading…") }
        }
        .task(id: state.bots.connection) {
            guard state.bots.isConnected else { return }
            await state.load { try await refresh($0) }
        }
    }

    private func refresh(_ client: PiBotClient) async throws { search = try await client.accounts().search }

    private func select(_ id: String) {
        Task {
            await state.run { client in
                try await client.updateConfig(edits: [.init(path: ["search", "provider"], value: .string(id))])
                if let search { self.search = PiBotSearchSettings(provider: id, providers: search.providers) }
                state.configSaved()
            }
        }
    }

    private func remove(_ provider: PiBotAccount) {
        state.confirm("Remove the key for \(provider.label)?", action: "Remove") {
            Task {
                await state.run { client in
                    try await client.removeCredential(accountID: provider.id)
                    try await refresh(client)
                }
            }
        }
    }
}
