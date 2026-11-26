import SwiftUI
import WovenProtocol

struct SettingsBackgroundServerView: View {
    @Bindable var application: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
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

    /// This Mac's server; another machine's is managed from its workspace page.
    private var machineID: String? { model.thisMachine?.id }

    var body: some View {
        SettingsPage(title: "Background Server", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsSection(detail: "The server keeps agents and scheduled work running when the app window closes.") {
                serverRow
                if let error { SettingsError(error) }
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

    private var state: MachineConnectionState? { model.thisMachine?.connection }

    private var serverRow: some View {
        SettingsRow(title: "Status") {
            if let actionInProgress {
                ProgressView().controlSize(.small)
                Text(actionInProgress == .start ? "Starting server…" : actionInProgress == .restart ? "Restarting server…" : "Stopping server…")
                    .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
            } else {
                SettingsStatus(state?.displayName ?? "Checking server…",
                               tone: state == .online ? .good : state == .offline ? .warning : .neutral)
                Group {
                    if state == .stopped {
                        Button("Start") { perform(.start) }
                    } else if state == .online {
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
                let result = action == .restart
                    ? try await model.restartServer(on: machineID, confirmed: confirmed)
                    : try await model.stopServer(on: machineID, confirmed: confirmed)
                if result.confirmationRequired { confirmationAction = action; return }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Screen-sleep protection, as one choice.
private struct SettingsKeepWorkingSection: View {
    @Bindable var model: MachinesStore

    private enum PowerChoice: CaseIterable, Hashable {
        case never, externalPower, battery, always

        init(_ policy: IdleSleepPolicy) {
            switch (policy.externalPower, policy.batteryPower) {
            case (false, false): self = .never
            case (true, false): self = .externalPower
            case (false, true): self = .battery
            case (true, true): self = .always
            }
        }

        var policy: IdleSleepPolicy {
            IdleSleepPolicy(externalPower: self == .externalPower || self == .always,
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

    var body: some View {
        SettingsSection(title: "Keep working", detail: "Keep this Mac awake only while agent work is running.") {
            SettingsRow(title: "When the screen sleeps") {
                SettingsPicker("Keep working when the screen sleeps", selection: Binding(
                    get: { PowerChoice(model.idleSleepPolicy) },
                    set: { choice in Task { await model.setIdleSleepPolicy(choice.policy) } }
                ), options: PowerChoice.allCases, popoverWidth: 160) { $0.title }
                .disabled(model.isChangingIdleSleepPolicy)
            }
            if let message = model.idleSleepError { SettingsError(message) }
            SettingsHelp {
                SettingsNote("When the screen sleeps: the screen can turn off and lock while work continues. Closing the lid or choosing Sleep can still pause work.")
            }
        }
        .task { await model.loadIdleSleepPolicy() }
    }
}
