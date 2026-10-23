import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsLocalWorkspaceView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onMore: (AgentRuntimeKind) -> Void

    var body: some View {
        SettingsPage(
            title: "Local Agent Workspace",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsWorkspaceSidebarVisibilityControl(.localWorkspace)
            workspaceCard
            runtimesCard
            SettingsSignInStatusCard(statuses: model.localSignInStatuses, checking: model.checkingLocalSignIn, error: model.localSignInError, scope: "local") {
                Task { await model.refreshLocalSignInStatus() }
            }
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
    }

    private var workspaceCard: some View {
        SettingsCard(title: "Workspace", detail: "Create a blank project or link an existing directory from the sidebar.") {
            SettingsInset {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Local agent workspace")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        SettingsPill(model.localACPWorkspaceAvailability.isReady ? "Ready" : "Setup required",
                            tone: model.localACPWorkspaceAvailability.isReady ? .neutral : .warning)
                    }
                    if let path = model.localACPWorkspaceAvailability.rootPath {
                        SettingsValueRow(label: "Agent home", value: path)
                    }
                    if !model.localACPWorkspaceAvailability.isReady {
                        SettingsNote(model.localACPWorkspaceAvailability.detail)
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
                                Text(AgentRuntimeKind.defaultAgent.displayName).font(.system(size: 13, weight: .medium))
                                Text("Included with Woven Matter.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
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
                                Text(error).font(.system(size: 11.5))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            if let inventory {
                                Text(inventory.summary)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if model.checkedRuntimeKinds.contains(definition.runtimeKind), inventory.latestUnavailable {
                                    Text("Couldn’t check for updates.").font(.system(size: 11.5))
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
                                    ? "Removes the runtime from the Local agent workspace sidebar without uninstalling it."
                                    : "Adds the runtime to the Local agent workspace sidebar without uninstalling it."
                            )

                            if inventory?.isInstalled != true {
                                Button(installing ? "Installing…" : inventory == nil ? "Checking…" : "Install") {
                                    model.installLocalACPRuntimeComponent(definition.runtimeKind)
                                }
                                .buttonStyle(DashboardPrimaryButtonStyle())
                                .disabled(inventory == nil || model.checkingRuntimeInventory || !model.installingLocalACPRuntimeKinds.isEmpty || model.preparedLocalACPRuntimeInstall != nil || model.localRuntimeMaintenanceHasActiveConversation)
                            } else {
                                SettingsHarnessSignInControl(model: model, runtimeKind: definition.runtimeKind, compact: true)
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
                        SettingsPill(model.openCode?.isInstalled == true ? "Installed" : "Not installed",
                            tone: model.openCode?.isInstalled == true ? .neutral : .warning)
                    }
                    Text(model.runtimeInventories[.opencode]?.summary ?? "Checking the local OpenCode v2 installation…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.checkedRuntimeKinds.contains(.opencode), model.runtimeInventories[.opencode]?.latestUnavailable == true {
                        Text("Couldn’t check for updates.").font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
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
                    if model.runtimeInventories[.opencode]?.isInstalled == true {
                        SettingsHarnessSignInControl(model: model, runtimeKind: .opencode, compact: true)
                    } else {
                        Button(model.openCode?.isInstalling == true ? "Installing…" : "Install") {
                            model.installLocalACPRuntimeComponent(.opencode)
                        }
                        .disabled(model.runtimeInventories[.opencode] == nil || model.runtimeMaintenanceBusy(.opencode) || model.localRuntimeMaintenanceHasActiveConversation)
                    }
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
