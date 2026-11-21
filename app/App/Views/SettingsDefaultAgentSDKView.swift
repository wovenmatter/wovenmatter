import SwiftUI

/// The Pi Durable SDK on each machine in scope: this Mac inline, the others folded.
struct SettingsDefaultAgentSDKView: View {
    let connections: AgentSettingsStore
    let machines: [Machine]
    @State private var expanded: Set<String> = []

    private var inScope: [Machine] {
        connections.scope == "global" ? machines : machines.filter { $0.id == connections.scope }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(inScope) { workspace in
                let state = connections.sdkState(on: workspace.id)
                if workspace.isThisMachine {
                    VStack(alignment: .leading, spacing: 10) {
                        if connections.scope == "global" {
                            workspaceLabel(workspace, state: state)
                        }
                        workspaceContent(workspace, state: state)
                    }
                    .padding(.vertical, 3)
                    .task {
                        let state = connections.sdkState(on: workspace.id)
                        if state.status == nil && !state.busy { perform(.status, in: workspace) }
                    }
                } else {
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(workspace.id) }, set: { value in
                        if value {
                            expanded.insert(workspace.id)
                            let state = connections.sdkState(on: workspace.id)
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

    private func workspaceLabel(_ workspace: Machine, state: PiDurableSDKState) -> some View {
        HStack {
            Text(workspace.name).font(.settingsBody.weight(.medium))
            if state.busy { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder private func workspaceContent(_ workspace: Machine, state: PiDurableSDKState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let hasUpdate = state.status?.sdks.contains { $0.updateAvailable || $0.consistent == false } == true
            let summary = state.status?.sdks.map { sdk in
                let installed = sdk.installedVersion ?? "Not installed"
                let update = sdk.updateAvailable ? sdk.latestVersion.map { " → \($0)" } ?? "" : ""
                return "\(sdk.displayName) \(installed)\(update)"
            }.joined(separator: " · ") ?? "Checking installed components…"
            SettingsRuntimeSummaryRow(summary: summary,
                status: state.busy ? (state.operation == .update ? "Updating" : "Checking")
                    : state.status == nil ? "Not checked"
                    : state.status?.sdks.allSatisfy({ $0.installedVersion != nil }) == true ? "Installed" : "Not installed",
                tone: state.status?.sdks.allSatisfy({ $0.installedVersion != nil }) == true ? .good : .neutral) {
                Button(state.busy ? (state.operation == .update ? "Updating…" : "Checking…")
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
                    Text(progress(operation)).font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                }
            }
            if let error = state.error { Text(error).font(.settingsBody).foregroundStyle(WovenPalette.danger).textSelection(.enabled) }
        }
    }

    private func progress(_ action: PiDurableSDKAction) -> String {
        switch action {
        case .status: return "Loading versions…"
        case .check: return "Checking for updates…"
        case .update: return "Updating Pi Durable…"
        }
    }

    private func perform(_ action: PiDurableSDKAction, in machine: Machine) {
        connections.requestSDK(action, on: machine.id)
    }
}
