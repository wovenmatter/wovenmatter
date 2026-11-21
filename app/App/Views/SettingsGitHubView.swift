import SwiftUI

/// Settings → GitHub: one SSH key and commit identity for git everywhere Woven works.
struct SettingsGitHubView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @Environment(\.wovenTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var pasting = false
    @State private var privateKey = ""
    @State private var name: String?
    @State private var email: String?
    @State private var confirmation: Confirmation?

    private enum Confirmation: Identifiable {
        case replace, remove
        var id: Self { self }
        var title: String { self == .replace ? "Replace the SSH key with a new one?" : "Remove the SSH key?" }
        var message: String {
            self == .replace
                ? "The current key stops working for Woven on every machine. Add the new public key to GitHub afterwards."
                : "Agents and bots on every machine stop using it for GitHub. Remove it from your GitHub account too."
        }
        var action: String { self == .replace ? "Replace" : "Remove key" }
    }

    private var store: SettingsStore { model.settings }

    var body: some View {
        SettingsPage(
            title: "GitHub",
            detail: "One SSH key and commit identity for git everywhere Woven works: agents on this Mac and your other Macs, Linux workspaces, and bots.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if let snapshot = store.github {
                keySection(snapshot)
                identitySection(snapshot)
                if snapshot.key != nil { accessSection(snapshot) }
                if let error = store.githubError { SettingsError(error) }
            } else if let error = store.githubError {
                SettingsError(error)
            } else {
                SettingsEmpty("Loading…")
            }
        }
        .task { await store.loadGitHub() }
        .onDisappear { privateKey = ""; pasting = false }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { item in
            Button(item.action, role: .destructive) {
                confirmation = nil
                Task { await store.runGitHub(item == .replace ? .generate : .removeKey) }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { item in
            Text(item.message)
        }
    }

    // MARK: SSH key

    private func keySection(_ snapshot: GitHubSettings) -> some View {
        SettingsSection(title: "SSH key", detail: "Used to clone, pull, and push GitHub repositories.") {
            if let key = snapshot.key {
                SettingsRow(title: key.comment ?? key.type, detail: key.fingerprint) {
                    SettingsStatus("Ready", tone: .good)
                }
                Text(key.publicKey)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Public key")
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.themeWhisper)
                    .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { keyActions(key) }
                    VStack(alignment: .leading, spacing: 8) { keyActions(key) }
                }
            } else {
                SettingsEmpty("No SSH key yet.")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { generateActions(snapshot) }
                VStack(alignment: .leading, spacing: 8) { generateActions(snapshot) }
            }
            .padding(.top, 4)
            if pasting { pasteForm }
        }
        .disabled(store.githubBusy)
    }

    @ViewBuilder private func keyActions(_ key: GitHubPublicKey) -> some View {
        GitHubCopyButton(title: "Copy public key", text: key.publicKey)
        GitHubLinkButton(title: "Add key on GitHub", url: "https://github.com/settings/ssh/new") { openURL($0) }
        Button { confirmation = .remove } label: { BotSettingsActionLabel(title: "Remove key", glyph: .trash) }
            .buttonStyle(SettingsQuietButtonStyle())
    }

    @ViewBuilder private func generateActions(_ snapshot: GitHubSettings) -> some View {
        Button {
            if snapshot.key != nil { confirmation = .replace }
            else { Task { await store.runGitHub(.generate) } }
        } label: {
            BotSettingsActionLabel(title: snapshot.key == nil ? "Generate a key" : "Replace with a new key", glyph: .keyRound)
        }
        .buttonStyle(WovenPrimaryButtonStyle())
        if !pasting {
            Button("Paste an existing private key") { pasting = true }
                .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    private var pasteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            BotSettingsTextEditor(text: $privateKey, label: "Private key",
                placeholder: GitHubSSHKeys.openSSHHeader, height: 150, monospaced: true)
                .autocorrectionDisabled()
                .privacySensitive()
            HStack(spacing: 8) {
                Button("Save private key") {
                    Task {
                        if await store.runGitHub(.importKey(privateKey: privateKey)) {
                            privateKey = ""; pasting = false
                        }
                    }
                }
                .buttonStyle(WovenPrimaryButtonStyle())
                .disabled(privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { privateKey = ""; pasting = false; store.githubError = nil }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
        }
        .padding(.top, 4)
    }

    // MARK: Identity

    private func identitySection(_ snapshot: GitHubSettings) -> some View {
        let currentName = name ?? snapshot.identity.name
        let currentEmail = email ?? snapshot.identity.email
        let trimmed = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let changed = trimmed(currentName) != snapshot.identity.name || trimmed(currentEmail) != snapshot.identity.email
        return SettingsSection(title: "Git identity",
                               detail: "Author name and email on commits agents and bots make. Leave both blank to keep each machine's own git settings.") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsField("Name") {
                    TextField("Your name", text: Binding(get: { currentName }, set: { name = $0 }))
                        .wovenInput()
                }
                SettingsField("Email") {
                    // Verbatim: as a localized key this would render as a Markdown mail link.
                    TextField(text: Binding(get: { currentEmail }, set: { email = $0 }),
                              prompt: Text(verbatim: "you@example.com")) { Text("Email") }
                        .labelsHidden()
                        .wovenInput()
                }
                Button("Save identity") {
                    Task {
                        if await store.runGitHub(.saveIdentity(GitHubGitIdentity(name: currentName, email: currentEmail))) {
                            name = nil; email = nil
                        }
                    }
                }
                .buttonStyle(WovenPrimaryButtonStyle())
                .disabled(!changed || store.githubBusy)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Where the key goes

    private func accessSection(_ snapshot: GitHubSettings) -> some View {
        let places = GitHubPlace.list(model.machines.machines, bots: model.bots)
        let listed = places.flatMap { [$0.id] + $0.bots.map(\.id) }
        return SettingsSection(title: "Where the key goes",
                               detail: "Agents and bots use the key only where it's on. Your name and email apply everywhere.") {
            SettingsToggleRow(title: "New places get the key", detail: "Macs, workspaces, and bots you add later.",
                              isOn: Binding(get: { snapshot.access.newPlaces }, set: { value in
                                  Task { await store.runGitHub(.setNewPlaces(value, listed: listed)) }
                              }))
            ForEach(places) { place in
                let machineOn = snapshot.access.allows(place.id)
                GitHubPlaceRow(glyph: place.glyph, title: place.name, detail: place.detail,
                               isOn: Binding(get: { machineOn }, set: { value in
                                   Task { await store.runGitHub(.setPlace(place.id, allowed: value)) }
                               }))
                ForEach(place.bots) { bot in
                    GitHubPlaceRow(glyph: .bot, title: bot.name, detail: "Bot on " + place.name,
                                   isOn: Binding(get: { machineOn && snapshot.access.allows(bot.id) }, set: { value in
                                       Task { await store.runGitHub(.setPlace(bot.id, allowed: value)) }
                                   }))
                        .disabled(!machineOn)
                        .padding(.leading, 26)
                }
            }
            SettingsNote("Turning a place off stops it at its next git command; a place that's offline stops when it's next online.")
        }
        .disabled(store.githubBusy)
    }
}

/// A Mac or Linux machine on the GitHub page, with the bots nested under their host.
private struct GitHubPlace: Identifiable {
    struct Bot: Identifiable { let id: String; let name: String }
    let id: String
    let name: String
    let detail: String
    let glyph: LucideGlyph
    let bots: [Bot]

    @MainActor static func list(_ machines: [Machine], bots: BotsStore) -> [GitHubPlace] {
        machines.map { machine in
            let detail = machine.isThisMachine ? "Mac you're using" : machine.platform == .mac ? "Mac" : "Linux workspace"
            let botsHere = machine.id == bots.hostMachineID
                ? bots.bots.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map { Bot(id: $0.id, name: $0.name) }
                : []
            return GitHubPlace(id: machine.id, name: machine.name, detail: detail,
                               glyph: machine.platform == .linux ? .terminal : .monitor, bots: botsHere)
        }
    }
}

private struct GitHubPlaceRow: View {
    let glyph: LucideGlyph
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                LucideIcon(glyph: glyph, size: 15)
                    .foregroundStyle(WovenPalette.mutedForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.settingsRow)
                    Text(detail)
                        .font(.settingsSecondary)
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

private struct GitHubLinkButton: View {
    let title: String
    let url: String
    let onOpenLink: (URL) -> Void
    var body: some View {
        Button { if let target = URL(string: url) { onOpenLink(target) } } label: {
            BotSettingsActionLabel(title: title, glyph: .externalLink)
                .foregroundStyle(WovenPalette.success)
        }
        .buttonStyle(SettingsQuietButtonStyle())
    }
}

private struct GitHubCopyButton: View {
    let title: String
    let text: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: { BotSettingsActionLabel(title: title, glyph: .copy) }
        .buttonStyle(SettingsQuietButtonStyle())
    }
}
