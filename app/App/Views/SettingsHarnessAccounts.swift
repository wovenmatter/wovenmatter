import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsHarnessAccounts: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var initialWorkspaceID: UUID?
    var fixedWorkspace = false
    @State private var scope = "local"

    private var workspace: RemoteWorkspaceConfiguration? {
        model.remoteWorkspaces.workspaces.first { $0.id.uuidString == scope }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !fixedWorkspace {
            Picker("Account workspace", selection: $scope) {
                Text("This Mac").tag("local")
                ForEach(model.remoteWorkspaces.workspaces) { Text($0.name).tag($0.id.uuidString) }
            }.frame(maxWidth: 440, alignment: .leading)
            }
            if scope == "local" {
                SettingsCard(title: "Account", detail: "This Mac") {
                    SettingsHarnessSignInControl(model: model, runtimeKind: runtimeKind)
                }
                SettingsCard(title: "Software") {
                    SettingsLocalRuntimeInventoryRow(model: model, runtimeKind: runtimeKind)
                    if model.runtimeInventories[runtimeKind]?.isInstalled == false {
                        Button("Install") { model.installLocalACPRuntimeComponent(runtimeKind) }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(model.runtimeMaintenanceBusy(runtimeKind) || model.localRuntimeMaintenanceHasActiveConversation)
                    }
                    SettingsRuntimeMaintenanceErrorView(model: model, runtimeKind: runtimeKind)
                }
            } else if let workspace {
                SettingsRemoteHarnessAccountView(model: model.remoteWorkspaces,
                    runtimeKind: runtimeKind, workspace: workspace)
                SettingsRemoteHarnessSoftware(model: model.remoteWorkspaces, runtimeKind: runtimeKind, workspace: workspace)
            } else {
                SettingsEmpty("This workspace is no longer configured.")
            }
        }
        .task(id: initialWorkspaceID) { scope = initialWorkspaceID?.uuidString ?? "local" }
        .task(id: scope) {
            if let workspace { model.remoteWorkspaces.refresh(workspace) }
            else if scope == "local" { model.refreshRuntimeInventory() }
        }
        .modifier(HarnessInstallerConfirmation(model: model, workspaceID: workspace?.id))
    }
}

struct SettingsRemoteHarnessSoftware: View {
    @Bindable var model: RemoteWorkspacesModel
    let runtimeKind: AgentRuntimeKind
    let workspace: RemoteWorkspaceConfiguration
    private var busy: Bool { model.busyWorkspaceIDs.contains(workspace.id) }
    var body: some View {
        SettingsCard(title: "Software") {
            if let harness = model.currentHarnesses(for: workspace).first(where: { $0.id == runtimeKind }) {
                let runtime = model.runtimeMaintenance[workspace.id]?.first { $0.id == runtimeKind }
                if let runtime {
                    ForEach(runtime.components) { component in
                        SettingsValueRow(label: component.displayName, value: component.installedVersion ?? "Not installed")
                    }
                }
                HStack {
                    if runtime?.installed == true {
                        SettingsRemoteRuntimeUpdateButton(model: model, harness: harness, configuration: workspace)
                        if let runtime, !runtime.enabled {
                            Button("Use harness") { model.setRuntimePreferences(runtime, configuration: workspace, enabled: true) }
                                .buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                        }
                    } else {
                        Button(busy ? "Working…" : "Install") {
                            model.prepareHarnessAction("install", harness: harness, configuration: workspace)
                        }.buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                    }
                }
                if let error = model.actionErrors[workspace.id]?[runtimeKind] { SettingsError(error) }
                if let operation = runtime?.operation, operation.status == "failed", let error = operation.error {
                    SettingsError(error)
                }
            } else { SettingsEmpty("Connect this workspace to manage software.") }
        }
    }
}

/// Installer review stays attached to the surface that requested the install.
struct HarnessInstallerConfirmation: ViewModifier {
    @Bindable var model: ApplicationModel
    var workspaceID: UUID?
    func body(content: Content) -> some View {
        content
            .confirmationDialog("Review installer source", isPresented: Binding(
                get: { workspaceID == nil && model.preparedLocalACPRuntimeInstall != nil },
                set: { if !$0 { model.cancelPreparedLocalACPRuntimeInstall() } }
            ), titleVisibility: .visible) {
                Button("Confirm and install") { model.confirmPreparedLocalACPRuntimeInstall() }
                Button("Cancel", role: .cancel) { model.cancelPreparedLocalACPRuntimeInstall() }
            } message: {
                if let preview = model.preparedLocalACPRuntimeInstall?.preview {
                    Text("Source: \(preview.source.absoluteString)\n" + (preview.sha256.map { "SHA-256: \($0)" }
                        ?? "Package: \(preview.packageSpec ?? "") · Registry integrity verification applies."))
                }
            }
            .modifier(RemoteHarnessInstallerConfirmation(model: model.remoteWorkspaces, workspaceID: workspaceID))
    }
}

struct RemoteHarnessInstallerConfirmation: ViewModifier {
    @Bindable var model: RemoteWorkspacesModel
    let workspaceID: UUID?
    var onCancel: () -> Void = {}
    func body(content: Content) -> some View {
        content.confirmationDialog("Review installer source", isPresented: Binding(
            get: { workspaceID != nil && model.preparedHarnessAction?.configuration.id == workspaceID && model.preparedHarnessAction?.action == "install" },
            set: { if !$0 { cancel() } }
        ), titleVisibility: .visible) {
            Button("Confirm and install") { model.confirmPreparedHarnessAction(workspaceID: workspaceID, action: "install") }
            Button("Cancel", role: .cancel) { cancel() }
        } message: {
            if let preview = model.preparedHarnessAction?.preview {
                Text("Source: \(preview.source)\n" + (preview.sha256.map { "SHA-256: \($0)" }
                    ?? "Package: \(preview.packageSpec ?? "") · Registry integrity verification applies."))
            }
        }
    }
    private func cancel() {
        if model.preparedHarnessAction?.configuration.id == workspaceID {
            model.cancelPreparedHarnessAction(workspaceID: workspaceID, action: "install")
            onCancel()
        }
    }
}
