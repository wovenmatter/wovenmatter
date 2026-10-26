import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsHarnessAccounts: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    let scope: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsNote("Sign-in belongs to this harness on the selected workspace. Sharing chat settings does not change it.")
            DisclosureGroup("Account sharing") {
                SettingsNote(sharingDetail)
            }
            if scope == "global" || scope == "local" {
                SettingsCard(title: runtimeKind.displayName, detail: "Local agent workspace") {
                    SettingsHarnessSignInControl(model: model, runtimeKind: runtimeKind)
                    SettingsLocalRuntimeInventoryRow(model: model, runtimeKind: runtimeKind)
                    if model.runtimeInventories[runtimeKind]?.isInstalled == false {
                        Button("Install") { model.installLocalACPRuntimeComponent(runtimeKind) }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(model.runtimeMaintenanceBusy(runtimeKind) || model.localRuntimeMaintenanceHasActiveConversation)
                    }
                    SettingsRuntimeMaintenanceErrorView(model: model, runtimeKind: runtimeKind)
                }
                .task { model.refreshRuntimeInventory() }
                .modifier(HarnessInstallerConfirmation(model: model))
            }
            ForEach(model.remoteWorkspaces.workspaces.filter {
                scope == "global" || $0.id.uuidString.lowercased() == scope
            }) { workspace in
                if scope == "global" {
                    DisclosureGroup(workspace.name) { remote(workspace) }
                } else { remote(workspace) }
            }
            if scope != "global" && scope != "local",
               !model.remoteWorkspaces.workspaces.contains(where: { $0.id.uuidString.lowercased() == scope }) {
                SettingsEmpty("This workspace is no longer configured.")
            }
        }
    }

    private var sharingDetail: String {
        switch runtimeKind {
        case .codex:
            "Codex uses its own ChatGPT sign-in or OpenAI API key. An OpenAI API key can also be used in Pi Durable, but Woven Matter does not automatically copy it into Codex or sync Codex sign-ins between machines."
        case .claudeCode:
            "Claude Code uses Claude’s credentials on this machine. Pi Durable manages separate Claude profiles; both require native sign-in on each machine. Anthropic API keys are reusable, but are not automatically synced into Claude Code."
        case .grokBuild:
            "Grok Build uses its own Grok sign-in on each machine. Pi Durable’s Grok account sharing does not sign in Grok Build."
        case .opencode:
            "OpenCode manages accounts and API keys in its own service. Workspaces connected to the same service use that service’s accounts; separate services need their own setup. Pi Durable’s OpenCode API key is not automatically synced into OpenCode."
        default:
            "Accounts are managed by this harness on each workspace."
        }
    }

    private func remote(_ workspace: RemoteWorkspaceConfiguration) -> some View {
        SettingsCard(title: runtimeKind.displayName, detail: workspace.name) {
            SettingsRemoteHarnessAccountView(model: model.remoteWorkspaces,
                runtimeKind: runtimeKind, workspace: workspace, embedded: true)
            SettingsRemoteHarnessSoftware(model: model.remoteWorkspaces,
                runtimeKind: runtimeKind, workspace: workspace)
        }
        .task { model.remoteWorkspaces.refresh(workspace) }
        .modifier(HarnessInstallerConfirmation(model: model, workspaceID: workspace.id))
    }
}

struct SettingsRemoteHarnessSoftware: View {
    @Bindable var model: RemoteWorkspacesModel
    let runtimeKind: AgentRuntimeKind
    let workspace: RemoteWorkspaceConfiguration
    private var busy: Bool { model.busyWorkspaceIDs.contains(workspace.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
    @State private var confirming = false
    func body(content: Content) -> some View {
        content.confirmationDialog("Review installer source", isPresented: Binding(
            get: { !confirming && workspaceID != nil && model.preparedHarnessAction?.configuration.id == workspaceID && model.preparedHarnessAction?.action == "install" },
            set: { if !$0 && !confirming { cancel() } }
        ), titleVisibility: .visible) {
            Button("Confirm and install") {
                // Backend commands are asynchronous. Dismissing this dialog must
                // not cancel the setup queue before the confirmation arrives.
                confirming = true
                model.confirmPreparedHarnessAction(workspaceID: workspaceID, action: "install")
            }
            Button("Cancel", role: .cancel) { cancel() }
        } message: {
            if let preview = model.preparedHarnessAction?.preview {
                Text("Source: \(preview.source)\n" + (preview.sha256.map { "SHA-256: \($0)" }
                    ?? "Package: \(preview.packageSpec ?? "") · Registry integrity verification applies."))
            }
        }
        .onChange(of: model.preparedHarnessAction == nil) { _, cleared in
            if cleared { confirming = false }
        }
        .onChange(of: model.errorMessage) { _, error in
            if error != nil { confirming = false }
        }
    }
    private func cancel() {
        if model.preparedHarnessAction?.configuration.id == workspaceID {
            model.cancelPreparedHarnessAction(workspaceID: workspaceID, action: "install")
            onCancel()
        }
    }
}
