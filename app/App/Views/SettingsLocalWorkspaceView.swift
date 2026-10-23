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
        SettingsCard(title: "Harnesses") {
            ForEach(LocalACPRuntimeCatalog.definitions.sorted {
                $0.runtimeKind.presentationRank < $1.runtimeKind.presentationRank
            }) { definition in
                runtimeRow(definition.runtimeKind)
            }
            if let error = model.openCode?.error { SettingsError(error) }
            if let error = model.localRunError { SettingsError(error) }
        }
    }

    private func runtimeRow(_ kind: AgentRuntimeKind) -> some View {
        let inventory = model.runtimeInventories[kind]
        let availability = model.localACPRuntimeAvailability.first { $0.runtimeKind == kind }
        let included = kind == .defaultAgent
        let checking = model.checkingLocalACPRuntimeKinds.contains(kind)
        let installed = included || inventory?.isInstalled == true
        let installing = model.installingLocalACPRuntimeKinds.contains(kind) || (kind == .opencode && model.openCode?.isInstalling == true)
        let status = included ? "Included" : checking ? "Checking"
            : kind == .opencode ? (installed ? "Installed" : "Not installed")
            : availability?.isReady == true && !model.isLocalACPAgentReady(kind) ? "Workspace unavailable"
            : localACPRuntimeStatusLabel(availability)
        return SettingsHarnessDisclosure(runtime: kind, status: status,
            tone: included || status == "Installed" ? .neutral : .warning) {
            if let inventory {
                SettingsNote(inventory.summary).textSelection(.enabled)
                if model.checkedRuntimeKinds.contains(kind), inventory.latestUnavailable {
                    SettingsNote("Couldn’t check for updates.")
                }
            }
            if availability?.isReady == true, !model.isLocalACPAgentReady(kind),
               let error = model.localACPAgentReconciliationError {
                SettingsError(error)
            }
            SettingsHarnessControlRow(title: "Preferences") {
                Button("Open settings") { onMore(kind) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .accessibilityLabel("Open \(kind.displayName) settings")
            }
            if included {
                SettingsHarnessControlRow(title: "Account") {
                    Text(HarnessAccountPresentation.providerSummary(model.localSignInStatuses)).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                    Button("Manage sign-in") { onMore(kind) }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            if !included {
                SettingsHarnessControlRow(title: "Software") {
                    if installed {
                        SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: kind)
                    } else {
                        Button(installing ? "Installing…" : inventory == nil ? "Checking…" : "Install") {
                            model.installLocalACPRuntimeComponent(kind)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(inventory == nil || model.runtimeMaintenanceBusy(kind) || model.checkingRuntimeInventory
                            || !model.installingLocalACPRuntimeKinds.isEmpty
                            || model.preparedLocalACPRuntimeInstall != nil
                            || model.localRuntimeMaintenanceHasActiveConversation)
                    }
                }
                if installed {
                    SettingsHarnessControlRow(title: "Account") {
                        Text(model.harnessSignIn.statuses[kind]?.label ?? "Not checked")
                            .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                        Button("Manage sign-in") { onMore(kind) }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                SettingsHarnessControlRow(title: "Sidebar") {
                    Toggle("Show in sidebar", isOn: Binding(
                        get: { model.isLocalACPRuntimeShown(kind) },
                        set: { model.setLocalACPRuntimeShown($0, runtimeKind: kind) }))
                        .accessibilityLabel("Show \(kind.displayName) in sidebar")
                }
                if model.runtimeFailures[kind, default: 0] >= 2
                    || (kind == .opencode && (model.openCode?.installationFailures ?? 0) >= 2) {
                    Button("Copy diagnostic") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(kind == .opencode
                            ? model.openCode?.installationDiagnostic ?? model.runtimeDiagnostic(kind)
                            : model.runtimeDiagnostic(kind), forType: .string)
                    }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
        }
        .task {
            if kind == .defaultAgent { await model.refreshLocalSignInStatus() }
            else { await model.refreshHarnessSignIn(kind) }
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

}
