import SwiftUI
import WovenMatterCompanion

struct SettingsDeviceWorkspacesView: View {
    let application: ApplicationModel
    var client: CentralLibraryClientModel?
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onLocalSettings: () -> Void
    var onRemoteSettings: () -> Void

    private var workspaces: [CompanionExecutionWorkspace] {
        let values = client?.executionWorkspaces ?? application.companionHost.executionWorkspaces
        return values.sorted {
            let leftLocal = isLocal($0)
            let rightLocal = isLocal($1)
            if leftLocal != rightLocal { return leftLocal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func isLocal(_ workspace: CompanionExecutionWorkspace) -> Bool {
        if let client { return workspace.id == client.localExecution?.descriptor.id }
        return workspace.capabilities.contains("history.central.v1")
    }
    var body: some View {
        SettingsPage(title: "Workspaces", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsCard(title: "This Mac") {
                HStack(spacing: 12) {
                    DashboardLucideIcon(glyph: .monitor, size: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(client?.localExecution?.descriptor.name ?? "Local agent workspace").font(.system(size: 13, weight: .medium))
                        Text("Agents and files on this Mac").font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                    Button("Settings", action: onLocalSettings).buttonStyle(SettingsQuietButtonStyle())
                }
                if let client {
                    Toggle("Available to paired devices", isOn: Binding(get: { client.sharingLocalExecution }, set: { enabled in
                        Task { if enabled { await client.startLocalSharing() } else { await client.stopLocalSharing() } }
                    })).toggleStyle(DashboardSwitchToggleStyle()).disabled(client.localSharingBusy || client.localExecution == nil)
                }
            }
            let others = workspaces.filter { !isLocal($0) }
            if !others.isEmpty {
                SettingsCard(title: "Other workspaces") {
                    ForEach(others) { workspace in
                        HStack(spacing: 12) {
                            DashboardLucideIcon(glyph: workspace.kind == .linux ? .container : workspace.kind == .ios ? .smartphone : .monitor, size: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.name).font(.system(size: 13, weight: .medium))
                                Text(workspace.kind == .linux ? "Linux workspace" : workspace.kind == .mac ? "Mac workspace" : "iPhone or iPad workspace")
                                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            Spacer()
                            if let client {
                                if client.hasDirectAccess(workspace.id) {
                                    Text(client.directOnline.contains(workspace.id) ? "Connected" : "Disconnected")
                                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                                    Button("Open") { Task { await client.selectExecutionWorkspace(workspace.id); client.section = .chats } }
                                        .buttonStyle(SettingsQuietButtonStyle()).disabled(!client.directOnline.contains(workspace.id))
                                } else {
                                    Button("Connect") { Task { await client.enableDirectAccess(workspace.id) } }
                                        .buttonStyle(SettingsQuietButtonStyle()).disabled(!client.online || workspace.endpoint == nil)
                                }
                            }
                        }
                    }
                }
            }
            if client == nil {
                Button("Manage remote Linux workspaces", action: onRemoteSettings).buttonStyle(SettingsQuietButtonStyle())
            }
        }
        .task {
            if let client { await client.refresh() }
            else { await application.companionHost.refreshStatus() }
        }
    }
}
