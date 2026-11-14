import SwiftUI
import WovenMatterClient

/// Settings → GitHub: one SSH key and commit identity for git everywhere Woven works.
struct SettingsGitHubView: View {
    @Bindable var model: GitHubSettingsModel
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
                if let error = model.error { SettingsError(error) }
            } else if let error = model.error {
                SettingsError(error)
            } else {
                SettingsEmpty("Loading…")
            }
            SettingsHelp {
                SettingsNote("Add the public key to your GitHub account, or as a deploy key on a single repository. Woven uses it only for github.com; other hosts keep using your own SSH settings.")
                SettingsNote("The private key stays in Apple Keychain on each of your Macs. Paired Macs receive it sealed to that Mac, so library copies on other devices hold only ciphertext.")
                SettingsNote("Linux workspaces and bots machines receive it with their other connections and keep it as a private file. Bots get it in their containers when they use git.")
                SettingsNote("Keys with a passphrase cannot be used: nobody may be at the machine to type it.")
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
