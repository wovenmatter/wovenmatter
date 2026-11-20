import SwiftUI

/// Woven MCP for agents outside Woven Matter: on or off, and which tools. Tailscale
/// decides who may reach the endpoint.
struct SettingsMCPAccessSection: View {
    @Bindable var settings: SettingsStore

    private var access: WovenMCPAccess? { settings.mcpAccess }
    private var busy: Bool { settings.mcpAccessBusy }
    private var exposedCount: Int {
        WorkspaceToolGroup.allCases.filter { access?.groups.contains($0) == true }.count
    }

    var body: some View {
        SettingsSection(title: "Outside agents",
                        detail: "Any agent that can reach this endpoint on your Tailnet can use the tools enabled here.") {
            SettingsToggleRow(
                title: "Expose Woven MCP",
                detail: nil,
                isOn: Binding(get: { access?.isEnabled ?? false }, set: { value in
                    Task { await settings.setMCPAccessEnabled(value) }
                })
            )
            .disabled(busy || access == nil)
            SettingsRow(title: "MCP endpoint") {
                if let access {
                    Text(access.endpointURL)
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
                SettingsSummaryRow("Tools exposed", value: "\(exposedCount) of \(WorkspaceToolGroup.allCases.count)") {
                    ForEach(WorkspaceToolGroup.allCases) { group in
                        Toggle(group.title, isOn: Binding(get: { settings.mcpAccess?.groups.contains(group) ?? false },
                            set: { value in Task { await settings.setMCPAccessGroup(group, enabled: value) } }))
                    }
                    .disabled(busy)
                    SettingsNote("Goals and visual replies are included. Usage data is always read only.")
                }
                if let exposureError = access.exposureError {
                    SettingsError("Tailnet endpoint unavailable: " + exposureError)
                }
            }
            if let error = settings.mcpAccessError { SettingsError(error) }
        }
        .task { await settings.refreshMCPAccess() }
    }
}
