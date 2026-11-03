import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsRemoteWorkspacesView: View {
    @Bindable var model: RemoteWorkspacesModel
    let application: ApplicationModel
    var reservesRailControlSpace = false
    var onMoreRuntime: (AgentRuntimeKind, RemoteWorkspaceConfiguration) -> Void
    var onBack: () -> Void
    @State private var selectedWorkspaceID: UUID?
    @State private var setupWorkspace: RemoteWorkspaceConfiguration?
    @State private var name = ""
    @State private var workspaceID = ""
    @State private var hostName = ""
    @State private var userName = ""
    @State private var port = 7337
    @State private var memoryLimit = ""
    @State private var swapLimit = ""
    private let workspaceKind: RemoteWorkspaceKind = .host
    @State private var accessMode: RemoteWorkspaceAccessMode = .fullRoot
    @State private var acknowledgedHostAccess = false
    @State private var pendingDeletion: RemoteWorkspaceConfiguration?
    @State private var browserWorkspace: RemoteWorkspaceConfiguration?
    @State private var logsWorkspace: RemoteWorkspaceConfiguration?

    private var sharedWorkspaces: [CompanionExecutionWorkspace] {
        application.companionHost.executionWorkspaces.filter {
            $0.kind == .linux && !$0.deleted && $0.ownerDeviceID != application.companionHost.peerIdentity?.deviceID
        }.sorted { $0.name < $1.name }
    }

    private func deploymentProgress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            SettingsNote(message)
        }
        .accessibilityElement(children: .combine)
    }

    private var workspacePage: some View {
        SettingsPage(
            title: selectedWorkspace?.name ?? "Remote Workspaces",
            detail: selectedWorkspace.map(workspaceLocation),
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: selectedWorkspace == nil ? "Settings" : "Remote Workspaces",
            onBack: {
                if selectedWorkspaceID == nil {
                    onBack()
                } else {
                    selectedWorkspaceID = nil
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if selectedWorkspace == nil {
                    SettingsWorkspaceSidebarVisibilityControl(.remoteWorkspaces)
                }
                if let selectedWorkspace {
                    workspaceCard(selectedWorkspace)
                    harnessesCard(selectedWorkspace)
                    if let progress = model.progress {
                        deploymentProgress(progress)
                    }
                } else {
                    workspacesCard
                    if !sharedWorkspaces.isEmpty {
                        SettingsCard(title: "Shared workspaces", detail: "Workspaces added on your paired Macs are available here after synchronization. Agents keep running on their own workspace.") {
                            ForEach(sharedWorkspaces) { workspace in
                                HStack {
                                    Text(workspace.name).font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text("Added on " + (application.companionHost.connectedPeerRoutes.first(where: { $0.deviceID == workspace.ownerDeviceID })?.name ?? "a paired Mac"))
                                        .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                }
                            }
                        }
                    }
                    hostCard
                    if currentPreflight?.ready == true { createCard }
                    if let progress = model.progress { deploymentProgress(progress) }
                }
                if let error = model.errorMessage {
                    SettingsError(error)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
        .id(selectedWorkspaceID)
        .task(id: selectedWorkspaceID) {
            if let selectedWorkspace {
                model.refresh(selectedWorkspace)
            } else {
                model.discoverMachines()
                for workspace in model.workspaces { model.refresh(workspace) }
            }
        }
    }

    private var workspacePresentations: some View {
        workspacePage
        .sheet(item: $browserWorkspace) { workspace in
            RemoteBrowserView(workspaces: model, configuration: workspace)
        }
        .sheet(item: $logsWorkspace) { workspace in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(workspace.name) logs").font(.headline)
                    Spacer()
                    Button("Refresh") { model.loadLogs(workspace) }
                    Button("Done") { logsWorkspace = nil }
                }.buttonStyle(SettingsQuietButtonStyle())
                if let error = model.errorMessage { SettingsError(error) }
                ScrollView {
                    Text(model.workspaceLogs[workspace.id] ?? "Loading logs…")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }
            .padding(24).frame(width: 760, height: 520)
            .foregroundStyle(DashboardPalette.foreground).background(DashboardPalette.background)
        }
        .onChange(of: hostName + userName + workspaceKind.rawValue + accessMode.rawValue) { _, _ in
            acknowledgedHostAccess = false
        }
        .onChange(of: model.workspaces.map(\.id)) { _, workspaceIDs in
            if let selectedWorkspaceID,
               !workspaceIDs.contains(selectedWorkspaceID) {
                self.selectedWorkspaceID = nil
            }
        }
        .onAppear { presentPendingSetup() }
        .onChange(of: model.pendingHarnessSetupIDs) { _, _ in presentPendingSetup() }
        .sheet(item: $setupWorkspace) { workspace in
            RemoteHarnessSetupView(application: application, workspace: workspace) {
                model.dismissHarnessSetup(workspace.id)
                setupWorkspace = nil
            }
        }
    }

    private var workspaceConfirmations: some View {
        workspacePresentations
        .confirmationDialog(
            "Authorize remote host preparation?",
            isPresented: Binding(
                get: { model.pendingHostPreparation != nil },
                set: { if !$0 { model.cancelHostPreparation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Authorize and prepare") {
                model.authorizeHostPreparation()
            }
            Button("Cancel", role: .cancel) {
                model.cancelHostPreparation()
            }
        } message: {
            if let pending = model.pendingHostPreparation {
                Text(
                    (pending.inspection.preparationActions ?? [])
                        .map { "• \($0)" }
                        .joined(separator: "\n")
                    + "\n\nThis prepares \(pending.hostName) and may download packages. Woven Matter will verify the host, then you can create a workspace."
                )
            }
        }
        .confirmationDialog(
            "Delete remote workspace?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button("Uninstall; keep data") {
                    model.delete(pendingDeletion, removePersistentData: false)
                    self.pendingDeletion = nil
                }
                Button("Uninstall and remove data", role: .destructive) {
                    model.delete(pendingDeletion, removePersistentData: true)
                    self.pendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Uninstall stops the native service and keeps workspace files and databases. Removing data cannot be undone.")
        }
    }

    var body: some View {
        workspaceConfirmations
        .confirmationDialog(
            "Confirm harness \(model.preparedHarnessAction?.action ?? "change")?",
            isPresented: Binding(
                get: { setupWorkspace == nil && model.preparedHarnessAction?.action != nil && model.preparedHarnessAction?.action != "update" },
                set: {
                    if !$0, setupWorkspace == nil, let prepared = model.preparedHarnessAction,
                       prepared.action != "update" {
                        model.cancelPreparedHarnessAction(
                            workspaceID: prepared.configuration.id,
                            harnessID: prepared.harness.id,
                            action: prepared.action
                        )
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Confirm \(model.preparedHarnessAction?.action.capitalized ?? "Change")") {
                if let prepared = model.preparedHarnessAction,
                   prepared.action != "update" {
                    model.confirmPreparedHarnessAction(
                        workspaceID: prepared.configuration.id,
                        harnessID: prepared.harness.id,
                        action: prepared.action
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                if let prepared = model.preparedHarnessAction,
                   prepared.action != "update" {
                    model.cancelPreparedHarnessAction(
                        workspaceID: prepared.configuration.id,
                        harnessID: prepared.harness.id,
                        action: prepared.action
                    )
                }
            }
        } message: {
            if let prepared = model.preparedHarnessAction {
                if let sha256 = prepared.preview.sha256 {
                    Text("Source: \(prepared.preview.source)\nSHA-256: \(sha256)\nThe service will download the source again and refuse to run it if this digest changes.")
                } else {
                    Text("Source: \(prepared.preview.source)\nPackage-manager integrity verification applies.\nCommand: \(prepared.preview.command)")
                }
            }
        }
    }

    private func presentPendingSetup() {
        guard setupWorkspace == nil,
              let workspace = model.workspaces.first(where: { model.pendingHarnessSetupIDs.contains($0.id) }) else { return }
        setupWorkspace = workspace
    }

    private var selectedWorkspace: RemoteWorkspaceConfiguration? {
        model.workspaces.first { $0.id == selectedWorkspaceID }
    }

    private var currentPreflight: RemoteWorkspacePreflight? {
        model.preflight(
            hostName: hostName,
            userName: userName, kind: workspaceKind, accessMode: accessMode
        )
    }

    private var workspacesCard: some View {
        SettingsCard(title: "Workspaces") {
            if model.workspaces.isEmpty {
                SettingsEmpty("No remote workspaces yet.")
            } else {
                ForEach(model.workspaces) { workspace in
                    SettingsInset { workspaceRow(workspace) }
                }
            }
        }
    }

    private func workspaceRow(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        let status = model.statuses[workspace.id]
        let busy = model.busyWorkspaceIDs.contains(workspace.id)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                Text(workspaceLocation(workspace))
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer(minLength: 12)
            SettingsPill(
                busy ? "Working" : (status?.state.capitalized ?? "Unknown"),
                tone: status?.running == true ? .neutral : .warning
            )
            Button("Manage") {
                selectedWorkspaceID = workspace.id
            }
            .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    private func workspaceCard(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        let status = model.statuses[workspace.id]
        let busy = model.busyWorkspaceIDs.contains(workspace.id)
        return SettingsCard(title: "Workspace") {
            HStack(spacing: 8) {
                SettingsPill(
                    busy ? "Working" : (status?.state.capitalized ?? "Unknown"),
                    tone: status?.running == true ? .neutral : .warning
                )
                .fixedSize(horizontal: true, vertical: false)
                Button("Reconnect") { model.reconnect(workspace) }
                    .help("Allow access to this workspace's saved Keychain token and reconnect.")
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(busy)
            HStack(spacing: 8) {
                if let status {
                    Button("Start") { model.lifecycle(.start, configuration: workspace) }
                        .disabled(status.running)
                    Button("Stop") { model.lifecycle(.stop, configuration: workspace) }
                        .disabled(!status.running)
                    Button("Restart") { model.lifecycle(.restart, configuration: workspace) }
                        .disabled(!status.running)
                }
                Button("Update server") {
                    model.updateContainer(workspace)
                }
                if workspace.kind == .host {
                    Button("Logs") { model.loadLogs(workspace); logsWorkspace = workspace }
                }
                Button("Uninstall…") { pendingDeletion = workspace }
            }
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(busy)

            if workspace.kind == .host {
                SettingsNote(hostWarning(user: workspace.userName, host: workspace.hostName))
                remoteValueRow(label: "Access", value: workspace.accessMode == .fullRoot ? "Full root access" : "Normal user permissions")
            }

            Button("View browser") { browserWorkspace = workspace }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(busy)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keep tasks and sessions running in the background", isOn: Binding(
                    get: { workspace.backgroundExecutionEnabled },
                    set: { model.setBackgroundExecution($0, for: workspace) }
                ))
                .disabled(busy || model.changingTaskGatewayIDs.contains(workspace.id))
                Text("Enabled by default. Tasks and sessions continue while this host is running. Results sync when you reconnect. Pi Durable needs this Mac to unlock credentials after a remote restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let gateway = model.taskGatewayStatuses[workspace.id], gateway.enabled != workspace.backgroundExecutionEnabled {
                    Text("Waiting for this workspace to apply the background execution setting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.changingTaskGatewayIDs.contains(workspace.id) {
                    ProgressView().controlSize(.small)
                }
                if let error = model.taskGatewayErrors[workspace.id] {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let status {
                VStack(alignment: .leading, spacing: 10) {
                    remoteValueRow(label: "Health", value: status.health?.capitalized ?? "Starting")
                    remoteValueRow(label: "Workspace data", value: workspaceUsageLabel(status))
                    remoteValueRow(label: "Host storage", value: hostStorageLabel(status))
                }
                if let warning = status.storageWarning, !warning.isEmpty {
                    storageWarning(warning)
                }
            } else {
                SettingsEmpty("Reconnect to load this workspace's current status.")
            }
            if workspace.kind == .host {
                HStack {
                    Text("Browser sandbox").font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Button("Verify browser") { model.checkBrowserSandbox(workspace) }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(busy || status?.running != true)
                }
                if let result = model.browserSelfTests[workspace.id] {
                    SettingsPill(result.ok ? "Verified" : "Needs attention", tone: result.ok ? .neutral : .warning)
                    if !result.ok {
                        if let reason = result.reason { SettingsNote(reason.replacingOccurrences(of: "_", with: " ")) }
                        if let missing = result.missingLibraries, !missing.isEmpty {
                            SettingsNote("Missing libraries: " + missing.joined(separator: ", "))
                        }
                        if let hint = result.hint { SettingsNote(hint) }
                    }
                } else { SettingsNote("Connect and verify the host browser to check its sandbox.") }
            }
        }
    }

    private func workspaceLocation(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> String {
        "\(workspace.workspaceID) · \(workspace.userName.map { "\($0)@" } ?? "")\(workspace.hostName)"
    }

    private var hostCard: some View {
        SettingsCard(title: "Host", detail: "Choose a machine, then check that it can run a workspace. Remote workspaces run Woven Matter directly on Linux.") {
            if workspaceKind == .host {
                SettingsField("Workspace access") {
                    Picker("Workspace access", selection: $accessMode) {
                        Text("Full root access").tag(RemoteWorkspaceAccessMode.fullRoot)
                        Text("Normal user permissions").tag(RemoteWorkspaceAccessMode.user)
                    }.labelsHidden()
                }
                SettingsNote(accessMode == .fullRoot
                    ? "Agents can administer this machine without approval for each elevated command. The access level applies to the entire workspace."
                    : "Agents use this Linux account's normal permissions. The access level applies to the entire workspace.")
            }
            SettingsField("Tailnet machines") {
                VStack(alignment: .leading, spacing: 8) {
                    let onlineMachines = model.machineCandidates.filter(\.online)
                    if onlineMachines.isEmpty, !model.isDiscovering {
                        Text("No online machines discovered")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    ForEach(onlineMachines) { machine in
                        Button {
                            hostName = machine.hostName
                            model.checkHost(hostName: hostName, userName: userName, kind: workspaceKind, accessMode: accessMode)
                        } label: {
                            HStack(spacing: 8) {
                                Text(machine.displayName)
                                if hostName.trimmingCharacters(in: .whitespacesAndNewlines) == machine.hostName {
                                    Text("Selected").font(.system(size: 11.5, weight: .medium))
                                }
                            }
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                    Button(model.isDiscovering ? "Discovering…" : "Refresh") {
                        model.discoverMachines()
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isDiscovering)
                }
            }

            SettingsField("Tailscale machine") {
                TextField("machine.tailnet-name.ts.net", text: $hostName)
                    .settingsInput()
                    .onSubmit { model.checkHost(hostName: hostName, userName: userName, kind: workspaceKind, accessMode: accessMode) }
            }
            SettingsField("Remote username (optional)") {
                TextField("Resolved by SSH config", text: $userName)
                    .settingsInput()
            }
            SettingsNote("Requires connected Tailscale on both machines. Uses your SSH agent; Woven Matter does not store SSH keys.")
            Button(model.isCheckingHost ? "Inspecting host…" : "Inspect host") {
                model.checkHost(
                    hostName: hostName,
                    userName: userName, kind: workspaceKind, accessMode: accessMode
                )
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(model.isCheckingHost || hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if currentPreflight == nil, !model.isCheckingHost {
                Text(hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Select a host to see whether it is ready."
                    : "Inspect this host to continue. Inspection makes no changes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            if let preflight = currentPreflight {
                SettingsInset {
                    VStack(alignment: .leading, spacing: 8) {
                        remoteValueRow(label: "Selected host", value: hostName.trimmingCharacters(in: .whitespacesAndNewlines))
                        remoteValueRow(
                            label: "Host status",
                            value: preflight.ready ? "Ready to create a workspace"
                                : preflight.canPrepare == true ? "Host preparation available"
                                : "Needs attention"
                        )
                        remoteValueRow(
                            label: "Runtime",
                            value: "Native Linux service · \(preflight.architecture)"
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            remoteValueRow(label: "Host storage", value: hostStorageLabel(preflight))
                        }
                        if let warning = preflight.storageWarning, !warning.isEmpty {
                            storageWarning(warning)
                        }
                        if !preflight.limitations.isEmpty {
                            Text(preflight.limitations.joined(separator: " "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        if preflight.preparationRequired == true {
                            Text("Preparation required")
                                .font(.system(size: 11.5, weight: .semibold))
                            ForEach(
                                Array((preflight.preparationActions ?? []).enumerated()),
                                id: \.offset
                            ) { _, action in
                                Text("• \(action)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                            }
                        }
                        if preflight.canPrepare == true {
                            Button(model.isCreating ? "Preparing host…" : "Prepare host") {
                                model.prepareHost(hostName: hostName, userName: userName, kind: workspaceKind, accessMode: accessMode)
                            }
                            .buttonStyle(DashboardPrimaryButtonStyle())
                        }
                    }
                }
            }
        }
        .disabled(model.isCreating)
    }

    private var createCard: some View {
        SettingsCard(title: "Create workspace", detail: "On \(hostName.trimmingCharacters(in: .whitespacesAndNewlines))") {
            SettingsField("Name") {
                TextField("Remote workspace name", text: $name)
                    .settingsInput()
            }
            SettingsField("Workspace ID") {
                TextField("remote-workspace-id", text: $workspaceID)
                    .settingsInput()
            }
            SettingsNote("Files use available disk space on the remote machine.")
            if workspaceKind == .host {
                SettingsNote(hostWarning(user: userName.isEmpty ? nil : userName, host: hostName))
                Toggle("I understand this workspace's access to the host", isOn: $acknowledgedHostAccess)
                    .toggleStyle(DashboardSwitchToggleStyle())
            }

            Button(model.isCreating ? "Creating…" : "Create workspace") {
                model.create(
                    name: name,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    userName: userName,
                    port: port,
                    memoryLimit: memoryLimit,
                    swapLimit: swapLimit, kind: workspaceKind, accessMode: accessMode
                )
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(model.isCreating || currentPreflight?.ready != true
                || (workspaceKind == .host && !acknowledgedHostAccess)
                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func hostWarning(user: String?, host: String) -> String {
        "Host mode runs agents as \(user ?? "the SSH user")@\(host) with that user's full permissions. There is no container isolation."
    }

    private func harnessesCard(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsCard(title: "Harnesses") {
            Button("Set up harnesses") { setupWorkspace = workspace }
                .buttonStyle(SettingsQuietButtonStyle())
            let harnesses = model.currentHarnesses(for: workspace)
            if harnesses.isEmpty {
                SettingsEmpty("Start the workspace or refresh to check for agents.")
            } else {
                ForEach(harnesses) { harness in
                    SettingsHarnessDisclosure(runtime: harness.id,
                        status: harness.state.replacingOccurrences(of: "_", with: " ").capitalized,
                        tone: harness.state == "ready" ? .neutral : .warning) {
                        if let runtime = model.runtimeMaintenance[workspace.id]?.first(where: { $0.id == harness.id }) {
                            runtimeInventory(runtime, workspace: workspace)
                        }
                        SettingsHarnessControlRow(title: "Preferences") {
                            Button("Open settings") { onMoreRuntime(harness.id, workspace) }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .accessibilityLabel("Open \(harness.displayName) settings")
                        }
                        if harness.id == .defaultAgent {
                            SettingsHarnessControlRow(title: "Account") {
                                Text(HarnessAccountPresentation.providerSummary(model.signInStatuses[workspace.id] ?? []))
                                    .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                                Button("Manage sign-in") { onMoreRuntime(harness.id, workspace) }
                                    .buttonStyle(SettingsQuietButtonStyle())
                            }
                            if let error = model.signInErrors[workspace.id] { SettingsNote(error) }
                        } else { runtimeButtons(harness, workspace: workspace) }
                    }
                }
            }
            if model.runtimeErrors[workspace.id] != nil {
                SettingsNote("Runtime inventory unavailable. Check for updates to retry.")
            }

        }
        .task(id: workspace.id) { await model.refreshSignInStatus(workspace) }
    }

    @ViewBuilder
    private func runtimeButtons(_ harness: RemoteHarnessStatus, workspace: RemoteWorkspaceConfiguration) -> some View {
        let runtime = model.runtimeMaintenance[workspace.id]?.first(where: { $0.id == harness.id })
        let checking = model.checkingRuntimeIDs[workspace.id]?.contains(harness.id) == true
        let running = runtime?.operation?.status == "running"
        let unavailable = model.isRuntimeInventoryUnavailable(harness.id, configuration: workspace)
        let busy = model.busyWorkspaceIDs.contains(workspace.id) || running || checking
        SettingsHarnessControlRow(title: "Software") {
            if let runtime, !runtime.installed {
                Button(running && runtime.operation?.action == "install" ? "Installing…" : (runtime.failureCount > 0 ? "Retry install" : "Install")) {
                    model.prepareHarnessAction("install", harness: harness, configuration: workspace)
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(busy || unavailable)
            } else if runtime?.source != "system" {
                SettingsRemoteRuntimeUpdateButton(model: model, harness: harness, configuration: workspace)
            } else {
                Text("Managed on host").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        if let runtime {
            if runtime.installed {
                SettingsHarnessControlRow(title: "Account") {
                    Text(HarnessAccountPresentation.remoteLabel(harness))
                        .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                    Button("Manage sign-in") { onMoreRuntime(harness.id, workspace) }
                        .buttonStyle(SettingsQuietButtonStyle())
                }
            }
        }
    }

    private func runtimeInventory(_ runtime: RemoteRuntimeMaintenance, workspace: RemoteWorkspaceConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(runtime.components) { component in
                if workspace.kind == .host, component.source == "system", let path = component.path {
                    Text("Using \(path) (installed on host)")
                        .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Text(componentVersion(component))
                    .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    .help(component.path ?? "No installed path")
            }
            if model.runtimeCheckErrors[workspace.id]?[runtime.id] != nil || runtime.versionCheckAvailable == false {
                Text("Couldn’t check for updates.")
                    .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            if runtime.operation?.status == "failed", let error = runtime.operation?.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground).lineLimit(2)
            }
            if runtime.failureCount >= 2, let prompt = runtime.diagnosticPrompt {
                Button("Copy diagnostic prompt") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                }.buttonStyle(SettingsQuietButtonStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func componentVersion(_ component: RemoteRuntimeComponent) -> String {
        let installed = component.installed ? (component.installedVersion ?? "version unavailable") : "missing"
        let newer = component.availableUpdateVersion
        return "\(component.displayName) \(installed)" + (newer.map { " → \($0)" } ?? "")
    }

    private func resourceLabel(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) : "Unlimited"
    }

    private func remoteValueRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func resourceInputValue(_ value: String?) -> String {
        guard let value else { return "" }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasSuffix("g"),
              normalized.dropLast().allSatisfy(\.isNumber) else {
            return normalized
        }
        return String(normalized.dropLast())
    }

    private func swapLabel(_ status: RemoteWorkspaceStatus) -> String {
        switch status.swapMode {
        case "default": return "Host default"
        case "disabled": return "Disabled"
        case "unlimited": return "Unlimited"
        case "additional": return resourceLabel(status.swapBytes)
        default: break
        }
        if status.swapBytes < 0 { return "Unlimited" }
        if status.memoryBytes > 0, status.swapBytes == 0 { return "Disabled" }
        return resourceLabel(status.swapBytes)
    }

    private func inspectionCapabilityLabel(
        _ supported: Bool,
        preflight: RemoteWorkspacePreflight
    ) -> String {
        if supported { return "Supported" }
        return preflight.preparationRequired == true
            ? "Verify after preparation"
            : "Unavailable"
    }

    private func workspaceUsageLabel(_ status: RemoteWorkspaceStatus) -> String {
        let usage = status.storageUsedBytes.map {
            ByteCountFormatter.string(fromByteCount: max($0, 0), countStyle: .file)
        } ?? "Usage unavailable"
        return status.legacyStorage ? "\(usage) · legacy storage" : "\(usage) · no fixed limit"
    }

    private func hostStorageLabel(_ status: RemoteWorkspaceStatus) -> String {
        storageCapacityLabel(
            capacity: status.hostStorageCapacityBytes,
            available: status.hostStorageAvailableBytes
        )
    }

    private func hostStorageLabel(_ preflight: RemoteWorkspacePreflight) -> String {
        storageCapacityLabel(
            capacity: preflight.hostStorageCapacityBytes,
            available: preflight.hostStorageAvailableBytes
        )
    }

    private func storageCapacityLabel(capacity: Int64?, available: Int64?) -> String {
        guard let capacity, let available else { return "Unavailable" }
        let free = ByteCountFormatter.string(fromByteCount: max(available, 0), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: max(capacity, 0), countStyle: .file)
        return "\(free) available of \(total)"
    }

    private func storageWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SettingsPill("Warning", tone: .warning)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
