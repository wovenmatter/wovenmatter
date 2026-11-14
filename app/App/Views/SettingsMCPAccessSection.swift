import SwiftUI
import WovenMatterCore

struct SettingsMCPAccessSection: View {
    @Bindable var model: ApplicationModel
    @State private var snapshot: WovenMCPAccessSnapshot?
    @State private var busy = false
    @State private var error: String?

    private var exposedCount: Int {
        WorkspaceToolGroup.configurableCases.filter { snapshot?.settings.groups.contains($0) == true }.count
    }

    var body: some View {
        SettingsSection(title: "Outside agents",
                        detail: "Any agent that can reach this endpoint on your Tailnet can use the tools enabled here.") {
            SettingsToggleRow(
                title: "Expose Woven MCP",
                detail: nil,
                isOn: Binding(get: { snapshot?.settings.isEnabled ?? false }, set: { update(.setEnabled($0)) })
            )
            .disabled(busy || snapshot == nil)
            SettingsRow(title: "MCP endpoint") {
                if let snapshot {
                    Text(snapshot.endpointURL)
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
                Button("Refresh") { update(.status) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(busy)
            }
            if let snapshot, snapshot.settings.isEnabled {
                SettingsSummaryRow("Tools exposed", value: "\(exposedCount) of \(WorkspaceToolGroup.configurableCases.count)") {
                    ForEach(WorkspaceToolGroup.configurableCases) { group in
                        Toggle(group.title, isOn: Binding(get: { self.snapshot?.settings.groups.contains(group) ?? false },
                            set: { update(.setGroup(group, enabled: $0)) }))
                    }
                    .disabled(busy)
                    SettingsNote("Goals and visual replies are included. Usage data is always read only.")
                }
                if let exposureError = snapshot.exposureError {
                    SettingsError("Tailnet endpoint unavailable: " + exposureError)
                }
            }
            if let error { SettingsError(error) }
        }
        .task { await perform(.status) }
    }

    private func update(_ action: WovenMCPAccessAction) {
        Task { await perform(action) }
    }

    @MainActor
    private func perform(_ action: WovenMCPAccessAction) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { snapshot = try await model.controlMCPAccess(action) }
        catch { self.error = error.localizedDescription }
    }
}
