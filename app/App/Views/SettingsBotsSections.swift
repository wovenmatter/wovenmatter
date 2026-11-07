import SwiftUI
import WovenMatterClient

/// One of Pi Bot's settings sections, native over its protocol.
struct SettingsBotsSectionPage: View {
    @Bindable var bots: BotsModel
    let section: PiBotSettingsSection
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpenLink: (URL) -> Void

    var body: some View {
        SettingsPage(title: section.title, detail: section.detail, reservesRailControlSpace: reservesRailControlSpace, backTitle: "Bots", onBack: onBack) {
            SettingsNote("Coming up.")
        }
    }
}

struct BotOnboardingView: View {
    @Bindable var bots: BotsModel
    let onOpenLink: (URL) -> Void

    var body: some View {
        DashboardConversationEmptyState(icon: .bot, title: "Sign in to a provider", detail: nil)
    }
}
