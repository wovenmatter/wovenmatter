import AppKit
import SwiftUI
import WovenProtocol

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedHost: String { hostName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String? {
        let user = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? nil : user
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
                if let error = model.serverErrors[selectedMachine.id] { SettingsError(error) }
            } else if addingMachine {
                machineCard
                if currentPreflight?.ready == true { createCard }
            } else {
                machineList
                if let error = model.listError { SettingsError(error) }
            }
        }
        .id(selectedMachineID)
        .task(id: selectedMachineID) {
            if let selectedMachine {
                model.refreshHarnessesIfStale(on: selectedMachine.id)
                await model.readStorage(on: selectedMachine.id)
            } else {
                model.findMachines()
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
                if let error = model.serverErrors[machine.id] { SettingsError(error) }
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
        .onChange(of: model.machines.map(\.id)) { _, machineIDs in
            if let selectedMachineID, !machineIDs.contains(selectedMachineID) {
                self.selectedMachineID = nil
            }
        }
        // Add Workspace stays open while the install runs, then opens the new machine.
        .onChange(of: model.finishedInstalls) { _, finished in
            guard addingMachine, let machineID = finished[trimmedHost] else { return }
            model.finishedInstalls[trimmedHost] = nil
            addingMachine = false
            selectedMachineID = machineID
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
                let running = model.thisMachine?.isOnline == true
                let starting = model.thisMachine?.connection == .starting
                SettingsStatus(running ? "Ready" : starting ? "Starting" : "Setup required",
                               tone: running ? .good : starting ? .neutral : .warning)
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
        if machine.connection != .starting, model.isBusy(machine.id) || model.isMaintainingHarnesses(on: machine.id) {
            return "Working"
        }
        return machine.connection.displayName
    }

    private func statusTone(_ machine: Machine) -> SettingsStatusTone {
        switch machine.connection {
        case .online: .good
        case .starting: .neutral
        case .stopped, .offline: .warning
        }
    }

    private func machineRow(_ machine: Machine) -> some View {
        SettingsDestinationRow(
            title: machine.name,
            detail: machineLocation(machine),
            status: statusLabel(machine),
            statusTone: statusTone(machine),
            icon: { MachineConnectionIcon(platform: machine.platform, size: 15) },
            action: { selectedMachineID = machine.id }
        )
    }

    private func machineSection(_ machine: Machine) -> some View {
        let busy = model.isBusy(machine.id)
        let maintaining = model.isMaintainingHarnesses(on: machine.id)
        return SettingsSection {
            SettingsRow(title: "Status") {
                SettingsStatus(statusLabel(machine), tone: statusTone(machine))
                Menu("Manage") {
                    // A stopped Mac cannot be reached to start it.
                    if machine.platform == .linux {
                        Button("Start") { manage(machine.id) { try await model.startServer(on: machine.id) } }
                            .disabled(machine.isOnline || maintaining)
                    }
                    Button("Stop") { manage(machine.id) { _ = try await model.stopServer(on: machine.id, confirmed: true) } }
                        .disabled(!machine.isOnline || maintaining)
                    Button("Restart") { manage(machine.id) { _ = try await model.restartServer(on: machine.id, confirmed: true) } }
                        .disabled(!machine.isOnline || maintaining)
                    Divider()
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
            if maintaining {
                SettingsNote("Harnesses are installing or updating. Stopping, updating or removing this workspace waits until they finish.")
            }
        }
    }

    /// A machine's action; its error shows on that machine's page until its next action.
    private func manage(_ machineID: String, _ action: @escaping () async throws -> Void) {
        model.serverErrors[machineID] = nil
        Task {
            do {
                try await action()
            } catch {
                model.serverErrors[machineID] = error.localizedDescription
            }
        }
    }

    /// Shown once the machine's own server has reported its disk.
    @ViewBuilder private func detailsSection(_ machine: Machine) -> some View {
        if let storage = model.machineStorage[machine.id] {
            SettingsSection(title: "Details") {
                SettingsValueRow(label: "Storage", value: storageCapacityLabel(
                    capacity: storage.capacityBytes, available: storage.availableBytes))
            }
        }
    }

    private func machineLocation(_ machine: Machine) -> String {
        model.address(of: machine.id) ?? machine.platform.displayName
    }

    private var machineCard: some View {
        SettingsSection(title: "Machine", detail: "Choose a machine, then check that it can run a workspace. Remote workspaces run Woven Matter directly on Linux.") {
            SettingsField("Tailnet machines") {
                VStack(alignment: .leading, spacing: 8) {
                    let onlineMachines = model.tailnetMachines
                    if onlineMachines.isEmpty, !model.isFindingMachines {
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
                    Button(model.isFindingMachines ? "Discovering…" : "Refresh") {
                        model.findMachines()
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isFindingMachines)
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
            if installing { installProgress(model.installStages[trimmedHost]) }
        }
    }

    /// Where the install has got to: a bar at the current stage's place among them all, and its name.
    private func installProgress(_ stage: InstallStage?) -> some View {
        let stages = InstallStage.allCases
        let index = stage.flatMap { stages.firstIndex(of: $0) } ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: (Double(index) + 0.5) / Double(stages.count))
                .progressViewStyle(.linear)
                .tint(WovenPalette.primary)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: index)
            SettingsNote(installStageLabel(stage ?? .checking))
        }
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func installStageLabel(_ stage: InstallStage) -> String {
        switch stage {
        case .checking: "Checking the machine…"
        case .packing: "Packing Woven Matter…"
        case .sending: "Sending to \(trimmedHost)…"
        case .node: "Installing Node…"
        case .starting: "Starting the server…"
        case .connecting: "Connecting…"
        }
    }

    private func hostWarning(user: String?, host: String) -> String {
        "This workspace runs agents as \(user ?? "the SSH user")@\(host) with that user's full permissions. There is no container isolation."
    }

    private func agentsSection(_ machine: Machine) -> some View {
        SettingsSection(title: "Agents") {
            let harnesses = model.harnesses(on: machine.id)
            if harnesses.isEmpty {
                // Until its first read returns, a machine that is up or coming up is being checked.
                if machine.connection == .starting || (machine.isOnline && !model.runtimesRead.contains(machine.id)
                    && !model.harnessInventoryUnavailable.contains(machine.id)) {
                    SettingsEmpty("Checking…")
                } else {
                    SettingsEmpty("Start the workspace or refresh to check for agents.")
                }
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
                            statusTone: harness.state == .ready ? .good : harness.state == .settingUp ? .neutral : .warning,
                            icon: { HarnessLogoIcon(logo: HarnessLogo(runtimeKind: harness.runtimeKind), size: 15) },
                            action: { onMoreRuntime(harness.runtimeKind, machine) }
                        )
                    }
                }
            }
            Button("Set up harnesses") { setupMachine = machine }
                .buttonStyle(SettingsQuietButtonStyle())
            if model.harnessInventoryUnavailable.contains(machine.id), machine.connection != .starting {
                SettingsNote("Runtime inventory unavailable. Open an agent and check for updates to retry.")
            }
        }
    }

    private func storageCapacityLabel(capacity: Int64?, available: Int64?) -> String {
        guard let capacity, let available else { return "Unavailable" }
        let free = ByteCountFormatter.string(fromByteCount: max(available, 0), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: max(capacity, 0), countStyle: .file)
        return "\(free) available of \(total)"
    }
}
