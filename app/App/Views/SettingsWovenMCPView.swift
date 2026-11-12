import SwiftUI
import WovenMatterCore

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
            if let tools = model.agentTools {
                WorkspaceToolDefaultsCard(tools: tools, onOpenPermissions: onOpenPermissions)
            } else {
                SettingsEmpty("Tool settings are unavailable until the workspace finishes opening.")
            }
            SettingsBotsMCPAccessSection(model: model)
            SettingsMCPAccessSection(model: model)
            if let tools = model.agentTools {
                ExecutorConnectionsCard(model: model, tools: tools)
            }
        }
    }
}
