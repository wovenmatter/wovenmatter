import SwiftUI
import WovenMatterCore

struct SettingsMCPAccessSection: View {
    @Bindable var model: ApplicationModel
    @State private var snapshot: WovenMCPAccessSnapshot?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SettingsCard(title: "Outside agents · Woven MCP",
                     detail: "Expose Woven Matter to agents on your Tailnet. Any agent that can reach this endpoint can use the tools enabled here.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MCP endpoint").font(.system(size: 12.5, weight: .medium))
                        if let snapshot {
                            Text(snapshot.endpointURL).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        } else { SettingsNote(busy ? "Loading…" : "Unavailable") }
                    }
                    Spacer(minLength: 8)
                    Button("Refresh") { update(.status) }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                }
                Toggle("Expose Woven MCP", isOn: Binding(get: { snapshot?.settings.isEnabled ?? false },
                    set: { update(.setEnabled($0)) }))
                    .disabled(busy || snapshot == nil)
                if let snapshot, snapshot.settings.isEnabled {
                    ForEach(WorkspaceToolGroup.configurableCases) { group in
                        Toggle(group.title, isOn: Binding(get: { self.snapshot?.settings.groups.contains(group) ?? false },
                            set: { update(.setGroup(group, enabled: $0)) }))
                    }
                    .disabled(busy)
                    SettingsNote("Goals and visual replies are included. Usage data is always read only.")
                    if let exposureError = snapshot.exposureError {
                        SettingsNote("Tailnet endpoint unavailable: " + exposureError)
                    }
                }
                if let error { SettingsNote(error) }
            }
            .font(.system(size: 13))
            .toggleStyle(DashboardSwitchToggleStyle())
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
