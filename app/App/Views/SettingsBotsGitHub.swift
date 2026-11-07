import SwiftUI
import WovenMatterClient

struct BotSettingsGitHub: View {
    let state: BotSettingsState
    let onOpenLink: (URL) -> Void
    @State private var status: PiBotGitHubStatus?
    @State private var pasting = false
    @State private var privateKey = ""
    @State private var name: String?
    @State private var email: String?

    var body: some View {
        Group {
            if let status {
                keyCard(status)
                identityCard(status)
            } else { SettingsEmpty("Loading…") }
        }
        .task(id: state.bots.connection) {
            guard state.bots.isConnected else { return }
            await state.load { try await refresh($0) }
        }
        .onDisappear { privateKey = "" }
    }

    private func refresh(_ client: PiBotClient) async throws { status = try await client.github() }

    private func keyCard(_ status: PiBotGitHubStatus) -> some View {
        SettingsCard(title: "Shared SSH key", detail: "Shared by all your bots to clone, pull, and push repositories.") {
            if let key = status.sshKey {
                Text(key.comment ?? key.type).font(.system(size: 13, weight: .medium))
                Text(key.fingerprint).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
                Text(key.publicKey).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).accessibilityLabel("Public key")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    HStack { keyActions(key) }
                    VStack(alignment: .leading) { keyActions(key) }
                }
            } else { SettingsEmpty("No SSH key stored.") }
            ViewThatFits(in: .horizontal) {
                HStack { generateActions(status) }
                VStack(alignment: .leading) { generateActions(status) }
            }
            if pasting {
                BotSettingsTextEditor(text: $privateKey, label: "Private key",
                    placeholder: "-----BEGIN OPENSSH PRIVATE KEY-----", height: 150, monospaced: true)
                    .autocorrectionDisabled().privacySensitive()
                HStack {
                    Button("Save private key") {
                        Task {
                            await state.run { client in
                                try await client.setSSHKey(privateKey: privateKey)
                                privateKey = ""; pasting = false
                                try await refresh(client)
                            }
                        }
                    }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { privateKey = ""; pasting = false }
                }
            }
        }
    }

    @ViewBuilder private func keyActions(_ key: PiBotSshKey) -> some View {
        BotSettingsCopy(title: "Copy public key", text: key.publicKey)
        BotSettingsLink(title: "Add key on GitHub ↗", url: "https://github.com/settings/ssh/new", onOpenLink: onOpenLink)
        Button {
            state.confirm("Remove the stored SSH key?", action: "Remove key") {
                Task { await state.run { client in try await client.removeSSHKey(); try await refresh(client) } }
            }
        } label: { BotSettingsActionLabel(title: "Remove key", glyph: .trash) }
    }

    @ViewBuilder private func generateActions(_ status: PiBotGitHubStatus) -> some View {
        Button {
            if status.sshKey != nil {
                state.confirm("Replace the stored SSH key with a new one?", action: "Replace") { generate() }
            } else { generate() }
        } label: {
            BotSettingsActionLabel(title: status.sshKey == nil ? "Generate a key" : "Replace with a new key", glyph: .keyRound)
        }.buttonStyle(DashboardPrimaryButtonStyle())
        if !pasting { Button("Paste an existing private key") { pasting = true } }
    }

    private func generate() {
        Task { await state.run { client in try await client.generateSSHKey(comment: "pi-bot"); try await refresh(client) } }
    }

    private func identityCard(_ status: PiBotGitHubStatus) -> some View {
        let currentName = name ?? status.identity.name ?? ""
        let currentEmail = email ?? status.identity.email ?? ""
        let changed = currentName != (status.identity.name ?? "") || currentEmail != (status.identity.email ?? "")
        return SettingsCard(title: "Git identity", detail: "Author name and email on commits made by all your bots. Leave email blank to use your GitHub account’s noreply address.") {
            SettingsField("Name") {
                TextField("Your name", text: Binding(get: { name ?? status.identity.name ?? "" }, set: { name = $0 })).dashboardInput()
            }
            SettingsField("Email") {
                // Verbatim: as a localized key this would render as a Markdown mail link.
                TextField(text: Binding(get: { email ?? status.identity.email ?? "" }, set: { email = $0 }),
                          prompt: Text(verbatim: "you@example.com")) { Text("Email") }
                    .labelsHidden()
                    .dashboardInput()
            }
            Button("Save identity") {
                Task {
                    await state.run { client in
                        try await client.setGitIdentity(name: currentName.trimmingCharacters(in: .whitespacesAndNewlines),
                            email: currentEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                        try await refresh(client)
                        name = nil; email = nil; state.configSaved()
                    }
                }
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(!changed || currentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
