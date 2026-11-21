import SwiftUI
import WovenProtocol

/// Woven MCP for agents outside Woven Matter on this Mac: on or off, which tools,
/// and the stdio command they start, a bridge to this Mac's server.
struct SettingsMCPAccessSection: View {
    @Bindable var settings: SettingsStore

    private var access: OutsideAgentAccess? { settings.mcpAccess }
    private var busy: Bool { settings.mcpAccessBusy }
    private var exposedCount: Int { ToolGroup.allCases.filter { access?.groups.contains($0) == true }.count }

    var body: some View {
        SettingsSection(title: "Outside agents",
                        detail: "Any agent on this Mac that starts this command can use the tools enabled here.") {
            SettingsToggleRow(
                title: "Expose Woven MCP",
                detail: nil,
                isOn: Binding(get: { access?.isEnabled ?? false }, set: { value in
                    Task { await settings.setMCPAccessEnabled(value) }
                })
            )
            .disabled(busy || access == nil)
            SettingsRow(title: "MCP command") {
                if let access {
                    Text(access.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(busy ? "Loading…" : "Unavailable")
                        .font(.settingsSecondary)
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
                Button("Refresh") { Task { await settings.refreshMCPAccess() } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(busy)
            }
            if let access, access.isEnabled {
                SettingsSummaryRow("Tools exposed", value: "\(exposedCount) of \(ToolGroup.allCases.count)") {
                    ForEach(ToolGroup.allCases) { group in
                        Toggle(group.title, isOn: Binding(get: { settings.mcpAccess?.groups.contains(group) ?? false },
                            set: { value in Task { await settings.setMCPAccessGroup(group, enabled: value) } }))
                    }
                    .disabled(busy)
                }
            }
            if let error = settings.mcpAccessError { SettingsError(error) }
        }
        .task { await settings.refreshMCPAccess() }
    }
}
