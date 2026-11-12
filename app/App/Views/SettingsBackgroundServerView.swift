import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsBackgroundServerView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var workspaceID: UUID?
    @State private var confirmationAction: String?
    @State private var error: String?
    @State private var actionInProgress: String?
    @State private var availability = ServerAvailability.checking

    private enum ServerAvailability {
        case checking, running, stopped, unavailable
        var label: String {
            switch self {
            case .checking: "Checking server…"
            case .running: "Running"
            case .stopped: "Stopped"
            case .unavailable: "Server unavailable"
            }
        }
        var tone: SettingsStatusTone {
            switch self {
            case .running: .good
            case .checking, .stopped: .neutral
            case .unavailable: .warning
            }
        }
    }

    private var leaseURL: URL {
        get throws { try ApplicationModel.dashboardSupportDirectory().appending(path: LocalExecutionRole.backend.leaseFileName) }
    }

    private var serverOptions: [UUID?] {
        [nil] + model.remoteWorkspaces.workspaces.map { Optional($0.id) }
    }

    var body: some View {
        SettingsPage(title: "Background Server", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsSection(detail: "The server keeps agents and scheduled work running when the app window closes.") {
                if !model.remoteWorkspaces.workspaces.isEmpty {
                    SettingsRow(title: "Server") {
                        SettingsPicker("Server", selection: $workspaceID, options: serverOptions) { id in
                            id.flatMap { id in model.remoteWorkspaces.workspaces.first { $0.id == id }?.name } ?? "This Mac"
                        }
                    }
                }
                if workspaceID == nil {
                    serverRow
                    if DevelopmentLaunch.mode != nil {
                        SettingsNote("This development profile uses its own server and data.")
                    }
                }
                if let error { SettingsError(error) }
                RuntimeInspectionView(model: model, workspaceID: workspaceID, onConnectionChange: observeConnection)
                    .id(workspaceID)
            }
            SettingsKeepWorkingSection(model: model)
        }
        .alert("Stop current work?", isPresented: Binding(get: { confirmationAction != nil }, set: { if !$0 { confirmationAction = nil } })) {
            Button("Cancel", role: .cancel) { confirmationAction = nil }
            Button(confirmationAction == "restart" ? "Stop work and restart" : "Stop work and server", role: .destructive) {
                let action = confirmationAction ?? "stop"
                confirmationAction = nil
                perform(action, confirmed: true)
            }
        } message: {
            Text("This server has active work. Continuing will cancel its current work before stopping the server.")
        }
    }

    private var serverRow: some View {
        SettingsRow(title: "Status") {
            if let actionInProgress {
                ProgressView().controlSize(.small)
                Text(actionInProgress == "start" ? "Starting server…" : actionInProgress == "restart" ? "Restarting server…" : "Stopping server…")
                    .font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
            } else {
                SettingsStatus(availability.label, tone: availability.tone)
                Group {
                    if availability == .stopped {
                        Button("Start") { perform("start") }
                    } else if availability == .running {
                        Button("Stop", role: .destructive) { perform("stop") }
                        Button("Restart") { perform("restart") }
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!model.isBackendFrontend)
            }
        }
    }

    private func observeConnection(_ connected: Bool) {
        guard workspaceID == nil, actionInProgress == nil else { return }
        if connected { availability = .running; return }
        // A failed RPC alone cannot prove that an execution owner stopped.
        do { availability = try WovenMatterBackendProcess.executionOwnerIsPresent(leaseURL: leaseURL) ? .unavailable : .stopped }
        catch { availability = .unavailable }
    }

    private func perform(_ action: String, confirmed: Bool = false) {
        guard actionInProgress == nil else { return }
        actionInProgress = action; error = nil
        Task {
            defer { actionInProgress = nil }
            do {
                if action == "start" {
                    try await model.startBackgroundServer()
                    availability = .running
                    return
                }
                let result = try await model.stopBackgroundServer(confirmed: confirmed)
                if result.confirmationRequired { confirmationAction = action; return }
                try await WovenMatterBackendProcess.waitForExecutionOwnerToExit(leaseURL: leaseURL)
                availability = .stopped
                if action == "restart" {
                    try await model.startBackgroundServer()
                    availability = .running
                }
            } catch {
                self.error = error.localizedDescription
                availability = .unavailable
            }
        }
    }
}

/// Screen sleep and closed-lid protection, as one choice each.
private struct SettingsKeepWorkingSection: View {
    @Bindable var model: ApplicationModel
    @State private var closedLidHelperSetup: ClosedLidHelperSetup = .unavailable

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

    private var lidSnapshot: ClosedLidProtectionSnapshot { model.closedLidProtection.snapshot }
    /// Without the signed helper, closed-lid protection can only be reduced, one power source at a time.
    private var lidOptions: [PowerChoice] {
        guard closedLidHelperSetup == .unavailable else { return PowerChoice.allCases }
        let current = lidSnapshot.policy
        return PowerChoice.allCases.filter {
            (!$0.policy.externalPower || current.externalPower) && (!$0.policy.batteryPower || current.batteryPower)
        }
    }

    var body: some View {
        SettingsSection(title: "Keep working", detail: "Keep this Mac awake only while agent work is running.") {
            SettingsRow(title: "When the screen sleeps") {
                SettingsPicker("Keep working when the screen sleeps", selection: Binding(
                    get: { PowerChoice(model.activeWorkSleepPrevention.snapshot.policy) },
                    set: { choice in Task { await model.setIdleSleepPolicyFromSettings(choice.policy) } }
                ), options: PowerChoice.allCases, popoverWidth: 160) { $0.title }
                .disabled(model.isChangingIdleSleepPolicy)
            }
            if let message = model.idleSleepSettingsError { SettingsError(message) }
            SettingsRow(title: "When the lid is closed") {
                SettingsPicker("Keep working when the lid is closed", selection: Binding(
                    get: { PowerChoice(lidSnapshot.policy) },
                    set: { choice in Task { await model.setClosedLidPolicyFromSettings(choice.policy) } }
                ), options: lidOptions, popoverWidth: 160) { $0.title }
                .disabled(model.isChangingClosedLidPolicy
                    || (closedLidHelperSetup == .unavailable && !lidSnapshot.policy.isEnabled))
            }
            lidStatus
            if let message = model.closedLidSettingsError ?? lidSnapshot.message { SettingsError(message) }
            SettingsHelp {
                SettingsNote("When the screen sleeps: the screen can turn off and lock while work continues. Closing the lid or choosing Sleep can still pause work.")
                SettingsNote("When the lid is closed: this also prevents Sleep from the Apple menu while work is active. Stop the work or turn this off to allow sleep. The Mac stays awake internally, so keep it ventilated.")
            }
        }
        .task {
            while !Task.isCancelled {
                closedLidHelperSetup = ClosedLidHelperRegistration.status
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    @ViewBuilder private var lidStatus: some View {
        if closedLidHelperSetup == .unavailable {
            SettingsNote(ClosedLidHelperRegistration.unavailableReason)
        } else if lidSnapshot.policy.isEnabled {
            if closedLidHelperSetup == .approvalRequired {
                SettingsRow(title: "Approval needed", detail: "Approve Woven Matter in macOS Login Items & Extensions to enable protection.") {
                    Button("Open System Settings") { ClosedLidHelperRegistration.openApprovalSettings() }
                        .buttonStyle(SettingsQuietButtonStyle())
                }
            } else if closedLidHelperSetup == .notRegistered {
                Button("Set up closed-lid protection") {
                    Task { await model.setClosedLidPolicyFromSettings(lidSnapshot.policy) }
                }.buttonStyle(SettingsQuietButtonStyle())
            } else if lidSnapshot.message == nil && model.closedLidSettingsError == nil {
                SettingsNote(lidSnapshot.isProtecting ? "Closed-lid protection is active."
                    : "Protection will activate during work on the selected power sources.")
            }
        }
    }
}

struct RuntimeInspectionView: View {
    @Bindable var model: ApplicationModel
    var workspaceID: UUID?
    var onConnectionChange: ((Bool) -> Void)?
    @State private var snapshot: RuntimeInspection?
    @State private var connected = false
    @State private var error: String?

    private var summary: String {
        guard let snapshot else { return connected ? "Waiting" : "Disconnected" }
        let count = snapshot.items.count
        return (count == 1 ? "1 item" : "\(count) items") + (connected ? "" : ", disconnected")
    }

    var body: some View {
        SettingsSummaryRow("Activity", value: summary, tone: connected ? .good : .neutral) {
            if let snapshot {
                Text("\(connected ? "Observed" : "Last observed") \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                RuntimeInspectionInventoryView(items: snapshot.items, connected: connected)
                if snapshot.items.isEmpty { SettingsNote("No managed activity in this scope.") }
            } else {
                SettingsNote(error ?? "Waiting for the execution owner…")
            }
            if snapshot != nil, let error { SettingsNote(error) }
        }
        .task(id: workspaceID?.uuidString ?? "local") {
            while !Task.isCancelled {
                do {
                    let value = try await model.runtimeInspection(.init(workspaceID: workspaceID))
                    guard !Task.isCancelled else { return }
                    snapshot = value; connected = true; error = nil
                    onConnectionChange?(true)
                } catch {
                    guard !Task.isCancelled else { return }
                    connected = false; self.error = error.localizedDescription
                    onConnectionChange?(false)
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}
