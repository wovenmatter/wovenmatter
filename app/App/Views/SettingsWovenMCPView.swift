import SwiftUI

/// Tools for every agent, in one place: defaults for new chats, connected apps, bots, and
/// access for agents outside Woven Matter. Each agent page can override the defaults.
struct SettingsWovenMCPView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: () -> Void
    var onOpenPermissions: () -> Void = MacAccessSetupModel.openSettings

    var body: some View {
        SettingsPage(
            title: "Woven MCP",
            detail: "Tools that agents can use inside Woven Matter.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            WorkspaceToolDefaultsCard(tools: model.agentTools, onOpenPermissions: onOpenPermissions)
            if model.bots.homeMachine != nil { SettingsBotsMCPAccessSection(bots: model.bots) }
            SettingsMCPAccessSection(settings: model.settings)
        }
    }
}
