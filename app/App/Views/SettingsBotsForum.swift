import SwiftUI
import WovenMatterClient

/// Settings → Bots: what the bots call the user, and the Forum they share. Both belong to
/// the one machine that runs bots; a runtime from before either shows nothing here.
struct SettingsBotsYouAndForum: View {
    @Bindable var bots: BotMachineSession

    var body: some View {
        if bots.isConnected {
            if bots.supportsUserName { SettingsBotsUserName(bots: bots) }
            if bots.supportsForum, let forum = bots.forum { forumSection(forum) }
        }
    }

    private func forumSection(_ forum: PiBotForumState) -> some View {
        let active = forum.activeBotIDs.count
        return SettingsSection(title: "Forum", detail: "One channel in the sidebar where you and your bots talk together.") {
            SettingsToggleRow(
                title: "Pause the Forum",
                detail: "Stops bots' Forum replies and holds new posts. On resume each bot catches up.",
                isOn: Binding(get: { bots.forum?.paused == true }, set: { paused in Task { await bots.setForumPaused(paused) } })
            )
            SettingsSummaryRow("Bots in the Forum", value: "\(active) of \(forum.bots.count)") {
                ForumMemberSwitches(bots: bots)
                SettingsNote("A bot that is in sees every post. Switched out, it hears nothing and leaves its threads. Admin Bot is out unless you switch it in.")
            }
        }
    }
}

/// One value, kept by the bots runtime: every bot is told it, and Admin Bot asks for it
/// while it is missing.
private struct SettingsBotsUserName: View {
    @Bindable var bots: BotMachineSession
    /// The field's text while it differs from what is saved.
    @State private var draft: String?
    @State private var saving = false

    private var text: String { draft ?? bots.userName }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmed != bots.userName }

    var body: some View {
        SettingsSection {
            SettingsRow(title: "Your name",
                        detail: "What your bots call you. Admin Bot asks for it when it is missing.") {
                TextField(text: Binding(get: { text }, set: { draft = String($0.prefix(80)) }),
                          prompt: Text(verbatim: "Your name")) { Text("Your name") }
                    .labelsHidden()
                    .wovenInput()
                    .frame(width: 220)
                    .onSubmit { save() }
                Button("Save") { save() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(!changed || saving)
            }
        }
    }

    private func save() {
        guard changed, !saving else { return }
        let name = trimmed
        saving = true
        Task {
            if await bots.setUserName(name) { draft = nil }
            saving = false
        }
    }
}
