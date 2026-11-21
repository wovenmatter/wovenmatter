import SwiftUI

struct WorkspaceToolDefaultsCard: View {
    @Bindable var tools: AgentToolsStore
    var onOpenPermissions: () -> Void = MacAccessSetupModel.openSettings

    private var enabledCount: Int {
        WorkspaceToolGroup.allCases.filter { tools.settings.enabledByDefault.contains($0) }.count
    }

    var body: some View {
        SettingsSection(title: "Tools for new chats", detail: "Agents use these by default. You can change them in each chat or on an agent’s page.") {
            SettingsSummaryRow("Tools", value: "\(enabledCount) of \(WorkspaceToolGroup.allCases.count) on") {
                ForEach(WorkspaceToolGroup.allCases) { group in
                    Toggle(group.title, isOn: Binding(get: { tools.settings.enabledByDefault.contains(group) }, set: { enabled in
                        var settings = tools.settings
                        if enabled { settings.enabledByDefault.insert(group) } else { settings.enabledByDefault.remove(group) }
                        tools.saveSettingsFromUI(settings)
                    }))
                    if group == .browser {
                        SettingsNote("Controls the browser inside Woven Matter.").padding(.leading, 12)
                    }
                    if group == .computer { WorkspaceComputerUseExplanation(onOpenPermissions: onOpenPermissions).padding(.leading, 12) }
                }
            }
            if let error = tools.error { SettingsError(error) }
        }
    }
}

struct WorkspaceSessionToolsMenu: View {
    @Bindable var tools: AgentToolsStore
    let sessionID: String
    @State private var confirmsTimerPause = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private func set(_ group: WorkspaceToolGroup, enabled: Bool, confirmed: Bool = false) {
        Task {
            do {
                try await tools.setEnabledFromUI(group, enabled: enabled, sessionID: sessionID, confirmedPausingTimers: confirmed)
                error = nil
            } catch WorkspaceToolError.timerPauseConfirmation { confirmsTimerPause = true }
            catch { self.error = error.localizedDescription }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("Tools").font(.system(size: 13, weight: .semibold))
                SettingsNote("Woven MCP tools for this session.")
                ForEach(WorkspaceToolGroup.allCases) { group in
                    HStack(spacing: 12) {
                        Toggle(group.title, isOn: Binding(get: { tools.policy(for: sessionID).enabled.contains(group) }, set: { set(group, enabled: $0) }))
                        Spacer(minLength: 0)
                    }
                    if group == .computer {
                        WorkspaceComputerUseExplanation { MacAccessSetupModel.openSettings(); dismiss() }
                    }
                }
                WorkspaceSessionManagementControls(tools: tools, sessionID: sessionID)
                if let error = error ?? tools.error { Text(error).font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground) }
            }.padding(16)
        }.scrollIndicators(.never)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12.5))
        .foregroundStyle(WovenPalette.foreground)
        .toggleStyle(CompactSwitchToggleStyle())
        .frame(width: 330)
        .alert("Disable timers?", isPresented: $confirmsTimerPause) {
            Button("Cancel", role: .cancel) { }
            Button("Disable and pause") { set(.timers, enabled: false, confirmed: true) }
        } message: { Text("Disabling timers will pause this session’s active timers.") }
    }
}

/// Computer Use's macOS permissions live in Settings → Permissions & Access;
/// this shows their status and links there.
private struct WorkspaceComputerUseExplanation: View {
    let onOpenPermissions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allows agents to see and control this Mac’s desktop and apps.")
            MacPermissionStatusLink(items: MacAccessStatus.computerUseRequirements, onOpen: onOpenPermissions)
        }.font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
    }
}
