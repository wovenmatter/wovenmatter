import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsLocalWorkspaceView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onMore: (AgentRuntimeKind) -> Void
    @State private var pendingCredentialRuntime: AgentRuntimeKind?

    var body: some View {
        SettingsPage(
            title: "Local agent workspace",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsWorkspaceSidebarVisibilityControl(.localWorkspace)
            workspaceCard
            SettingsSignInStatusCard(statuses: model.localSignInStatuses, checking: model.checkingLocalSignIn, error: model.localSignInError, scope: "local") {
                Task { await model.refreshLocalSignInStatus() }
            }
            runtimesCard
        }
        .task { await model.openCode?.resolveExecutable(); model.refreshRuntimeInventory() }
        .confirmationDialog(
            "Relink \(model.pendingWorkspaceFolderChange?.folder.directoryName ?? "folder")?",
            isPresented: Binding(
                get: { model.pendingWorkspaceFolderChange != nil },
                set: { if !$0 { model.cancelWorkspaceFolderChange() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy files and relink") {
                model.confirmWorkspaceFolderChange(copyContents: true)
            }
            Button("Keep backup only") {
                model.confirmWorkspaceFolderChange(copyContents: false)
            }
            Button("Cancel", role: .cancel) { model.cancelWorkspaceFolderChange() }
        } message: {
            if let pending = model.pendingWorkspaceFolderChange {
                Text("The current \(pending.folder.directoryName) folder contains files. Relinking will save that folder as a backup inside your workspace and link to:\n\(pending.destination.path)\n\nYou can also copy its contents into the linked folder. Items with names already present there will stay in the backup; existing destination files will not be overwritten.")
            }
        }
        .confirmationDialog(
            "Review installer source",
            isPresented: Binding(
                get: { model.preparedLocalACPRuntimeInstall != nil },
                set: {
                    if !$0 { model.cancelPreparedLocalACPRuntimeInstall() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Confirm and install") {
                model.confirmPreparedLocalACPRuntimeInstall()
            }
            Button("Cancel", role: .cancel) {
                model.cancelPreparedLocalACPRuntimeInstall()
            }
        } message: {
            if let prepared = model.preparedLocalACPRuntimeInstall {
                if let sha256 = prepared.preview.sha256,
                   let bytes = prepared.preview.bytes {
                    Text(
                        "Source: \(prepared.preview.source.absoluteString)\n"
                            + "SHA-256: \(sha256)\n"
                            + "Size: \(bytes) bytes\n"
                            + "Woven Matter will download this source again and refuse to run it if the digest changes."
                    )
                } else if let packageSpec = prepared.preview.packageSpec {
                    Text(
                        "Source: \(prepared.preview.source.absoluteString)\n"
                            + "Package: \(packageSpec)\n"
                            + "npm registry integrity verification applies to this exact package version."
                    )
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { pendingCredentialRuntime != nil },
                set: { if !$0 { pendingCredentialRuntime = nil } }
            )
        ) {
            if let runtimeKind = pendingCredentialRuntime {
                CredentialAccessDisclosureView(
                    purpose: "Allow Woven Matter to start \(runtimeKind.displayName) and check credentials managed by its CLI.",
                    onEnable: {
                        model.acknowledgeCredentialAccessDisclosure()
                        pendingCredentialRuntime = nil
                        model.enableLocalACPRuntimeCredentialAccess(runtimeKind)
                    },
                    onCancel: { pendingCredentialRuntime = nil }
                )
            }
        }
    }

    private var workspaceCard: some View {
        SettingsCard(
            title: "Workspace",
            detail: "Local agents share this folder."
        ) {
            SettingsInset {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Local agent workspace")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        SettingsPill(
                            model.localACPWorkspaceAvailability.isReady
                                ? "Ready"
                                : "Setup required",
                            tone: model.localACPWorkspaceAvailability.isReady
                                ? .neutral
                                : .warning
                        )
                    }
                    SettingsValueRow(
                        label: "Agent home",
                        value: model.localACPWorkspaceAvailability.rootPath
                            ?? "~/.woven-matter"
                    )
                    SettingsValueRow(
                        label: "Repositories",
                        value: model.localACPWorkspaceAvailability
                            .repositoriesPath ?? "~/.woven-matter/Repos"
                    )
                    SettingsValueRow(
                        label: "Databases",
                        value: model.localACPWorkspaceAvailability
                            .databasesPath ?? "~/.woven-matter/Databases"
                    )
                    Text(model.localACPWorkspaceAvailability.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        WorkspaceFolderActions {
                            Button("Choose repositories folder") {
                                chooseLocalACPRepositories()
                            }
                            .buttonStyle(SettingsQuietButtonStyle())

                            if model.localACPWorkspaceAvailability
                                .usesExternalRepositories {
                                Button("Use default Repos") {
                                    model.configureLocalACPRepositories(nil)
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                            }
                        }

                        WorkspaceFolderActions {
                            Button("Choose databases folder") {
                                chooseLocalACPDatabases()
                            }
                            .buttonStyle(SettingsQuietButtonStyle())

                            if model.localACPWorkspaceAvailability
                                .usesExternalDatabases {
                                Button("Use default Databases") {
                                    model.configureLocalACPDatabases(nil)
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                            }

                            Button("Open workspace") {
                                openLocalACPWorkspace()
                            }
                            .buttonStyle(SettingsQuietButtonStyle())
                        }
                    }
                    .disabled(model.workspaceFolderChangeInProgress)

                    if let error = model.workspaceFolderChangeError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.workspaceFolderChangeInProgress {
                        Text("Changing folder…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    if let recovery = model.workspaceFolderRecovery,
                       let backup = recovery.backupURL {
                        Text("Previous files saved in \(backup.lastPathComponent).")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .textSelection(.enabled)
                        if !recovery.skippedItemNames.isEmpty {
                            Text("Already present in the destination; kept in the backup: \(recovery.skippedItemNames.joined(separator: ", ")).")
                                .font(.system(size: 11.5))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                                .textSelection(.enabled)
                        }
                        Button("Open backup") { NSWorkspace.shared.open(backup) }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }

                    if !model.localACPWorkspaceAvailability.isReady {
                        Button("Retry setup") {
                            model.setUpLocalACPWorkspace(
                                homeDirectory: FileManager.default
                                    .homeDirectoryForCurrentUser
                            )
                        }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                        .disabled(model.workspaceFolderChangeInProgress)
                    }
                }
            }

        }
    }

    private var runtimesCard: some View {
        SettingsCard(title: "Runtimes") {
            ForEach(
                LocalACPRuntimeCatalog.definitions.sorted {
                    $0.runtimeKind.presentationRank < $1.runtimeKind.presentationRank
                }
            ) { definition in
                if definition.runtimeKind == .defaultAgent {
                    SettingsInset {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Built-in").font(.system(size: 13, weight: .medium))
                                Text("Built into Woven Matter.").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Settings") { onMore(.defaultAgent) }.buttonStyle(SettingsQuietButtonStyle())
                        }
                    }
                } else if definition.runtimeKind == .opencode {
                    openCodeRuntimeRow
                } else {
                let availability = model.localACPRuntimeAvailability.first {
                    $0.runtimeKind == definition.runtimeKind
                }
                let inventory = model.runtimeInventories[definition.runtimeKind]
                let installing = model.installingLocalACPRuntimeKinds.contains(definition.runtimeKind)
                let isChecking = model.checkingLocalACPRuntimeKinds.contains(
                    definition.runtimeKind
                )
                let databaseIsReady = model.isLocalACPAgentReady(
                    definition.runtimeKind
                )
                let isReady = !isChecking
                    && availability?.isReady == true
                    && databaseIsReady
                SettingsInset {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(definition.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                SettingsPill(
                                    isChecking
                                        ? "Checking"
                                        : !model.isLocalACPRuntimeCredentialAccessEnabled(
                                            definition.runtimeKind
                                        ) && availability?.executablePath != nil
                                            ? "Not enabled"
                                        : availability?.isReady == true && !databaseIsReady
                                            ? "Workspace unavailable"
                                            : localACPRuntimeStatusLabel(availability),
                                    tone: isReady
                                        ? .neutral
                                        : .warning
                                )
                            }
                            if availability?.isReady == true && !databaseIsReady,
                               let error = model.localACPAgentReconciliationError {
                                Text(error).font(.system(size: 11))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            if let inventory {
                                Text(inventory.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if model.checkedRuntimeKinds.contains(definition.runtimeKind), inventory.latestUnavailable {
                                    Text("Couldn’t check for updates.").font(.system(size: 11))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                }
                            }
                            if model.runtimeFailures[definition.runtimeKind, default: 0] >= 2 {
                                Button("Copy diagnostic") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.runtimeDiagnostic(definition.runtimeKind), forType: .string)
                                }.buttonStyle(SettingsQuietButtonStyle())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        RuntimeMaintenanceActions {
                            Button("Settings") { onMore(definition.runtimeKind) }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .accessibilityLabel("Open \(definition.displayName) settings")
                            SettingsLocalRuntimeUpdateButton(
                                model: model,
                                runtimeKind: definition.runtimeKind
                            )
                            let isShown = model.isLocalACPRuntimeShown(
                                definition.runtimeKind
                            )
                            Button(isShown ? "Hide" : "Show") {
                                model.setLocalACPRuntimeShown(
                                    !isShown,
                                    runtimeKind: definition.runtimeKind
                                )
                            }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .accessibilityLabel(
                                "\(isShown ? "Hide" : "Show") \(definition.displayName) in the left sidebar"
                            )
                            .accessibilityHint(
                                isShown
                                    ? "Removes the runtime from the Local agent workspace sidebar without changing its enabled state."
                                    : "Adds the runtime to the Local agent workspace sidebar without changing its enabled state."
                            )

                            if inventory?.isInstalled != true {
                                if model.isLocalACPRuntimeCredentialAccessEnabled(definition.runtimeKind) {
                                    Button("Disable") { model.disableLocalACPRuntimeCredentialAccess(definition.runtimeKind) }
                                        .buttonStyle(SettingsQuietButtonStyle())
                                }
                                Button(installing ? "Installing…" : inventory == nil ? "Checking…" : model.runtimeFailures[definition.runtimeKind, default: 0] > 0 ? "Retry install" : "Install") {
                                    model.installLocalACPRuntimeComponent(definition.runtimeKind)
                                }
                                .buttonStyle(DashboardPrimaryButtonStyle())
                                .disabled(inventory == nil || model.checkingRuntimeInventory || !model.installingLocalACPRuntimeKinds.isEmpty || model.localRuntimeMaintenanceHasActiveConversation)
                            } else if model.isLocalACPRuntimeCredentialAccessEnabled(definition.runtimeKind) {
                                Button("Disable") {
                                    model.disableLocalACPRuntimeCredentialAccess(
                                        definition.runtimeKind
                                    )
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                            } else {
                                Button(isChecking ? "Checking…" : "Enable") {
                                    if model.hasAcknowledgedCredentialAccessDisclosure {
                                        model.enableLocalACPRuntimeCredentialAccess(
                                            definition.runtimeKind
                                        )
                                    } else {
                                        pendingCredentialRuntime =
                                            definition.runtimeKind
                                    }
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .disabled(isChecking || !model.installingLocalACPRuntimeKinds.isEmpty || inventory?.isInstalled != true)
                            }
                        }
                    }
                }
                }
            }

            if let error = model.openCode?.error { SettingsError(error) }
            if let error = model.localRunError {
                SettingsError(error)
            }
        }
    }

    private var openCodeRuntimeRow: some View {
        SettingsInset {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("OpenCode").font(.system(size: 13, weight: .medium))
                        SettingsPill(model.openCode?.isEnabled == true ? "Enabled" : "Not enabled",
                            tone: model.openCode?.isEnabled == true ? .neutral : .warning)
                    }
                    Text(model.runtimeInventories[.opencode]?.summary ?? "Checking the local OpenCode v2 installation…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.checkedRuntimeKinds.contains(.opencode), model.runtimeInventories[.opencode]?.latestUnavailable == true {
                        Text("Couldn’t check for updates.").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    if model.openCode?.installationFailures ?? 0 >= 2 {
                        Button("Copy diagnostic") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.openCode?.installationDiagnostic ?? model.runtimeDiagnostic(.opencode), forType: .string)
                        }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RuntimeMaintenanceActions {
                    Button("Settings") { onMore(.opencode) }
                        .accessibilityLabel("Open OpenCode settings")
                    SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: .opencode)
                    let shown = model.isLocalACPRuntimeShown(.opencode)
                    Button(shown ? "Hide" : "Show") { model.setLocalACPRuntimeShown(!shown, runtimeKind: .opencode) }
                        .accessibilityLabel("\(shown ? "Hide" : "Show") OpenCode in the left sidebar")
                    Button(model.openCode?.isInstalling == true ? "Downloading…" : model.runtimeInventories[.opencode]?.isInstalled != true ? "Install" : model.openCode?.isEnabled == true ? "Disable" : "Enable") {
                        guard let openCode = model.openCode else { return }
                        openCode.perform {
                            if model.runtimeInventories[.opencode]?.isInstalled != true { try await openCode.download(); model.refreshRuntimeInventory() }
                            else if openCode.isEnabled { await openCode.disable() }
                            else { try await openCode.connectLocal() }
                        }
                    }
                    .disabled(model.runtimeInventories[.opencode] == nil || !model.installingLocalACPRuntimeKinds.isEmpty || model.openCode == nil || model.openCode?.isConnecting == true || model.openCode?.isInstalling == true || model.openCode?.isControllingServer == true)
                }
                .buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }

    private func localACPRuntimeStatusLabel(
        _ availability: LocalACPRuntimeAvailability?
    ) -> String {
        guard let availability else { return "Checking" }
        return switch availability.state {
        case .ready:
            "Installed"
        case .cliMissing:
            "CLI required"
        case .adapterMissing:
            "Adapter required"
        case .adapterOutdated:
            "Update required"
        case .authenticationRequired:
            "Sign in required"
        case .executableUnavailable:
            "Setup required"
        }
    }

    private func chooseLocalACPRepositories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Repositories Folder"
        panel.message = "Choose an existing folder for repositories used only by direct chats on this Mac."
        Task {
            guard await panel.begin() == .OK,
                  let repositories = panel.url else { return }
            model.configureLocalACPRepositories(repositories)
        }
    }

    private func chooseLocalACPDatabases() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Databases Folder"
        panel.message = "Choose an existing folder for databases used by direct chats on this Mac."
        Task {
            guard await panel.begin() == .OK,
                  let databases = panel.url else { return }
            model.configureLocalACPDatabases(databases)
        }
    }

    private func openLocalACPWorkspace() {
        let root = model.localACPWorkspaceAvailability.rootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter")
        NSWorkspace.shared.open(root)
    }
}

private struct RuntimeMaintenanceActions<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: content)
            VStack(alignment: .trailing, spacing: 8, content: content)
        }
    }
}

private struct WorkspaceFolderActions<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: content)
            VStack(alignment: .leading, spacing: 8, content: content)
        }
    }
}
