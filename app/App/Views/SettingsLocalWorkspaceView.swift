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
            title: "Local Agent Workspace",
            detail: "Run Codex, Claude Code, Cursor, Grok Build, Hermes, OpenClaw, OpenCode, or Pi as direct sessions on this Mac.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            workspaceCard
            runtimesCard
        }
        .task { await model.openCode?.resolveExecutable(); model.refreshRuntimeInventory() }
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
            Button("Confirm and Install") {
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
                    purpose: "Enable \(runtimeKind.displayName) as a local harness. Woven Matter can then start its CLI and check the account credentials that CLI manages.",
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
            detail: "The home folder direct sessions share, and where their repositories and databases live."
        ) {
            SettingsInset {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Local Agent Workspace")
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
                            .repositoriesPath ?? "~/.woven-matter/REPOS"
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

                    if model.localACPWorkspaceAvailability.isReady {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button("Choose Repositories Folder") {
                                    chooseLocalACPRepositories()
                                }
                                .buttonStyle(SettingsQuietButtonStyle())

                                if model.localACPWorkspaceAvailability
                                    .usesExternalRepositories {
                                    Button("Use Default REPOS") {
                                        model.configureLocalACPRepositories(nil)
                                    }
                                    .buttonStyle(SettingsQuietButtonStyle())
                                }
                            }

                            HStack(spacing: 8) {
                                Button("Choose Databases Folder") {
                                    chooseLocalACPDatabases()
                                }
                                .buttonStyle(SettingsQuietButtonStyle())

                                if model.localACPWorkspaceAvailability
                                    .usesExternalDatabases {
                                    Button("Use Default Databases") {
                                        model.configureLocalACPDatabases(nil)
                                    }
                                    .buttonStyle(SettingsQuietButtonStyle())
                                }

                                Button("Open Workspace") {
                                    openLocalACPWorkspace()
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                            }
                        }
                    } else {
                        Button("Retry Setup") {
                            model.setUpLocalACPWorkspace(
                                homeDirectory: FileManager.default
                                    .homeDirectoryForCurrentUser
                            )
                        }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                    }
                }
            }

            SettingsNote("Direct chats start in ~/.woven-matter and share its workspace files. Conversation transcripts stay in Woven Matter’s local database.")
        }
    }

    private var runtimesCard: some View {
        SettingsCard(
            title: "Runtimes",
            detail: "Woven Matter discovers installed CLIs and adapters automatically and can install what’s missing."
        ) {
            ForEach(LocalACPRuntimeCatalog.definitions) { definition in
                if definition.runtimeKind == .opencode {
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
                            Text(
                                isChecking
                                    ? "Checking ACP availability…"
                                    : availability?.isReady == true && !databaseIsReady
                                        ? model.localACPAgentReconciliationError
                                            ?? "The local workspace could not save this agent."
                                        : (availability?.detail
                                            ?? definition.adapterDescription)
                            )
                                .font(.system(size: 11.5))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if let inventory {
                                if definition.runtimeKind == .hermes, let limitation = inventory.limitation {
                                    Text(limitation).font(.system(size: 11))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let notice = inventory.updateNotice {
                                    Text(notice).font(.system(size: 11))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(inventory.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if model.isLocalACPRuntimeCredentialAccessEnabled(definition.runtimeKind), inventory.latestUnavailable {
                                    Text("Some latest versions are unavailable.")
                                        .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                }
                            }
                        }
                        .help(inventory?.limitation ?? definition.adapterDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        RuntimeMaintenanceActions {
                            if definition.runtimeKind == .openclaw {
                                Button("More") { onMore(.openclaw) }
                                    .buttonStyle(SettingsQuietButtonStyle())
                                    .accessibilityLabel("More OpenClaw settings")
                            }
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
                                    ? "Removes the runtime from the Local Agent Workspace sidebar without changing its enabled state."
                                    : "Adds the runtime to the Local Agent Workspace sidebar without changing its enabled state."
                            )

                            if model.runtimeFailures[definition.runtimeKind, default: 0] >= 2 {
                                Button("Copy diagnostic") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.runtimeDiagnostic(definition.runtimeKind), forType: .string)
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                            }
                            if inventory?.manualUpdateAvailable == true {
                                Link("Update guide", destination: URL(string: "https://nousresearch.github.io/hermes-agent/docs/getting-started/updating/")!)
                                    .buttonStyle(SettingsQuietButtonStyle())
                            }
                            if inventory?.outdated == true, inventory?.isInstalled == true,
                               model.isLocalACPRuntimeCredentialAccessEnabled(definition.runtimeKind) {
                                Button(installing ? "Updating…" : "Update") { model.updateRuntime(definition.runtimeKind) }
                                    .buttonStyle(SettingsQuietButtonStyle())
                                    .disabled(!model.installingLocalACPRuntimeKinds.isEmpty || !model.localRunningConversationIDs.isEmpty)
                            }
                            if inventory?.isInstalled != true {
                                if model.isLocalACPRuntimeCredentialAccessEnabled(definition.runtimeKind) {
                                    Button("Disable") { model.disableLocalACPRuntimeCredentialAccess(definition.runtimeKind) }
                                        .buttonStyle(SettingsQuietButtonStyle())
                                }
                                Button(installing ? "Installing…" : inventory == nil ? "Checking…" : "Install") {
                                    model.installLocalACPRuntimeComponent(definition.runtimeKind)
                                }
                                .buttonStyle(DashboardPrimaryButtonStyle())
                                .disabled(inventory == nil || !model.installingLocalACPRuntimeKinds.isEmpty || !model.localRunningConversationIDs.isEmpty)
                            } else if model.isLocalACPRuntimeCredentialAccessEnabled(definition.runtimeKind) {
                                if !isReady {
                                    Button("Recheck") { model.refreshLocalACPRuntimesNow(); model.refreshRuntimeInventory() }
                                        .buttonStyle(SettingsQuietButtonStyle()).disabled(isChecking)
                                }
                                Button("Disable") {
                                    model.disableLocalACPRuntimeCredentialAccess(
                                        definition.runtimeKind
                                    )
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                            } else {
                                let credentialAccessEnabled = model
                                    .isLocalACPRuntimeCredentialAccessEnabled(
                                        definition.runtimeKind
                                    )
                                Button(
                                    isChecking ? "Checking…"
                                        : credentialAccessEnabled ? "Recheck" : "Enable"
                                ) {
                                    if credentialAccessEnabled {
                                        model.refreshLocalACPRuntimesNow()
                                    } else if model
                                        .hasAcknowledgedCredentialAccessDisclosure {
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

            SettingsNote("Checks run at startup and when reopening the app. Updates run only when requested. Manage remote runtimes in their Remote Workspace settings. Buzz is managed separately.")
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
                    Text(model.runtimeInventories[.opencode]?.limitation ?? "Uses the local OpenCode v2 service.")
                        .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RuntimeMaintenanceActions {
                    Button("More") { onMore(.opencode) }
                        .accessibilityLabel("More OpenCode settings")
                    let shown = model.isLocalACPRuntimeShown(.opencode)
                    Button(shown ? "Hide" : "Show") { model.setLocalACPRuntimeShown(!shown, runtimeKind: .opencode) }
                        .accessibilityLabel("\(shown ? "Hide" : "Show") OpenCode in the left sidebar")
                    if model.openCode?.installationFailures ?? 0 >= 2 {
                        Button("Copy diagnostic") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.openCode?.installationDiagnostic ?? model.runtimeDiagnostic(.opencode), forType: .string)
                        }
                    }
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
            "Ready"
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

    private func localACPInstallButtonLabel(
        _ availability: LocalACPRuntimeAvailability
    ) -> String {
        if availability.needsCLIInstallation {
            return "Install CLI"
        }
        return availability.state == .adapterOutdated
            ? "Update Adapter"
            : "Install Adapter"
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
        guard let path = model.localACPWorkspaceAvailability.rootPath else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
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
