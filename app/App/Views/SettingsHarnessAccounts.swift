import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// One harness's account, then its software and diagnostics. This is the only place
/// these controls live; workspace pages show status and link here.
struct SettingsHarnessAccounts: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    let scope: String

    private var remotes: [RemoteWorkspaceConfiguration] {
        model.remoteWorkspaces.workspaces.filter {
            scope == "global" || $0.id.uuidString.lowercased() == scope
        }
    }

    private var showsLocal: Bool { scope == "global" || scope == "local" }

    var body: some View {
        SettingsSection(title: "\(runtimeKind.displayName) account") {
            if showsLocal {
                localLabel
                SettingsHarnessSignInControl(model: model, runtimeKind: runtimeKind)
            }
            ForEach(remotes) { workspace in
                perWorkspace(workspace) {
                    SettingsRemoteHarnessAccountView(model: model.remoteWorkspaces,
                        runtimeKind: runtimeKind, workspace: workspace, embedded: true)
                }
                .task { model.remoteWorkspaces.refresh(workspace) }
            }
            if !showsLocal, remotes.isEmpty {
                SettingsEmpty("This workspace is no longer configured.")
            }
            SettingsHelp {
                SettingsNote("Sign-in belongs to this harness on the selected workspace. Sharing chat settings does not change it.")
                SettingsNote(sharingDetail)
            }
        }
        if showsLocal || !remotes.isEmpty {
            SettingsSection(title: "Software") {
                if showsLocal {
                    localLabel
                    localContent
                }
                ForEach(remotes) { workspace in
                    perWorkspace(workspace) {
                        SettingsRemoteHarnessSoftware(model: model.remoteWorkspaces,
                            runtimeKind: runtimeKind, workspace: workspace)
                    }
                    .modifier(HarnessInstallerConfirmation(model: model, workspaceID: workspace.id))
                }
            }
        }
    }

    /// With remote workspaces listed too, this Mac's part gets a label.
    @ViewBuilder private var localLabel: some View {
        if scope == "global" && !remotes.isEmpty {
            Text("Local workspace")
                .font(.settingsBody)
                .foregroundStyle(DashboardPalette.mutedForeground)
        }
    }

    /// Each remote workspace folds into a row when several are listed.
    @ViewBuilder private func perWorkspace<Content: View>(
        _ workspace: RemoteWorkspaceConfiguration, @ViewBuilder content: () -> Content
    ) -> some View {
        if scope == "global" {
            SettingsSummaryRow(workspace.name) { content() }
        } else {
            content()
        }
    }

    @ViewBuilder private var localContent: some View {
        SettingsLocalRuntimeInventoryRow(model: model, runtimeKind: runtimeKind)
            .task { model.refreshRuntimeInventory() }
            .modifier(HarnessInstallerConfirmation(model: model))
        if model.checkedRuntimeKinds.contains(runtimeKind), model.runtimeInventories[runtimeKind]?.latestUnavailable == true {
            SettingsNote("Couldn’t check for updates.")
        }
        SettingsRuntimeMaintenanceErrorView(model: model, runtimeKind: runtimeKind)
        if model.runtimeFailures[runtimeKind, default: 0] >= 2
            || (runtimeKind == .opencode && (model.openCode?.installationFailures ?? 0) >= 2) {
            Button("Copy diagnostic") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(runtimeKind == .opencode
                    ? model.openCode?.installationDiagnostic ?? model.runtimeDiagnostic(runtimeKind)
                    : model.runtimeDiagnostic(runtimeKind), forType: .string)
            }
            .buttonStyle(SettingsQuietButtonStyle())
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

}

struct SettingsRemoteHarnessSoftware: View {
    @Bindable var model: RemoteWorkspacesModel
    let runtimeKind: AgentRuntimeKind
    let workspace: RemoteWorkspaceConfiguration

    private func componentVersion(_ component: RemoteRuntimeComponent) -> String {
        let installed = component.installed ? (component.installedVersion ?? "version unavailable") : "missing"
        let newer = component.availableUpdateVersion
        return "\(component.displayName) \(installed)" + (newer.map { " → \($0)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let harness = model.currentHarnesses(for: workspace).first(where: { $0.id == runtimeKind }) {
                let runtime = model.runtimeMaintenance[workspace.id]?.first { $0.id == runtimeKind }
                let checking = model.checkingRuntimeIDs[workspace.id]?.contains(runtimeKind) == true
                let running = runtime?.operation?.status == "running"
                let unavailable = model.isRuntimeInventoryUnavailable(runtimeKind, configuration: workspace)
                let busy = model.busyWorkspaceIDs.contains(workspace.id) || running || checking
                SettingsRuntimeSummaryRow(
                    summary: runtime?.components.map(componentVersion).joined(separator: " · ") ?? "Checking installed components…",
                    status: runtime?.installed == true ? "Installed" : runtime == nil ? "Checking" : "Not installed",
                    tone: runtime?.installed == true ? .good : runtime == nil ? .neutral : .warning
                ) {
                    if let runtime, !runtime.installed {
                        Button(running && runtime.operation?.action == "install" ? "Installing…" : (runtime.failureCount > 0 ? "Retry install" : "Install")) {
                            model.prepareHarnessAction("install", harness: harness, configuration: workspace)
                        }.buttonStyle(SettingsQuietButtonStyle()).disabled(busy || unavailable)
                    } else if runtime?.source != "system" {
                        SettingsRemoteRuntimeUpdateButton(model: model, harness: harness, configuration: workspace)
                    } else {
                        Text("Managed on host").font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
                .help(runtime?.components.compactMap(\.path).joined(separator: "\n") ?? "")
                if let runtime {
                    ForEach(runtime.components) { component in
                        if workspace.kind == .host, component.source == "system", let path = component.path {
                            SettingsNote("Using \(path) (installed on host)")
                        }
                    }
                    if model.runtimeCheckErrors[workspace.id]?[runtimeKind] != nil || runtime.versionCheckAvailable == false {
                        SettingsNote("Couldn’t check for updates.")
                    }
                    if runtime.failureCount >= 2, let prompt = runtime.diagnosticPrompt {
                        Button("Copy diagnostic prompt") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                        }.buttonStyle(SettingsQuietButtonStyle())
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
                if let prepared = model.preparedLocalACPRuntimeInstall {
                    if let sha256 = prepared.preview.sha256, let bytes = prepared.preview.bytes {
                        Text("Source: \(prepared.preview.source.absoluteString)\n"
                            + "SHA-256: \(sha256)\n"
                            + "Size: \(bytes) bytes\n"
                            + "Woven Matter will download this source again and refuse to run it if the digest changes.")
                    } else if let packageSpec = prepared.preview.packageSpec {
                        Text("Source: \(prepared.preview.source.absoluteString)\n"
                            + "Package: \(packageSpec)\n"
                            + "npm registry integrity verification applies to this exact package version.")
                    }
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
