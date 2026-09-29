import SwiftUI
import WovenMatterClient

struct SettingsDefaultAgentSDKView: View {
    let connections: DefaultAgentSettingsModel
    let remoteWorkspaces: RemoteWorkspacesModel
    @State private var expanded: Set<String> = []

    private struct Workspace: Identifiable {
        let id: String
        let name: String
        let remoteID: UUID?
    }
    private var workspaces: [Workspace] {
        let local = Workspace(id: "local", name: "Local agent workspace", remoteID: nil)
        let remotes = remoteWorkspaces.workspaces.map {
            Workspace(id: $0.id.uuidString.lowercased(), name: $0.name, remoteID: $0.id)
        }
        if connections.scope == "global" { return [local] + remotes }
        return ([local] + remotes).filter { $0.id == connections.scope }
    }

    var body: some View {
        SettingsCard(title: "Agent SDKs", detail: "Running turns finish with their current SDK. Updates apply to subsequent turns.") {
            ForEach(workspaces) { workspace in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(workspace.id) }, set: { value in
                    if value {
                        expanded.insert(workspace.id)
                        let state = connections.sdks.state(for: workspace.id)
                        if state.status == nil && !state.busy { perform(.status, in: workspace) }
                    } else { expanded.remove(workspace.id) }
                })) {
                    workspaceContent(workspace).padding(.top, 10).padding(.bottom, 4)
                } label: {
                    HStack {
                        Text(workspace.name).font(.callout.weight(.medium))
                        if connections.sdks.state(for: workspace.id).busy { ProgressView().controlSize(.mini) }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder private func workspaceContent(_ workspace: Workspace) -> some View {
        let state = connections.sdks.state(for: workspace.id)
        VStack(alignment: .leading, spacing: 12) {
            if let status = state.status {
                ForEach(status.sdks) { sdk in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { sdkLabel(sdk); Spacer(minLength: 12); sdkActions(sdk, state: state, workspace: workspace) }
                        VStack(alignment: .leading, spacing: 8) { sdkLabel(sdk); sdkActions(sdk, state: state, workspace: workspace) }
                    }
                }
                if let notice = status.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            } else if !state.busy {
                Button("Load SDK versions") { perform(.status, in: workspace) }.buttonStyle(SettingsQuietButtonStyle())
            }
            if let operation = state.operation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress(operation)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = state.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func sdkLabel(_ sdk: DefaultAgentSDKStatus.SDK) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sdk.name).font(.callout.weight(.medium))
            Text(sdk.installedVersion.map { "Version \($0)" } ?? "Not installed").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if sdk.updateAvailable, let latest = sdk.latestVersion {
                Text("Version \(latest) available").font(.caption).foregroundStyle(.secondary)
            } else if sdk.latestVersion != nil {
                Text("Up to date").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sdkActions(_ sdk: DefaultAgentSDKStatus.SDK, state: DefaultAgentSDKWorkspaceState, workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            Button("Check for updates") { perform(.check, id: sdk.id, in: workspace) }
            if sdk.updateAvailable, let latest = sdk.latestVersion {
                Button("Update") { perform(.update, id: sdk.id, version: latest, in: workspace) }
                    .accessibilityLabel("Update \(sdk.name) in \(workspace.name)")
            }
        }.buttonStyle(SettingsQuietButtonStyle()).disabled(state.busy).fixedSize()
    }

    private func progress(_ request: DefaultAgentSDKRequest) -> String {
        let name = request.id == "claude" ? "Claude SDK" : request.id == "pi" ? "Pi SDK" : "SDKs"
        switch request.action {
        case .status: return "Loading SDK versions…"
        case .check: return "Checking \(name) for updates…"
        case .update: return "Updating \(name)…"
        }
    }

    private func perform(_ action: DefaultAgentSDKRequest.Action, id: String? = nil, version: String? = nil, in workspace: Workspace) {
        connections.sdks.request(.init(workspaceID: workspace.remoteID, request: .init(action: action, id: id, version: version)),
                                 connections: connections, remoteWorkspaces: remoteWorkspaces)
    }
}
