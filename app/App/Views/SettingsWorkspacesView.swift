import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Every workspace in one list. Remote workspace details open in place; agents' install,
/// sign-in, and update controls live on each agent page.
struct SettingsWorkspacesView: View {
    @Bindable var model: RemoteWorkspacesModel
    let application: ApplicationModel
    var reservesRailControlSpace = false
    var initialWorkspaceID: UUID?
    var onMoreRuntime: (AgentRuntimeKind, RemoteWorkspaceConfiguration) -> Void
    var onBack: () -> Void
    @State private var selectedWorkspaceID: UUID?
    @State private var addingWorkspace = false
    @State private var setupWorkspace: RemoteWorkspaceConfiguration?
    @State private var name = ""
    @State private var workspaceID = ""
    @State private var hostName = ""
    @State private var userName = ""
    @State private var accessMode: RemoteWorkspaceAccessMode = .fullRoot
    @State private var acknowledgedHostAccess = false
    @State private var pendingDeletion: RemoteWorkspaceConfiguration?
    @State private var browserWorkspace: RemoteWorkspaceConfiguration?
    @State private var logsWorkspace: RemoteWorkspaceConfiguration?
    @State private var sharedLogsWorkspace: ExecutionWorkspace?

    /// Workspaces this Mac did not add. Other paired devices own their Mac and iPhone or iPad
    /// workspaces; every Linux host without an SSH setup here is managed by signed request.
    private var sharedWorkspaces: [ExecutionWorkspace] {
        let configured = Set(model.workspaces.map { $0.id.uuidString.lowercased() })
        let thisDevice = application.libraryHost.peerIdentity?.deviceID
        return application.libraryHost.executionWorkspaces.filter {
            $0.isVisibleInConnections && !configured.contains($0.id)
                && ($0.kind == .linux || $0.ownerDeviceID != thisDevice)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A workspace another device added. Linux hosts without an SSH setup here are
    /// managed by signed request; other devices' Mac and iPhone or iPad workspaces are listed.
    @ViewBuilder
    private func sharedWorkspaceRow(_ workspace: ExecutionWorkspace) -> some View {
        let addedOn = application.libraryHost.connectedPeerRoutes.first(where: { $0.deviceID == workspace.ownerDeviceID })?.name
        let detail = [sharedWorkspaceKind(workspace.kind), addedOn.map { "Added on " + $0 }].compactMap { $0 }.joined(separator: " · ")
        if workspace.kind == .linux {
            let state = model.sharedHosts[workspace.id]
            let ready = state?.serviceState == "running" || state?.serviceState == "ready"
            VStack(alignment: .leading, spacing: 4) {
                SettingsRow(title: workspace.name, detail: detail) {
                    if state?.busy == true { ProgressView().controlSize(.small) }
                    if let service = state?.serviceState {
                        SettingsStatus(ready ? "Ready" : service.capitalized, tone: ready ? .good : .warning)
                    } else if state?.error != nil {
                        SettingsStatus("Needs attention", tone: .warning)
                    }
                    Menu("Manage") {
                        Button("Refresh status") { model.manageSharedHost(workspace.id, .refresh) }
                        Button("Restart") { model.manageSharedHost(workspace.id, .restart) }
                        Button("Update server") { model.manageSharedHost(workspace.id, .update) }
                        Divider()
                        Button("Logs") { model.manageSharedHost(workspace.id, .logs); sharedLogsWorkspace = workspace }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(state?.busy == true)
                }
                if let progress = state?.progress { SettingsNote(progress) }
                if let error = state?.error { SettingsError(error) }
            }
            .task(id: workspace.id) { if model.sharedHosts[workspace.id] == nil { model.manageSharedHost(workspace.id, .refresh) } }
        } else {
            SettingsRow(title: workspace.name, detail: detail) { EmptyView() }
        }
    }

    private func deploymentProgress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            SettingsNote(message)
        }
        .accessibilityElement(children: .combine)
    }

    private var pageTitle: String {
        selectedWorkspace?.name ?? (addingWorkspace ? "Add Workspace" : "Workspaces")
    }

    private var workspacePage: some View {
        SettingsPage(
            title: pageTitle,
            detail: selectedWorkspace.map(workspaceLocation),
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: selectedWorkspace != nil || addingWorkspace ? "Workspaces" : "Settings",
            onBack: {
                if selectedWorkspaceID != nil {
                    selectedWorkspaceID = nil
                } else if addingWorkspace {
                    addingWorkspace = false
                } else {
                    onBack()
                }
            }
        ) {
            if let selectedWorkspace {
                workspaceSection(selectedWorkspace)
                agentsSection(selectedWorkspace)
                detailsSection(selectedWorkspace)
                if let progress = model.progress {
                    deploymentProgress(progress)
                }
            } else if addingWorkspace {
                hostCard
                if currentPreflight?.ready == true { createCard }
                if let progress = model.progress { deploymentProgress(progress) }
            } else {
                workspaceList
                if let progress = model.progress { deploymentProgress(progress) }
            }
            if let error = model.errorMessage {
                SettingsError(error)
            }
        }
        .id(selectedWorkspaceID)
        .task(id: selectedWorkspaceID == nil && !addingWorkspace) {
            // Workspaces added on other paired devices arrive through host status.
            guard selectedWorkspaceID == nil, !addingWorkspace, !DevelopmentLaunch.isClient else { return }
            while !Task.isCancelled {
                await application.libraryHost.refreshStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
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
                    Text("\(workspace.name) logs").font(.settingsSection)
                    Spacer()
                    Button("Refresh") { model.loadLogs(workspace) }
                    Button("Done") { logsWorkspace = nil }
                }.buttonStyle(SettingsQuietButtonStyle())
                if let error = model.errorMessage { SettingsError(error) }
                ScrollView {
                    Text(model.workspaceLogs[workspace.id] ?? "Loading logs…")
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }
            .padding(24).frame(width: 760, height: 520)
            .foregroundStyle(DashboardPalette.foreground).background(DashboardPalette.background)
        }
        .sheet(item: $sharedLogsWorkspace) { workspace in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(workspace.name) logs").font(.settingsSection)
                    Spacer()
                    Button("Refresh") { model.manageSharedHost(workspace.id, .logs) }
                    Button("Done") { sharedLogsWorkspace = nil }
                }.buttonStyle(SettingsQuietButtonStyle())
                if let error = model.sharedHosts[workspace.id]?.error { SettingsError(error) }
                ScrollView {
                    Text(model.sharedHosts[workspace.id]?.logs ?? "Loading logs…")
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }
            .padding(24).frame(width: 760, height: 520)
            .foregroundStyle(DashboardPalette.foreground).background(DashboardPalette.background)
        }
        .onChange(of: hostName + userName + accessMode.rawValue) { _, _ in
            acknowledgedHostAccess = false
        }
        .onChange(of: model.workspaces.map(\.id)) { _, workspaceIDs in
            if let selectedWorkspaceID,
               !workspaceIDs.contains(selectedWorkspaceID) {
                self.selectedWorkspaceID = nil
            }
        }
        .onAppear {
            selectedWorkspaceID = selectedWorkspaceID ?? initialWorkspaceID
            presentPendingSetup()
        }
        .onChange(of: model.workspaces.count) { oldCount, newCount in
            if newCount > oldCount { addingWorkspace = false }
        }
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
            userName: userName, kind: .host, accessMode: accessMode
        )
    }

    @ViewBuilder private var workspaceList: some View {
        SettingsSection(title: "This Mac", detail: "Create a blank project or link an existing directory from the sidebar.") {
            SettingsRow(
                title: "Local workspace",
                detail: localWorkspaceDetail
            ) {
                SettingsStatus(application.localACPWorkspaceAvailability.isReady ? "Ready" : "Setup required",
                    tone: application.localACPWorkspaceAvailability.isReady ? .good : .warning)
            }
        }
        SettingsSection(title: "Remote workspaces", detail: "Agents and files on remote Linux machines.") {
            if model.workspaces.isEmpty {
                SettingsEmpty("No remote workspaces yet.")
            } else {
                VStack(spacing: 2) {
                    ForEach(model.workspaces) { workspace in workspaceRow(workspace) }
                }
            }
            Button("Add workspace") { addingWorkspace = true }
                .buttonStyle(SettingsQuietButtonStyle())
        }
        if !sharedWorkspaces.isEmpty {
            SettingsSection(title: "From other devices", detail: "Every Mac can manage these and start sessions there. Agents keep running on their own workspace.") {
                ForEach(sharedWorkspaces) { workspace in sharedWorkspaceRow(workspace) }
            }
        }
    }

    private var localWorkspaceDetail: String? {
        let availability = application.localACPWorkspaceAvailability
        let lines = [availability.rootPath, availability.isReady ? nil : availability.detail].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func sharedWorkspaceKind(_ kind: ExecutionWorkspace.Kind) -> String {
        switch kind {
        case .mac: "Mac workspace"
        case .linux: "Linux workspace"
        case .ios: "iPhone or iPad workspace"
        }
    }

    private func statusLabel(_ workspace: RemoteWorkspaceConfiguration) -> String {
        model.busyWorkspaceIDs.contains(workspace.id) ? "Working" : (model.statuses[workspace.id]?.state.capitalized ?? "Unknown")
    }

    private func workspaceRow(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsDestinationRow(
            title: workspace.name,
            detail: workspaceLocation(workspace),
            status: statusLabel(workspace),
            statusTone: model.statuses[workspace.id]?.running == true ? .good : .warning,
            icon: { DashboardLucideIcon(glyph: .container, size: 15) },
            action: { selectedWorkspaceID = workspace.id }
        )
    }

    private func workspaceSection(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        let status = model.statuses[workspace.id]
        let busy = model.busyWorkspaceIDs.contains(workspace.id)
        return SettingsSection {
            SettingsRow(title: "Status") {
                SettingsStatus(statusLabel(workspace), tone: status?.running == true ? .good : .warning)
                Button("Reconnect") { model.reconnect(workspace) }
                    .help("Allow access to this workspace's saved Keychain token and reconnect.")
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(busy)
                Menu("Manage") {
                    if let status {
                        Button("Start") { model.lifecycle(.start, configuration: workspace) }
                            .disabled(status.running)
                        Button("Stop") { model.lifecycle(.stop, configuration: workspace) }
                            .disabled(!status.running)
                        Button("Restart") { model.lifecycle(.restart, configuration: workspace) }
                            .disabled(!status.running)
                        Divider()
                    }
                    Button("Update server") { model.updateContainer(workspace) }
                    Button("View browser") { browserWorkspace = workspace }
                    if workspace.kind == .host {
                        Button("Logs") { model.loadLogs(workspace); logsWorkspace = workspace }
                    }
                    Divider()
                    Button("Uninstall…", role: .destructive) { pendingDeletion = workspace }
                }
                .menuStyle(.button)
                .fixedSize()
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(busy)
            }
            if status == nil {
                SettingsEmpty("Reconnect to load this workspace's current status.")
            }
            if let warning = status?.storageWarning, !warning.isEmpty {
                storageWarning(warning)
            }
        }
    }

    private func detailsSection(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        let status = model.statuses[workspace.id]
        let busy = model.busyWorkspaceIDs.contains(workspace.id)
        return SettingsSection(title: "Details") {
            VStack(alignment: .leading, spacing: 2) {
                SettingsToggleRow(
                    title: "Keep working in the background",
                    detail: "Tasks and sessions continue while this host is running. Results sync when you reconnect.",
                    isOn: Binding(
                        get: { workspace.backgroundExecutionEnabled },
                        set: { model.setBackgroundExecution($0, for: workspace) }
                    )
                )
                .disabled(busy || model.changingTaskGatewayIDs.contains(workspace.id))
                if let gateway = model.taskGatewayStatuses[workspace.id], gateway.enabled != workspace.backgroundExecutionEnabled {
                    SettingsNote("Waiting for this workspace to apply the background execution setting.")
                }
                if model.changingTaskGatewayIDs.contains(workspace.id) {
                    ProgressView().controlSize(.small)
                }
                if let error = model.taskGatewayErrors[workspace.id] { SettingsError(error) }
            }
            if workspace.kind == .host {
                SettingsSummaryRow("Access", value: workspace.accessMode == .fullRoot ? "Full root access" : "Normal user permissions") {
                    SettingsNote(hostWarning(user: workspace.userName, host: workspace.hostName))
                }
            }
            if let status {
                SettingsSummaryRow("Storage", value: hostStorageLabel(status)) {
                    SettingsValueRow(label: "Health", value: status.health?.capitalized ?? "Starting")
                    SettingsValueRow(label: "Workspace data", value: workspaceUsageLabel(status))
                    SettingsValueRow(label: "Host storage", value: hostStorageLabel(status))
                }
            }
            if workspace.kind == .host {
                browserSandboxRow(workspace, status: status, busy: busy)
            }
            SettingsHelp {
                SettingsNote("Background work is on by default. Pi Durable needs this Mac to unlock credentials after a remote restart.")
            }
        }
    }

    private func browserSandboxRow(_ workspace: RemoteWorkspaceConfiguration, status: RemoteWorkspaceStatus?, busy: Bool) -> some View {
        let result = model.browserSelfTests[workspace.id]
        return SettingsSummaryRow(
            "Browser sandbox",
            value: result == nil ? "Not checked" : result?.ok == true ? "Verified" : "Needs attention",
            tone: result == nil ? .neutral : result?.ok == true ? .good : .warning
        ) {
            if let result, !result.ok {
                if let reason = result.reason { SettingsNote(reason.replacingOccurrences(of: "_", with: " ")) }
                if let missing = result.missingLibraries, !missing.isEmpty {
                    SettingsNote("Missing libraries: " + missing.joined(separator: ", "))
                }
                if let hint = result.hint { SettingsNote(hint) }
            }
            if result == nil { SettingsNote("Connect and verify the host browser to check its sandbox.") }
            Button("Verify browser") { model.checkBrowserSandbox(workspace) }
                .buttonStyle(SettingsQuietButtonStyle()).disabled(busy || status?.running != true)
        }
    }

    private func workspaceLocation(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> String {
        "\(workspace.workspaceID) · \(workspace.userName.map { "\($0)@" } ?? "")\(workspace.hostName)"
    }

    private var hostCard: some View {
        SettingsSection(title: "Host", detail: "Choose a machine, then check that it can run a workspace. Remote workspaces run Woven Matter directly on Linux.") {
            SettingsRow(title: "Workspace access") {
                SettingsPicker("Workspace access", selection: $accessMode,
                    options: [RemoteWorkspaceAccessMode.fullRoot, .user], popoverWidth: 220) {
                    $0 == .fullRoot ? "Full root access" : "Normal user permissions"
                }
            }
            SettingsNote(accessMode == .fullRoot
                ? "Agents can administer this machine without approval for each elevated command. The access level applies to the entire workspace."
                : "Agents use this Linux account's normal permissions. The access level applies to the entire workspace.")
            SettingsField("Tailnet machines") {
                VStack(alignment: .leading, spacing: 8) {
                    let onlineMachines = model.machineCandidates.filter(\.online)
                    if onlineMachines.isEmpty, !model.isDiscovering {
                        Text("No online machines discovered")
                            .font(.settingsSecondary)
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    ForEach(onlineMachines) { machine in
                        Button {
                            hostName = machine.hostName
                            model.checkHost(hostName: hostName, userName: userName, kind: .host, accessMode: accessMode)
                        } label: {
                            HStack(spacing: 8) {
                                Text(machine.displayName)
                                if hostName.trimmingCharacters(in: .whitespacesAndNewlines) == machine.hostName {
                                    Text("Selected").font(.settingsSecondary.weight(.medium))
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
                    .dashboardInput()
                    .onSubmit { model.checkHost(hostName: hostName, userName: userName, kind: .host, accessMode: accessMode) }
            }
            SettingsField("Remote username (optional)") {
                TextField("Resolved by SSH config", text: $userName)
                    .dashboardInput()
            }
            SettingsNote("Requires connected Tailscale on both machines. Uses your SSH agent; Woven Matter does not store SSH keys.")
            Button(model.isCheckingHost ? "Inspecting host…" : "Inspect host") {
                model.checkHost(
                    hostName: hostName,
                    userName: userName, kind: .host, accessMode: accessMode
                )
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(model.isCheckingHost || hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if currentPreflight == nil, !model.isCheckingHost {
                Text(hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Select a host to see whether it is ready."
                    : "Inspect this host to continue. Inspection makes no changes.")
                    .font(.settingsSecondary)
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            if let preflight = currentPreflight {
                SettingsInset {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsValueRow(label: "Selected host", value: hostName.trimmingCharacters(in: .whitespacesAndNewlines))
                        SettingsValueRow(
                            label: "Host status",
                            value: preflight.ready ? "Ready to create a workspace"
                                : preflight.canPrepare == true ? "Host preparation available"
                                : "Needs attention"
                        )
                        SettingsValueRow(
                            label: "Runtime",
                            value: "Native Linux service · \(preflight.architecture)"
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsValueRow(label: "Host storage", value: hostStorageLabel(preflight))
                        }
                        if let warning = preflight.storageWarning, !warning.isEmpty {
                            storageWarning(warning)
                        }
                        if !preflight.limitations.isEmpty {
                            Text(preflight.limitations.joined(separator: " "))
                                .font(.settingsSecondary)
                                .foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        if preflight.preparationRequired == true {
                            Text("Preparation required")
                                .font(.settingsSecondary.weight(.semibold))
                            ForEach(
                                Array((preflight.preparationActions ?? []).enumerated()),
                                id: \.offset
                            ) { _, action in
                                Text("• \(action)")
                                    .font(.settingsSecondary)
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                            }
                        }
                        if preflight.canPrepare == true {
                            Button(model.isCreating ? "Preparing host…" : "Prepare host") {
                                model.prepareHost(hostName: hostName, userName: userName, kind: .host, accessMode: accessMode)
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
        SettingsSection(title: "Create workspace", detail: "On \(hostName.trimmingCharacters(in: .whitespacesAndNewlines))") {
            SettingsField("Name") {
                TextField("Remote workspace name", text: $name)
                    .dashboardInput()
            }
            SettingsField("Workspace ID") {
                TextField("remote-workspace-id", text: $workspaceID)
                    .dashboardInput()
            }
            SettingsNote("Files use available disk space on the remote machine.")
            SettingsNote(hostWarning(user: userName.isEmpty ? nil : userName, host: hostName))
            Toggle("I understand this workspace's access to the host", isOn: $acknowledgedHostAccess)

            Button(model.isCreating ? "Creating…" : "Create workspace") {
                model.create(
                    name: name,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    userName: userName,
                    port: 7337,
                    kind: .host, accessMode: accessMode
                )
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(model.isCreating || currentPreflight?.ready != true
                || !acknowledgedHostAccess
                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func hostWarning(user: String?, host: String) -> String {
        "Host mode runs agents as \(user ?? "the SSH user")@\(host) with that user's full permissions. There is no container isolation."
    }

    private func agentsSection(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsSection(title: "Agents") {
            let harnesses = model.currentHarnesses(for: workspace)
            if harnesses.isEmpty {
                SettingsEmpty("Start the workspace or refresh to check for agents.")
            } else {
                VStack(spacing: 2) {
                    ForEach(harnesses) { harness in
                        SettingsDestinationRow(
                            title: harness.displayName,
                            detail: harness.id == .defaultAgent
                                ? HarnessAccountPresentation.providerSummary(model.signInStatuses[workspace.id] ?? [])
                                : HarnessAccountPresentation.remoteLabel(harness),
                            status: harness.state.replacingOccurrences(of: "_", with: " ").capitalized,
                            statusTone: harness.state == "ready" ? .good : .warning,
                            icon: { DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: harness.id), size: 15) },
                            action: { onMoreRuntime(harness.id, workspace) }
                        )
                    }
                }
            }
            Button("Set up harnesses") { setupWorkspace = workspace }
                .buttonStyle(SettingsQuietButtonStyle())
            if let error = model.signInErrors[workspace.id] { SettingsError(error) }
            if model.runtimeErrors[workspace.id] != nil {
                SettingsNote("Runtime inventory unavailable. Open an agent and check for updates to retry.")
            }
        }
        .task(id: workspace.id) { await model.refreshSignInStatus(workspace) }
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
            SettingsStatus("Warning", tone: .warning)
            SettingsNote(message)
        }
    }
}
