import SwiftUI
import WovenMatterClient

/// Settings → GitHub: one SSH key and commit identity for git everywhere Woven works.
struct SettingsGitHubView: View {
    @Bindable var model: GitHubSettingsModel
    /// The machines and their bots, as Settings → Bots knows them.
    var bots: BotsModel
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

    var body: some View {
        SettingsPage(
            title: "GitHub",
            detail: "One SSH key and commit identity for git everywhere Woven works: agents on this Mac and your other Macs, Linux workspaces, and bots.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if let snapshot = model.snapshot {
                keySection(snapshot)
                identitySection(snapshot)
                if snapshot.key != nil { accessSection(snapshot) }
                if let error = model.error { SettingsError(error) }
            } else if let error = model.error {
                SettingsError(error)
            } else {
                SettingsEmpty("Loading…")
            }
        }
        .task { await model.load() }
        .onDisappear { privateKey = ""; pasting = false }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { item in
            Button(item.action, role: .destructive) {
                confirmation = nil
                Task { await model.run(.init(action: item == .replace ? .generate : .removeKey)) }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { item in
            Text(item.message)
        }
    }

    // MARK: SSH key

    private func keySection(_ snapshot: GitHubSettingsSnapshot) -> some View {
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
            if snapshot.waitingForAnotherMac {
                SettingsNote("Another Mac changed this key. It arrives here the next time that Mac is online.")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { generateActions(snapshot) }
                VStack(alignment: .leading, spacing: 8) { generateActions(snapshot) }
            }
            .padding(.top, 4)
            if pasting { pasteForm }
        }
        .disabled(model.busy)
    }

    @ViewBuilder private func keyActions(_ key: GitHubPublicKey) -> some View {
        GitHubCopyButton(title: "Copy public key", text: key.publicKey)
        GitHubLinkButton(title: "Add key on GitHub", url: "https://github.com/settings/ssh/new") { openURL($0) }
        Button { confirmation = .remove } label: { BotSettingsActionLabel(title: "Remove key", glyph: .trash) }
            .buttonStyle(SettingsQuietButtonStyle())
    }

    @ViewBuilder private func generateActions(_ snapshot: GitHubSettingsSnapshot) -> some View {
        Button {
            if snapshot.key != nil { confirmation = .replace }
            else { Task { await model.run(.init(action: .generate)) } }
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
                        if await model.run(.init(action: .importKey, privateKey: privateKey)) {
                            privateKey = ""; pasting = false
                        }
                    }
                }
                .buttonStyle(WovenPrimaryButtonStyle())
                .disabled(privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { privateKey = ""; pasting = false; model.error = nil }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
        }
        .padding(.top, 4)
    }

    // MARK: Identity

    private func identitySection(_ snapshot: GitHubSettingsSnapshot) -> some View {
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
                        if await model.run(.init(action: .saveIdentity, identity: .init(name: currentName, email: currentEmail))) {
                            name = nil; email = nil
                        }
                    }
                }
                .buttonStyle(WovenPrimaryButtonStyle())
                .disabled(!changed || model.busy)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Where the key goes

    private func accessSection(_ snapshot: GitHubSettingsSnapshot) -> some View {
        let places = GitHubPlace.list(bots, thisDeviceID: snapshot.thisDeviceID)
        let listed = places.flatMap { [$0.id] + $0.bots.map(\.id) }.filter { !$0.hasPrefix("linux:") && !$0.hasPrefix("member:") }
        return SettingsSection(title: "Where the key goes",
                               detail: "Agents and bots use the key only where it's on. Your name and email apply everywhere.") {
            SettingsToggleRow(title: "New places get the key", detail: "Macs, workspaces, and bots you add later.",
                              isOn: Binding(get: { snapshot.access.newPlaces }, set: { value in
                                  Task { await model.run(.init(action: .setNewPlaces, allowed: value, listed: listed)) }
                              }))
            ForEach(places) { place in
                let machineOn = snapshot.access.allows(place.id)
                GitHubPlaceRow(glyph: place.glyph, title: place.name, detail: place.detail,
                               isOn: Binding(get: { machineOn }, set: { value in
                                   Task { await model.run(.init(action: .setPlace, place: place.id, allowed: value)) }
                               }))
                    .disabled(!place.canChoose)
                ForEach(place.bots) { bot in
                    GitHubPlaceRow(glyph: .bot, title: bot.name, detail: "Bot on " + place.name,
                                   isOn: Binding(get: { machineOn && snapshot.access.allows(bot.id) }, set: { value in
                                       Task { await model.run(.init(action: .setPlace, place: bot.id, allowed: value)) }
                                   }))
                        .disabled(!machineOn || !place.canChoose)
                        .padding(.leading, 26)
                }
            }
            SettingsNote("Turning a place off stops it at its next git command; a place that's offline stops when it's next online.")
        }
        .disabled(model.busy)
    }
}

/// A Mac or Linux machine on the GitHub page, with its bots nested under it.
private struct GitHubPlace: Identifiable {
    struct Bot: Identifiable { let id: String; let name: String }
    let id: String
    let name: String
    let detail: String
    let glyph: LucideGlyph
    let isThisMac: Bool
    /// An offline machine never reached yet has no device ID to choose by.
    let canChoose: Bool
    let bots: [Bot]

    @MainActor static func list(_ model: BotsModel, thisDeviceID: String?) -> [GitHubPlace] {
        let order: [BotMachine.Kind: Int] = [.thisMac: 0, .mac: 1, .linux: 2]
        // Before Bots has answered, This Mac is still listed.
        let machines = model.machines.contains { $0.kind == .thisMac } || thisDeviceID == nil ? model.machines
            : [BotMachine(id: thisDeviceID ?? "", name: "This Mac", kind: .thisMac, state: .off)] + model.machines
        return machines
            .sorted { (order[$0.kind] ?? 3, $0.displayName.lowercased()) < (order[$1.kind] ?? 3, $1.displayName.lowercased()) }
            .map { machine in
                let isThisMac = machine.kind == .thisMac
                let id = isThisMac ? (thisDeviceID ?? machine.id) : machine.id
                let canChoose = !id.hasPrefix("linux:") && !id.hasPrefix("member:")
                let detail: String
                switch machine.kind {
                case .thisMac: detail = "Mac you're using"
                case .mac: detail = canChoose ? "Mac" : "Mac · connect it once to choose"
                case .linux: detail = canChoose ? "Linux workspace" : "Linux workspace · connect it once to choose"
                }
                let bots = (model.session(for: machine.id)?.bots ?? [])
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map { Bot(id: $0.id, name: $0.name) }
                return GitHubPlace(id: id, name: machine.displayName, detail: detail,
                                   glyph: machine.kind == .linux ? .terminal : .monitor,
                                   isThisMac: isThisMac, canChoose: canChoose, bots: bots)
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
