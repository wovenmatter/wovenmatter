import ServiceManagement
import SwiftUI

struct SettingsBackgroundServerView: View {
    @Bindable var application: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var selectedMachineID: String?
    @State private var confirmationAction: ServerAction?
    @State private var error: String?
    @State private var actionInProgress: ServerAction?

    private enum ServerAction { case start, stop, restart }

    private var model: MachinesStore { application.machines }

    init(model: ApplicationModel, reservesRailControlSpace: Bool = false, onBack: @escaping () -> Void) {
        self.application = model
        self.reservesRailControlSpace = reservesRailControlSpace
        self.onBack = onBack
    }

    private var machineID: String? { selectedMachineID ?? model.thisMachine?.id }

    private var serverOptions: [String?] {
        [nil] + model.otherMachines.map { Optional($0.id) }
    }

    var body: some View {
        SettingsPage(title: "Background Server", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsSection(detail: "The server keeps agents and scheduled work running when the app window closes.") {
                if !model.otherMachines.isEmpty {
                    SettingsRow(title: "Server") {
                        SettingsPicker("Server", selection: $selectedMachineID, options: serverOptions) { id in
                            id.flatMap { model.machine(id: $0)?.name } ?? "This Mac"
                        }
                    }
                }
                serverRow
                if let error { SettingsError(error) }
                RuntimeInspectionView(model: model, machineID: machineID)
                    .id(machineID)
            }
            SettingsKeepWorkingSection(model: model)
        }
        .alert("Stop current work?", isPresented: Binding(get: { confirmationAction != nil }, set: { if !$0 { confirmationAction = nil } })) {
            Button("Cancel", role: .cancel) { confirmationAction = nil }
            Button(confirmationAction == .restart ? "Stop work and restart" : "Stop work and server", role: .destructive) {
                let action = confirmationAction ?? .stop
                confirmationAction = nil
                perform(action, confirmed: true)
            }
        } message: {
            Text("This server has active work. Continuing will cancel its current work before stopping the server.")
        }
    }

    private var status: MachineServerStatus? { machineID.flatMap { model.serverStatus(on: $0) } }

    private var serverRow: some View {
        SettingsRow(title: "Status") {
            if let actionInProgress {
                ProgressView().controlSize(.small)
                Text(actionInProgress == .start ? "Starting server…" : actionInProgress == .restart ? "Restarting server…" : "Stopping server…")
                    .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
            } else {
                SettingsStatus(status?.state.displayName ?? "Checking server…",
                               tone: status?.state == .running ? .good : status?.state == .unavailable ? .warning : .neutral)
                Group {
                    if status?.state == .stopped {
                        Button("Start") { perform(.start) }
                    } else if status?.state == .running {
                        Button("Stop", role: .destructive) { perform(.stop) }
                        Button("Restart") { perform(.restart) }
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }

    private func perform(_ action: ServerAction, confirmed: Bool = false) {
        guard actionInProgress == nil, let machineID else { return }
        actionInProgress = action; error = nil
        Task {
            defer { actionInProgress = nil }
            do {
                if action == .start {
                    try await model.startServer(on: machineID)
                    return
                }
                let result = try await model.stopServer(on: machineID, confirmed: confirmed)
                if result.confirmationRequired { confirmationAction = action; return }
                if action == .restart { try await model.startServer(on: machineID) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Screen sleep and closed-lid protection, as one choice each.
private struct SettingsKeepWorkingSection: View {
    @Bindable var model: MachinesStore

    private enum PowerChoice: CaseIterable, Hashable {
        case never, externalPower, battery, always

        init(_ policy: WorkPowerPolicy) {
            switch (policy.externalPower, policy.batteryPower) {
            case (false, false): self = .never
            case (true, false): self = .externalPower
            case (false, true): self = .battery
            case (true, true): self = .always
            }
        }

        var policy: WorkPowerPolicy {
            WorkPowerPolicy(externalPower: self == .externalPower || self == .always,
                            batteryPower: self == .battery || self == .always)
        }

        var title: String {
            switch self {
            case .never: "Never"
            case .externalPower: "On power"
            case .battery: "On battery"
            case .always: "Always"
            }
        }
    }

    private var power: MachinePower { model.power }
    private var helperUnavailable: Bool {
        if case .unavailable = power.closedLidHelper { return true }
        return false
    }
    /// Without the signed helper, closed-lid protection can only be reduced, one power source at a time.
    private var lidOptions: [PowerChoice] {
        guard helperUnavailable else { return PowerChoice.allCases }
        let current = power.closedLid
        return PowerChoice.allCases.filter {
            (!$0.policy.externalPower || current.externalPower) && (!$0.policy.batteryPower || current.batteryPower)
        }
    }

    var body: some View {
        SettingsSection(title: "Keep working", detail: "Keep this Mac awake only while agent work is running.") {
            SettingsRow(title: "When the screen sleeps") {
                SettingsPicker("Keep working when the screen sleeps", selection: Binding(
                    get: { PowerChoice(power.idleSleep) },
                    set: { choice in Task { await model.setIdleSleepPolicy(choice.policy) } }
                ), options: PowerChoice.allCases, popoverWidth: 160) { $0.title }
                .disabled(model.isChangingIdleSleepPolicy)
            }
            if let message = model.idleSleepError { SettingsError(message) }
            SettingsRow(title: "When the lid is closed") {
                SettingsPicker("Keep working when the lid is closed", selection: Binding(
                    get: { PowerChoice(power.closedLid) },
                    set: { choice in Task { await model.setClosedLidPolicy(choice.policy) } }
                ), options: lidOptions, popoverWidth: 160) { $0.title }
                .disabled(model.isChangingClosedLidPolicy
                    || (helperUnavailable && !power.closedLid.isEnabled))
            }
            lidStatus
            if let message = model.closedLidError ?? power.closedLidMessage { SettingsError(message) }
            SettingsHelp {
                SettingsNote("When the screen sleeps: the screen can turn off and lock while work continues. Closing the lid or choosing Sleep can still pause work.")
                SettingsNote("When the lid is closed: this also prevents Sleep from the Apple menu while work is active. Stop the work or turn this off to allow sleep. The Mac stays awake internally, so keep it ventilated.")
            }
        }
    }

    @ViewBuilder private var lidStatus: some View {
        if case .unavailable(let reason) = power.closedLidHelper {
            SettingsNote(reason)
        } else if power.closedLid.isEnabled {
            if power.closedLidHelper == .approvalRequired {
                SettingsRow(title: "Approval needed", detail: "Approve Woven Matter in macOS Login Items & Extensions to enable protection.") {
                    Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(SettingsQuietButtonStyle())
                }
            } else if power.closedLidHelper == .notRegistered {
                Button("Set up closed-lid protection") {
                    Task { await model.setClosedLidPolicy(power.closedLid) }
                }.buttonStyle(SettingsQuietButtonStyle())
            } else if power.closedLidMessage == nil && model.closedLidError == nil {
                SettingsNote(power.isProtectingClosedLid ? "Closed-lid protection is active."
                    : "Protection will activate during work on the selected power sources.")
            }
        }
    }
}

struct RuntimeInspectionView: View {
    @Bindable var model: MachinesStore
    var machineID: String?

    private var snapshot: RuntimeInspection? { machineID.flatMap { model.inspections[$0] } }
    private var error: String? { machineID.flatMap { model.inspectionErrors[$0] } }
    private var connected: Bool { machineID.flatMap { model.machine(id: $0)?.isOnline } == true && snapshot != nil }

    private var summary: String {
        guard let snapshot else { return connected ? "Waiting" : "Disconnected" }
        let count = snapshot.items.count
        return (count == 1 ? "1 item" : "\(count) items") + (connected ? "" : ", disconnected")
    }

    var body: some View {
        SettingsSummaryRow("Activity", value: summary, tone: connected ? .good : .neutral) {
            if let snapshot {
                Text("\(connected ? "Observed" : "Last observed") \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                RuntimeInspectionInventoryView(items: snapshot.items, connected: connected)
                if snapshot.items.isEmpty { SettingsNote("No managed activity in this scope.") }
            } else {
                SettingsNote(error ?? "Waiting for the server…")
            }
            if snapshot != nil, let error { SettingsNote(error) }
        }
        .task(id: machineID) {
            if let machineID { model.refreshInspection(on: machineID) }
        }
    }
}
