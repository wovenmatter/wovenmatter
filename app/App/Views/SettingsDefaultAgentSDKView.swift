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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(workspaces) { workspace in
                let state = connections.sdks.state(for: workspace.id)
                if workspace.remoteID == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if connections.scope == "global" {
                            workspaceLabel(workspace, state: state)
                        }
                        workspaceContent(workspace, state: state)
                    }
                    .padding(.vertical, 3)
                    .task {
                        let state = connections.sdks.state(for: workspace.id)
                        if state.status == nil && !state.busy { perform(.status, in: workspace) }
                    }
                } else {
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(workspace.id) }, set: { value in
                        if value {
                            expanded.insert(workspace.id)
                            let state = connections.sdks.state(for: workspace.id)
                            if state.status == nil && !state.busy { perform(.status, in: workspace) }
                        } else { expanded.remove(workspace.id) }
                    })) {
                        if expanded.contains(workspace.id) {
                            workspaceContent(workspace, state: state).padding(.top, 10).padding(.bottom, 4)
                        }
                    } label: {
                        workspaceLabel(workspace, state: state)
                    }
                    .disclosureGroupStyle(SettingsDisclosureGroupStyle())
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func workspaceLabel(_ workspace: Workspace, state: DefaultAgentSDKWorkspaceState) -> some View {
        HStack {
            Text(workspace.name).font(.callout.weight(.medium))
            if state.busy { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder private func workspaceContent(_ workspace: Workspace, state: DefaultAgentSDKWorkspaceState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let hasUpdate = state.status?.sdks.contains { $0.updateAvailable || $0.consistent == false } == true
            let summary = state.status?.sdks.map { sdk in
                let installed = sdk.installedVersion ?? "Not installed"
                let update = sdk.updateAvailable ? sdk.latestVersion.map { " → \($0)" } ?? "" : ""
                return "\(sdk.displayName) \(installed)\(update)"
            }.joined(separator: " · ") ?? "Checking installed components…"
            SettingsRuntimeSummaryRow(runtimeKind: .defaultAgent, summary: summary,
                status: state.busy ? (state.operation?.action == .update ? "Updating" : "Checking")
                    : state.status == nil ? "Not checked"
                    : state.status?.sdks.allSatisfy({ $0.installedVersion != nil }) == true ? "Installed" : "Not installed") {
                Button(state.busy ? (state.operation?.action == .update ? "Updating…" : "Checking…")
                    : hasUpdate ? "Update" : "Check for updates") {
                    perform(hasUpdate ? .update : .check, in: workspace)
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(state.busy)
            }
            if let notice = state.status?.notice { SettingsNote(notice) }
            ForEach(state.status?.sdks.filter { $0.notice != nil } ?? []) { sdk in
                SettingsNote("\(sdk.displayName): \(sdk.notice ?? "")")
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

    private func progress(_ request: DefaultAgentSDKRequest) -> String {
        switch request.action {
        case .status: return "Loading versions…"
        case .check: return "Checking for updates…"
        case .update: return "Updating Pi Durable…"
        }
    }

    private func perform(_ action: DefaultAgentSDKRequest.Action, id: String? = nil, version: String? = nil, in workspace: Workspace) {
        connections.sdks.request(.init(workspaceID: workspace.remoteID, request: .init(action: action, id: id, version: version)),
                                 connections: connections, remoteWorkspaces: remoteWorkspaces)
    }
}
