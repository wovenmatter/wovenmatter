import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsRemoteWorkspacesView: View {
    @Bindable var model: RemoteWorkspacesModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var selectedWorkspaceID: UUID?
    @State private var name = ""
    @State private var workspaceID = ""
    @State private var hostName = ""
    @State private var userName = ""
    @State private var port = 7337
    @State private var memoryLimit = ""
    @State private var swapLimit = ""
    @State private var pendingDeletion: RemoteWorkspaceConfiguration?
    @State private var authorizationCode = ""
    @State private var managedMemoryLimit = ""
    @State private var managedSwapLimit = ""

    var body: some View {
        SettingsPage(
            title: selectedWorkspace?.name ?? "Remote Agent Workspaces",
            detail: selectedWorkspace.map(workspaceLocation)
                ?? "Create independent Woven Matter workspaces on Linux machines through your existing SSH configuration.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: selectedWorkspace == nil ? "Settings" : "Remote Agent Workspaces",
            onBack: {
                if selectedWorkspaceID == nil {
                    onBack()
                } else {
                    selectedWorkspaceID = nil
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let selectedWorkspace {
                    workspaceCard(selectedWorkspace)
                    resourceCard(selectedWorkspace)
                    harnessesCard(selectedWorkspace)
                    if let progress = model.progress {
                        SettingsNote(progress)
                    }
                } else {
                    workspacesCard
                    createCard
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
        .onChange(of: model.workspaces.map(\.id)) { _, workspaceIDs in
            if let selectedWorkspaceID,
               !workspaceIDs.contains(selectedWorkspaceID) {
                self.selectedWorkspaceID = nil
            }
        }
        .confirmationDialog(
            "Authorize remote host preparation?",
            isPresented: Binding(
                get: { model.pendingHostPreparation != nil },
                set: { if !$0 { model.cancelHostPreparation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Authorize and Prepare") {
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
                    + "\n\nThis changes the remote host and may download packages. Woven Matter will verify the result before creating anything. It will not format, repartition, or remount storage."
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
                Button("Remove container; keep data") {
                    model.delete(pendingDeletion, removePersistentData: false)
                    self.pendingDeletion = nil
                }
                Button("Remove container and persistent data", role: .destructive) {
                    model.delete(pendingDeletion, removePersistentData: true)
                    self.pendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Keeping data leaves the workspace's dedicated volume on the remote machine. Removing persistent data cannot be undone.")
        }
        .confirmationDialog(
            "Confirm harness \(model.preparedHarnessAction?.action ?? "change")?",
            isPresented: Binding(
                get: { model.preparedHarnessAction != nil },
                set: { if !$0 { model.cancelPreparedHarnessAction() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Confirm \(model.preparedHarnessAction?.action.capitalized ?? "Change")") {
                model.confirmPreparedHarnessAction()
            }
            Button("Cancel", role: .cancel) {
                model.cancelPreparedHarnessAction()
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

    private var selectedWorkspace: RemoteWorkspaceConfiguration? {
        model.workspaces.first { $0.id == selectedWorkspaceID }
    }

    private var currentPreflight: RemoteWorkspacePreflight? {
        model.preflight(
            hostName: hostName,
            userName: userName
        )
    }

    private var workspacesCard: some View {
        SettingsCard(
            title: "Workspaces",
            detail: "Each container has its own persistent home, installed harnesses, credentials, and conversations."
        ) {
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
                managedMemoryLimit = resourceInputValue(workspace.memoryLimit)
                managedSwapLimit = resourceInputValue(workspace.swapLimit)
            }
            .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    private func workspaceCard(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        let status = model.statuses[workspace.id]
        let busy = model.busyWorkspaceIDs.contains(workspace.id)
        return SettingsCard(
            title: "Workspace",
            detail: "Container lifecycle and live resource status."
        ) {
            HStack(spacing: 8) {
                SettingsPill(
                    busy ? "Working" : (status?.state.capitalized ?? "Unknown"),
                    tone: status?.running == true ? .neutral : .warning
                )
                .fixedSize(horizontal: true, vertical: false)
                Button("Refresh") { model.refresh(workspace) }
                if let status {
                    Button("Start") { model.lifecycle(.start, configuration: workspace) }
                        .disabled(status.running)
                    Button("Stop") { model.lifecycle(.stop, configuration: workspace) }
                        .disabled(!status.running)
                    Button("Restart") { model.lifecycle(.restart, configuration: workspace) }
                        .disabled(!status.running)
                }
                Button("Update Container") {
                    model.updateContainer(workspace)
                }
                Button("Delete…") { pendingDeletion = workspace }
            }
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(busy)

            if let status {
                VStack(alignment: .leading, spacing: 10) {
                    remoteValueRow(label: "Health", value: status.health?.capitalized ?? "Starting")
                    remoteValueRow(label: "Memory", value: resourceLabel(status.memoryBytes))
                    remoteValueRow(label: "Additional swap", value: swapLabel(status))
                    remoteValueRow(label: "Workspace data", value: workspaceUsageLabel(status))
                    remoteValueRow(label: "Host storage", value: hostStorageLabel(status))
                }
                if let warning = status.storageWarning, !warning.isEmpty {
                    storageWarning(warning)
                }
            } else {
                SettingsEmpty("Refresh to load this workspace's current status.")
            }
        }
    }

    private func workspaceLocation(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> String {
        "\(workspace.userName.map { "\($0)@" } ?? "")\(workspace.hostName) · \(workspace.workspaceID)"
    }

    private var createCard: some View {
        SettingsCard(
            title: "Create New Workspace",
            detail: "Woven Matter checks the machine, builds the pinned workspace image there, and binds its service to remote loopback."
        ) {
            SettingsField("Tailnet machines") {
                VStack(alignment: .leading, spacing: 8) {
                    let onlineMachines = model.machineCandidates.filter(\.online)
                    if onlineMachines.isEmpty, !model.isDiscovering {
                        Text("No online machines discovered")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    ForEach(onlineMachines.prefix(5)) { machine in
                        Button(machine.displayName) { hostName = machine.hostName }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }
                    Button(model.isDiscovering ? "Discovering…" : "Refresh") {
                        model.discoverMachines()
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isDiscovering)
                }
            }

            SettingsField("Name") {
                TextField("Remote workspace name", text: $name)
                    .settingsInput()
            }
            SettingsField("Workspace ID") {
                TextField("remote-workspace-id", text: $workspaceID)
                    .settingsInput()
            }
            SettingsField("SSH hostname") {
                TextField("machine.tailnet-name.ts.net", text: $hostName)
                    .settingsInput()
            }
            SettingsField("Remote username (optional)") {
                TextField("Resolved by SSH config", text: $userName)
                    .settingsInput()
            }
            Button(model.isCheckingHost ? "Inspecting Host…" : "Inspect Host") {
                model.checkHost(
                    hostName: hostName,
                    userName: userName
                )
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(model.isCheckingHost || hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if currentPreflight == nil {
                Text("Inspection is read-only. Woven Matter will explain and ask before changing the host.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            if let preflight = currentPreflight {
                SettingsInset {
                    VStack(alignment: .leading, spacing: 8) {
                        remoteValueRow(
                            label: "Runtime",
                            value: preflight.version.isEmpty
                                ? "Docker Engine not ready · \(preflight.architecture)"
                                : "Docker Engine \(preflight.version) · \(preflight.architecture)"
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            remoteValueRow(
                                label: "Memory",
                                value: inspectionCapabilityLabel(
                                    preflight.capabilities.memory,
                                    preflight: preflight
                                )
                            )
                            remoteValueRow(
                                label: "Swap",
                                value: inspectionCapabilityLabel(
                                    preflight.capabilities.swap,
                                    preflight: preflight
                                )
                            )
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
                            Text("Create Workspace will ask for explicit authorization before applying these changes.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                }
            }
            SettingsField("Remote loopback port") {
                TextField("7337", value: $port, format: .number)
                    .settingsInput()
            }
            SettingsField("Memory limit (GB)") {
                TextField("8", text: $memoryLimit)
                    .settingsInput()
            }
            SettingsField("Swap limit (additional GB)") {
                TextField("4", text: $swapLimit)
                    .settingsInput()
            }

            SettingsNote("Memory and additional swap are measured in GB. Enter 0 to disable swap, or leave it blank to use the host default. Every workspace has a dedicated persistent volume mounted at /home. Workspace storage has no fixed limit and uses the available capacity of the remote host. The service is available only through SSH on the remote machine's loopback address. Woven Matter uses your SSH agent and does not store SSH keys.")

            Button(model.isCreating ? "Creating…" : "Create New Workspace") {
                model.create(
                    name: name,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    userName: userName,
                    port: port,
                    memoryLimit: memoryLimit,
                    swapLimit: swapLimit
                )
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(model.isCreating)
            if let progress = model.progress {
                Text(progress)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
    }

    private func resourceCard(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsCard(
            title: "\(workspace.name) resources",
            detail: "Changing memory or swap recreates only the container. The dedicated workspace volume is retained."
        ) {
            SettingsField("Memory limit (GB)") {
                TextField("8", text: $managedMemoryLimit)
                    .settingsInput()
            }
            SettingsField("Swap limit (additional GB)") {
                TextField("4", text: $managedSwapLimit)
                    .settingsInput()
            }
            if let status = model.statuses[workspace.id] {
                VStack(alignment: .leading, spacing: 10) {
                    remoteValueRow(label: "Workspace data", value: workspaceUsageLabel(status))
                    remoteValueRow(label: "Host storage", value: hostStorageLabel(status))
                }
                SettingsNote("Workspace storage has no fixed limit. Files, harnesses, credentials, configuration, and caches persist in the dedicated /home volume and use available space on the remote host.")
                if let warning = status.storageWarning, !warning.isEmpty {
                    storageWarning(warning)
                }
            }
            Button("Apply Resources") {
                model.applyResources(
                    workspace,
                    memoryLimit: managedMemoryLimit,
                    swapLimit: managedSwapLimit
                )
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(model.busyWorkspaceIDs.contains(workspace.id))
        }
    }

    private func harnessesCard(
        _ workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsCard(
            title: "\(workspace.name) harnesses",
            detail: "Install, choose a supported account or API-key method, and verify each harness directly. Installation and credentials persist in this workspace home."
        ) {
            let harnesses = model.harnesses[workspace.id] ?? []
            if harnesses.isEmpty {
                SettingsEmpty("Start the workspace and refresh to inspect its harnesses.")
            } else {
                ForEach(harnesses) { harness in
                    SettingsInset {
                        HStack(spacing: 12) {
                            DashboardHarnessLogoIcon(
                                logo: DashboardHarnessLogo(runtimeKind: harness.id),
                                size: 20
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(harness.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(harness.transport) · \(harness.capabilities.joined(separator: ", "))")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                                    .lineLimit(2)
                                Text(
                                    "Authentication: \(harness.authenticationStatus.replacingOccurrences(of: "_", with: " ").capitalized)"
                                )
                                .font(.system(size: 11.5))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                                if !harness.detectedProviders.isEmpty {
                                    Text("Detected: \(harness.detectedProviders.joined(separator: ", "))")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            SettingsPill(
                                harness.state.replacingOccurrences(of: "_", with: " ").capitalized,
                                tone: harness.state == "ready" ? .neutral : .warning
                            )
                            harnessButtons(harness, workspace: workspace)
                        }
                    }
                }
            }

            if let operation = model.operations[workspace.id] {
                SettingsNote("\(operation.action.capitalized): \(operation.status)\(operation.error.map { " — \($0)" } ?? "")")
                if !operation.output.isEmpty {
                    Text(operation.output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
            }

            if let session = model.authenticationSessions[workspace.id] {
                signInCard(session, workspace: workspace)
            }

        }
    }

    @ViewBuilder
    private func harnessButtons(
        _ harness: RemoteHarnessStatus,
        workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        if harness.state == "cli_missing" || harness.state == "adapter_missing" {
            Button("Install") {
                model.prepareHarnessAction("install", harness: harness, configuration: workspace)
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
        } else if harness.state == "authentication_required" {
            if harness.setupMethods.count == 1,
               let method = harness.setupMethods.first {
                Button("Set Up") {
                    startSignIn(harness, method: method, workspace: workspace)
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
            } else if !harness.setupMethods.isEmpty {
                Menu("Set Up…") {
                    ForEach(harness.setupMethods) { method in
                        Button(method.displayName) {
                            startSignIn(harness, method: method, workspace: workspace)
                        }
                    }
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
            } else {
                Text("No supported sign-in methods")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
        } else {
            Button("Recheck") {
                model.performHarnessAction("recheck", harness: harness, configuration: workspace)
            }
            .buttonStyle(SettingsQuietButtonStyle())
            if !harness.setupMethods.isEmpty {
                Menu("Change Sign-In…") {
                    ForEach(harness.setupMethods) { method in
                        Button(method.displayName) {
                            startSignIn(harness, method: method, workspace: workspace)
                        }
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
            }
            Button("Update") {
                model.prepareHarnessAction("update", harness: harness, configuration: workspace)
            }
            .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    private func startSignIn(
        _ harness: RemoteHarnessStatus,
        method: RemoteHarnessSetupMethod,
        workspace: RemoteWorkspaceConfiguration
    ) {
        authorizationCode = ""
        model.startHarnessSignIn(
            harness: harness,
            method: method,
            configuration: workspace
        )
    }

    private func signInCard(
        _ session: RemoteHarnessAuthenticationSession,
        workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsInset {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(session.methodName)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    SettingsPill(
                        session.state.replacingOccurrences(of: "_", with: " ").capitalized,
                        tone: session.state == "waiting_for_user" ? .warning : .neutral
                    )
                    if session.state == "waiting_for_user" {
                        Button("Cancel") {
                            model.cancelHarnessSignIn(configuration: workspace)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                Text(session.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)

                if let notice = session.notice {
                    SettingsNote(notice)
                }

                if let url = session.verificationURL {
                    Button("Open Sign-In Page") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                }

                if let userCode = session.userCode {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("One-time code")
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                            Text(userCode)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Copy Code") { copy(userCode) }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }
                }

                if session.state == "waiting_for_user",
                   session.acceptsAuthorizationCode {
                    HStack {
                        credentialInput(session, workspace: workspace)
                        Button("Submit") {
                            submitAuthorizationCode(workspace)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(
                            authorizationCode.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                    }
                }

                if let error = session.error {
                    SettingsError(error)
                }
            }
        }
    }

    @ViewBuilder
    private func credentialInput(
        _ session: RemoteHarnessAuthenticationSession,
        workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        let label = session.credentialInputLabel ?? "Authorization code"
        if session.credentialInputSecret == true {
            SecureField(label, text: $authorizationCode)
                .settingsInput()
                .onSubmit { submitAuthorizationCode(workspace) }
        } else {
            TextField(label, text: $authorizationCode)
                .settingsInput()
                .onSubmit { submitAuthorizationCode(workspace) }
        }
    }

    private func submitAuthorizationCode(
        _ workspace: RemoteWorkspaceConfiguration
    ) {
        let code = authorizationCode.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !code.isEmpty else { return }
        model.submitAuthorizationCode(code, configuration: workspace)
        authorizationCode = ""
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
