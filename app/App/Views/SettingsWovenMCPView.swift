import SwiftUI
import WovenMatterCore

/// Tools for every agent, in one place: defaults for new chats, connected apps, and
/// access for agents outside Woven Matter. Each agent page can override the defaults.
struct SettingsWovenMCPView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    var body: some View {
        SettingsPage(
            title: "Woven MCP",
            detail: "Tools that agents can use inside Woven Matter.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if let tools = model.agentTools {
                WorkspaceToolDefaultsCard(tools: tools)
                ExecutorConnectionsCard(model: model, tools: tools)
            } else {
                SettingsEmpty("Tool settings are unavailable until the workspace finishes opening.")
            }
            SettingsMCPAccessSection(model: model)
        }
    }
}
