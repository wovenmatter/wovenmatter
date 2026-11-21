import AppKit
import SwiftUI

/// Every machine in one list. Machine details open in place; agents' install,
/// sign-in, and update controls live on each agent page.
struct SettingsWorkspacesView: View {
    @Bindable var model: MachinesStore
    let application: ApplicationModel
    var reservesRailControlSpace = false
    var initialMachineID: String?
    var onMoreRuntime: (AgentRuntimeKind, Machine) -> Void
    var onBack: () -> Void
    @State private var selectedMachineID: String?
    @State private var addingMachine = false
    @State private var setupMachine: Machine?
    @State private var hostName = ""
    @State private var userName = ""
    @State private var acknowledgedMachineAccess = false
    @State private var pendingRemoval: Machine?
    @State private var logsMachine: Machine?

    private var trimmedHost: String { hostName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String? {
        let user = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? nil : user
    }

    private func deploymentProgress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            SettingsNote(message)
        }
        .accessibilityElement(children: .combine)
    }

    private var pageTitle: String {
        selectedMachine?.name ?? (addingMachine ? "Add Workspace" : "Workspaces")
    }

    private var workspacePage: some View {
        SettingsPage(
            title: pageTitle,
            detail: selectedMachine.map(machineLocation),
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: selectedMachine != nil || addingMachine ? "Workspaces" : "Settings",
            onBack: {
                if selectedMachineID != nil {
                    selectedMachineID = nil
                } else if addingMachine {
                    addingMachine = false
                } else {
                    onBack()
                }
            }
        ) {
            if let selectedMachine {
                machineSection(selectedMachine)
                agentsSection(selectedMachine)
                detailsSection(selectedMachine)
                if let progress = model.progress {
                    deploymentProgress(progress)
                }
            } else if addingMachine {
                machineCard
                if currentPreflight?.ready == true { createCard }
                if let progress = model.progress { deploymentProgress(progress) }
            } else {
                machineList
                if let progress = model.progress { deploymentProgress(progress) }
            }
            if let error = model.errorMessage {
                SettingsError(error)
            }
        }
        .id(selectedMachineID)
        .task(id: selectedMachineID) {
            if let selectedMachine {
                model.refreshHarnesses(on: selectedMachine.id)
            } else {
                model.findComputers()
            }
        }
    }

    private var workspacePresentations: some View {
        workspacePage
        .sheet(item: $logsMachine) { machine in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(machine.name) logs").font(.settingsSection)
                    Spacer()
                    Button("Refresh") { model.loadLogs(on: machine.id) }
                    Button("Done") { logsMachine = nil }
                }.buttonStyle(SettingsQuietButtonStyle())
                if let error = model.errorMessage { SettingsError(error) }
                ScrollView {
                    Text(model.serverLogs[machine.id] ?? "Loading logs…")
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }
            .padding(24).frame(width: 760, height: 520)
            .foregroundStyle(WovenPalette.foreground).background(WovenPalette.background)
        }
        .onChange(of: hostName + userName) { _, _ in
            acknowledgedMachineAccess = false
        }
        .onChange(of: model.machines.map(\.id)) { oldIDs, machineIDs in
            if let selectedMachineID, !machineIDs.contains(selectedMachineID) {
                self.selectedMachineID = nil
            }
            if machineIDs.count > oldIDs.count { addingMachine = false }
        }
        .onAppear {
            selectedMachineID = selectedMachineID ?? initialMachineID
            presentPendingSetup()
        }
        .debugRequest("add-workspace") { selectedMachineID = nil; addingMachine = true }
        .onChange(of: model.pendingHarnessSetupMachineIDs) { _, _ in presentPendingSetup() }
        .sheet(item: $setupMachine) { machine in
            RemoteHarnessSetupView(application: application, machine: machine) {
                model.dismissHarnessSetup(machine.id)
                setupMachine = nil
            }
        }
    }

    private var workspaceConfirmations: some View {
        workspacePresentations
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "machine")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingRemoval {
                Button("Remove", role: .destructive) {
                    model.remove(pendingRemoval.id)
                    self.pendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This stops and uninstalls the server there, then removes the machine, its chats and its folders from every machine.")
        }
    }

    var body: some View {
        workspaceConfirmations
    }

    private func presentPendingSetup() {
        guard setupMachine == nil,
              let machine = model.machines.first(where: { model.pendingHarnessSetupMachineIDs.contains($0.id) }) else { return }
        setupMachine = machine
    }

    private var selectedMachine: Machine? {
        selectedMachineID.flatMap { model.machine(id: $0) }
    }

    private var currentPreflight: MachinePreflight? {
        trimmedHost.isEmpty ? nil : model.machinePreflights[trimmedHost]
    }

    @ViewBuilder private var machineList: some View {
        SettingsSection(title: "This Mac", detail: "Create a blank project or link an existing directory from the sidebar.") {
            SettingsRow(title: "Local workspace", detail: model.thisMachine?.name) {
                let running = model.thisMachine.flatMap { model.serverStatus(on: $0.id) }?.isRunning == true
                SettingsStatus(running ? "Ready" : "Setup required", tone: running ? .good : .warning)
            }
        }
        SettingsSection(title: "Remote workspaces", detail: "Agents and files on your other machines.") {
            if model.otherMachines.isEmpty {
                SettingsEmpty("No remote workspaces yet.")
            } else {
                VStack(spacing: 2) {
                    ForEach(model.otherMachines) { machine in machineRow(machine) }
                }
            }
            Button("Add workspace") { addingMachine = true }
                .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    private func statusLabel(_ machine: Machine) -> String {
        if model.isBusy(machine.id) || model.isMaintainingHarnesses(on: machine.id) { return "Working" }
        if !machine.isOnline { return "Offline" }
        return model.serverStatus(on: machine.id)?.state.displayName ?? "Unknown"
    }

    private func isRunning(_ machine: Machine) -> Bool {
        machine.isOnline && model.serverStatus(on: machine.id)?.isRunning == true
    }

    private func machineRow(_ machine: Machine) -> some View {
        SettingsDestinationRow(
            title: machine.name,
            detail: machineLocation(machine),
            status: statusLabel(machine),
            statusTone: isRunning(machine) ? .good : .warning,
            icon: { MachineConnectionIcon(platform: machine.platform, size: 15) },
            action: { selectedMachineID = machine.id }
        )
    }

    private func machineSection(_ machine: Machine) -> some View {
        let status = model.serverStatus(on: machine.id)
        let busy = model.isBusy(machine.id)
        let maintaining = model.isMaintainingHarnesses(on: machine.id)
        return SettingsSection {
            SettingsRow(title: "Status") {
                SettingsStatus(statusLabel(machine), tone: isRunning(machine) ? .good : .warning)
                Menu("Manage") {
                    if let status {
                        // A stopped Mac cannot be reached to start it.
                        if machine.platform == .linux {
                            Button("Start") { manage { try await model.startServer(on: machine.id) } }
                                .disabled(status.isRunning || maintaining)
                        }
                        Button("Stop") { manage { _ = try await model.stopServer(on: machine.id, confirmed: true) } }
                            .disabled(!status.isRunning || maintaining)
                        Button("Restart") { manage { _ = try await model.restartServer(on: machine.id, confirmed: true) } }
                            .disabled(!status.isRunning || maintaining)
                        Divider()
                    }
                    if machine.platform == .linux {
                        Button("Update server") { model.updateServer(on: machine.id) }
                            .disabled(maintaining)
                    }
                    Button("Logs") { model.loadLogs(on: machine.id); logsMachine = machine }
                        .disabled(machine.platform == .mac && !machine.isOnline)
                    Divider()
                    Button("Remove…", role: .destructive) { pendingRemoval = machine }
                        .disabled(maintaining)
                }
                .menuStyle(.button)
                .fixedSize()
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(busy)
            }
            if status == nil {
                SettingsEmpty("This machine's status appears when it is online.")
            }
            if maintaining {
                SettingsNote("Harnesses are installing or updating. Stopping, updating or removing this workspace waits until they finish.")
            }
            if let warning = status?.storageWarning, !warning.isEmpty {
                storageWarning(warning)
            }
        }
    }

    private func manage(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                model.errorMessage = nil
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func detailsSection(_ machine: Machine) -> some View {
        let status = model.serverStatus(on: machine.id)
        return SettingsSection(title: "Details") {
            if let status {
                SettingsSummaryRow("Storage", value: machineStorageLabel(status)) {
                    SettingsValueRow(label: "Health", value: status.health?.capitalized ?? "Starting")
                    SettingsValueRow(label: "Workspace data", value: workspaceUsageLabel(status))
                    SettingsValueRow(label: "Machine storage", value: machineStorageLabel(status))
                }
            }
        }
    }

    private func machineLocation(_ machine: Machine) -> String {
        let status = model.serverStatus(on: machine.id)
        return status?.hostName ?? machine.platform.displayName
    }

    private var machineCard: some View {
        SettingsSection(title: "Machine", detail: "Choose a machine, then check that it can run a workspace. Remote workspaces run Woven Matter directly on Linux.") {
            SettingsField("Tailnet machines") {
                VStack(alignment: .leading, spacing: 8) {
                    let onlineMachines = model.tailnetComputers
                    if onlineMachines.isEmpty, !model.isFindingComputers {
                        Text("No online machines discovered")
                            .font(.settingsSecondary)
                            .foregroundStyle(WovenPalette.mutedForeground)
                    }
                    ForEach(onlineMachines) { machine in
                        Button {
                            hostName = machine.hostName
                            inspectMachine()
                        } label: {
                            HStack(spacing: 8) {
                                Text(machine.name)
                                if trimmedHost == machine.hostName {
                                    Text("Selected").font(.settingsSecondary.weight(.medium))
                                }
                            }
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                    Button(model.isFindingComputers ? "Discovering…" : "Refresh") {
                        model.findComputers()
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isFindingComputers)
                }
            }

            SettingsField("Tailscale machine") {
                TextField("machine.tailnet-name.ts.net", text: $hostName)
                    .wovenInput()
                    .onSubmit { inspectMachine() }
            }
            SettingsField("Remote username (optional)") {
                TextField("Resolved by SSH config", text: $userName)
                    .wovenInput()
            }
            SettingsNote("Requires connected Tailscale on both machines. Uses your SSH agent; Woven Matter does not store SSH keys.")
            let inspecting = model.inspectingHostnames.contains(trimmedHost)
            Button(inspecting ? "Inspecting machine…" : "Inspect machine") { inspectMachine() }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(inspecting || trimmedHost.isEmpty)
            if currentPreflight == nil, !inspecting {
                Text(trimmedHost.isEmpty
                    ? "Select a machine to see whether it is ready."
                    : "Inspect this machine to continue. Inspection makes no changes.")
                    .font(.settingsSecondary)
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            if let error = model.machineErrors[trimmedHost] { SettingsError(error) }
            if let preflight = currentPreflight {
                SettingsInset {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsValueRow(label: "Selected machine", value: trimmedHost)
                        SettingsValueRow(
                            label: "Machine status",
                            value: preflight.ready ? "Ready to create a workspace" : "Needs attention"
                        )
                        SettingsValueRow(
                            label: "Runtime",
                            value: "Native Linux service · \(preflight.architecture)"
                        )
                        SettingsValueRow(label: "Machine storage", value: storageCapacityLabel(
                            capacity: preflight.storageCapacityBytes, available: preflight.storageAvailableBytes))
                        if !preflight.limitations.isEmpty {
                            Text(preflight.limitations.joined(separator: " "))
                                .font(.settingsSecondary)
                                .foregroundStyle(WovenPalette.mutedForeground)
                        }
                    }
                }
            }
        }
        .disabled(installing)
    }

    private var installing: Bool { model.installingHostnames.contains(trimmedHost) }

    private func inspectMachine() {
        guard !trimmedHost.isEmpty else { return }
        model.inspectMachine(hostName: trimmedHost, userName: trimmedUser)
    }

    private var createCard: some View {
        SettingsSection(title: "Create workspace", detail: "On \(trimmedHost)") {
            SettingsNote("Files use available disk space on the remote machine.")
            SettingsNote(hostWarning(user: trimmedUser, host: hostName))
            Toggle("I understand this workspace's access to the machine", isOn: $acknowledgedMachineAccess)

            Button(installing ? "Creating…" : "Create workspace") {
                model.installServer(hostName: trimmedHost, userName: trimmedUser)
            }
            .buttonStyle(WovenPrimaryButtonStyle())
            .disabled(installing || currentPreflight?.ready != true || !acknowledgedMachineAccess)
        }
    }

    private func hostWarning(user: String?, host: String) -> String {
        "This workspace runs agents as \(user ?? "the SSH user")@\(host) with that user's full permissions. There is no container isolation."
    }

    private func agentsSection(_ machine: Machine) -> some View {
        SettingsSection(title: "Agents") {
            let harnesses = model.harnesses(on: machine.id)
            if harnesses.isEmpty {
                SettingsEmpty("Start the workspace or refresh to check for agents.")
            } else {
                VStack(spacing: 2) {
                    ForEach(harnesses) { harness in
                        SettingsDestinationRow(
                            title: harness.runtimeKind.displayName,
                            detail: harness.runtimeKind == .defaultAgent
                                ? HarnessAccountPresentation.providerSummary(model.providerSignIns(on: machine.id))
                                : HarnessAccountPresentation.accountLabel(harness.runtimeKind,
                                    status: model.signInStatus(harness.runtimeKind, on: machine.id)),
                            status: harness.state.displayName,
                            statusTone: harness.state == .ready ? .good : .warning,
                            icon: { HarnessLogoIcon(logo: HarnessLogo(runtimeKind: harness.runtimeKind), size: 15) },
                            action: { onMoreRuntime(harness.runtimeKind, machine) }
                        )
                    }
                }
            }
            Button("Set up harnesses") { setupMachine = machine }
                .buttonStyle(SettingsQuietButtonStyle())
            if model.harnessInventoryUnavailable.contains(machine.id) {
                SettingsNote("Runtime inventory unavailable. Open an agent and check for updates to retry.")
            }
        }
    }

    private func workspaceUsageLabel(_ status: MachineServerStatus) -> String {
        let usage = status.storageUsedBytes.map {
            ByteCountFormatter.string(fromByteCount: max($0, 0), countStyle: .file)
        } ?? "Usage unavailable"
        return "\(usage) · no fixed limit"
    }

    private func machineStorageLabel(_ status: MachineServerStatus) -> String {
        storageCapacityLabel(
            capacity: status.storageCapacityBytes,
            available: status.storageAvailableBytes
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
