import SwiftUI

/// Settings → Updates: this Mac's version with Check for updates and Update this Mac, three
/// rows that update all your devices at once, then each device, which opens to update
/// everything on it or one part. Updates run side by side; only the rows an update covers wait.
struct SettingsUpdatesView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void

    private var updates: UpdatesStore { model.updates }
    private var thisMac: Machine? { model.machines.thisMachine }
    private var thisMacState: UpdatesStore.MachineState { thisMac.map { updates.state(of: $0.id) } ?? .init() }

    var body: some View {
        let shownBusy = updates.busyConfirmation?.id
        SettingsPage(
            title: "Updates",
            detail: "Woven Matter and its harnesses on this Mac and your other devices.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            overview
            allDevices
            yourDevices
        }
        .task {
            updates.loadIfNeeded()
            await model.bots.refresh()
        }
        .alert(busyTitle, isPresented: Binding(
            get: { updates.busyConfirmation != nil }, set: { if !$0, let shownBusy { updates.cancelBusy(shownBusy) } }
        ), presenting: updates.busyConfirmation) { confirmation in
            Button("Update now", role: .destructive) { updates.confirmBusy() }
            Button("Cancel", role: .cancel) { updates.cancelBusy(confirmation.id) }
        } message: { confirmation in
            Text(confirmation.items.joined(separator: "\n\n"))
        }
    }

    // MARK: This Mac, then all your devices

    /// "Woven Matter 0.4.3".
    private var thisMacProduct: String {
        "Woven Matter \(thisMac?.appVersion ?? "")".trimmingCharacters(in: .whitespaces)
    }

    private static let thisMacAbout = "This updates the Woven Matter desktop app on this Mac."

    private var thisMacIsBehind: Bool { thisMacState.appUpdateAvailable }

    private var appsAvailable: Bool {
        model.machines.machines.contains { updates.state(of: $0.id).appUpdateAvailable || updates.state(of: $0.id).botsOutdated }
    }

    private var harnessesAvailable: Bool {
        model.machines.machines.contains { (updates.state(of: $0.id).harnesses ?? []).contains(where: \.updateAvailable) }
    }

    /// This Mac's version, Check for updates and, when a release is newer, the page's one
    /// primary button: Update this Mac (only its Woven Matter app).
    private var overview: some View {
        SettingsSection {
            SettingsRow(title: "This Mac · " + thisMacProduct, detail: Self.thisMacAbout) {
                if updates.checking { ProgressView().controlSize(.small) }
                else if thisMacState.updatingApp { ProgressView().controlSize(.small) }
                else if thisMacIsBehind, let latest = updates.latestVersion {
                    SettingsStatus("\(latest) available", tone: .warning)
                } else if updates.checkedAt != nil {
                    SettingsStatus("Up to date", tone: .good)
                }
                Button(updates.checking ? "Checking…" : "Check for updates") { Task { await updates.checkAll() } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    // Usable while updates run: each check skips whatever is updating right now.
                    .disabled(updates.checking)
                if thisMacIsBehind, let thisMac {
                    Button("Update this Mac") { updates.start(.app(machineID: thisMac.id)) }
                        .buttonStyle(WovenPrimaryButtonStyle())
                        .disabled(!updates.canStart(.app(machineID: thisMac.id)))
                }
            }
            ForEach(updates.progress) { line in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    SettingsNote(line.text)
                }
            }
            if let notice = updates.notice { SettingsNote(notice) }
            if updates.releaseError != nil {
                SettingsNote("The newest release couldn't be checked, so devices are compared with this Mac.")
            }
            ForEach(updates.failures, id: \.self) { SettingsError($0) }
        }
    }

    /// One kind of thing on every device at once.
    private var allDevices: some View {
        SettingsSection {
            updateRow("Update everything", detail: "Update everything across all your devices.",
                      request: .everything, available: appsAvailable || harnessesAvailable)
            updateRow("Update just Woven Matter", detail: "Update just the Woven Matter apps across your devices.",
                      request: .apps, available: appsAvailable)
            updateRow("Update just the harnesses", detail: "Update just the harnesses across your devices.",
                      request: .harnesses, available: harnessesAvailable)
        }
    }

    /// A row whose Update button does what its title says. It waits only while everything it
    /// covers is already updating.
    private func updateRow(_ title: String, detail: String, request: UpdatesStore.Request, available: Bool,
                           accessibility: String? = nil) -> some View {
        let canStart = updates.canStart(request)
        let updating = updates.isUpdating(request)
        return SettingsRow(title: title, detail: detail) {
            if updating {
                ProgressView().controlSize(.small)
            } else if !available, updates.checkedAt != nil || updates.running {
                SettingsStatus("Up to date", tone: .good)
            }
            Button(updating ? "Updating…" : "Update") { updates.start(request) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!available || !canStart)
                .accessibilityLabel(accessibility ?? title)
        }
    }

    // MARK: Your devices

    /// This Mac, then other Macs, then Linux machines.
    private var deviceList: [Machine] {
        let others = model.machines.otherMachines.sorted { ($0.platform == .linux ? 1 : 0) < ($1.platform == .linux ? 1 : 0) }
        return (thisMac.map { [$0] } ?? []) + others
    }

    private var yourDevices: some View {
        SettingsSection(title: "Your devices") {
            ForEach(deviceList) { deviceRow($0) }
        }
    }

    private func hasBots(_ machine: Machine) -> Bool { model.bots.homeMachineID == machine.id }

    /// "Woven Matter 0.4.3 · Bots", the version it's on and whether its bots run there.
    private func deviceSummary(_ machine: Machine) -> String {
        let product = machine.isThisMachine ? thisMacProduct
            : (machine.platform == .linux ? "Woven server" : "Woven Matter") + (machine.appVersion.map { " " + $0 } ?? "")
        return [product, hasBots(machine) ? "Bots" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// A device's name and version. Opening it shows its Update buttons.
    private func deviceRow(_ machine: Machine) -> some View {
        let state = updates.state(of: machine.id)
        let offline = !machine.isOnline
        return SettingsDisclosureRow(machine.name, detail: deviceSummary(machine)) {
            if state.isUpdating {
                ProgressView().controlSize(.small)
                SettingsStatus("Updating", tone: .neutral)
            } else if offline {
                SettingsStatus("Offline", tone: .neutral)
            } else if state.hasUpdate {
                SettingsStatus("Update available", tone: .warning)
            } else {
                SettingsStatus("Up to date", tone: .good)
            }
        } content: {
            updateRow("Update everything on this device", detail: everythingDetail(machine),
                      request: .machine(machine.id), available: !offline && state.hasUpdate,
                      accessibility: "Update everything on \(machine.name)")
            appRow(machine, state)
            if hasBots(machine) { bots(machine, state) }
            harnessRows(machine, state)
        }
    }

    private func everythingDetail(_ machine: Machine) -> String {
        let product = machine.platform == .linux ? "the Woven server" : "Woven Matter"
        return hasBots(machine) ? "Updates \(product), the bots, and every harness on this device."
            : "Updates \(product) and every harness on this device."
    }

    /// A device's Woven Matter or Woven server, alone.
    private func appRow(_ machine: Machine, _ state: UpdatesStore.MachineState) -> some View {
        let linux = machine.platform == .linux
        let outdated = state.appUpdateAvailable
        let request = UpdatesStore.Request.app(machineID: machine.id)
        let detail = machine.isThisMachine ? Self.thisMacAbout
            : linux && outdated && state.appWaitsForThisMac ? "Update this Mac first. Its Woven Matter brings this server's update."
            : linux ? "This updates the Woven server on this device."
            : "This updates the Woven Matter desktop app on this device."
        return SettingsRow(title: "Update just Woven Matter", detail: detail) {
            if state.updatingApp { ProgressView().controlSize(.small) }
            else if !machine.isOnline { SettingsStatus("Offline", tone: .neutral) }
            else if outdated { SettingsStatus("Update available", tone: .warning) }
            else if !machine.isThisMachine || updates.checkedAt != nil { SettingsStatus("Up to date", tone: .good) }
            Button(state.updatingApp ? "Updating…" : "Update") { updates.start(request) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!outdated || state.appWaitsForThisMac || !updates.canStart(request))
                .accessibilityLabel("Update just Woven Matter on \(machine.isThisMachine ? "this Mac" : machine.name)")
        }
    }

    private func bots(_ machine: Machine, _ state: UpdatesStore.MachineState) -> some View {
        let outdated = state.botsOutdated
        let updating = state.updatingBots || model.bots.updating
        let behind = state.botsToUpdate
        let request = UpdatesStore.Request.bots(machineID: machine.id)
        let detail = behind == 0 ? "They keep their files and sign-ins."
            : behind == 1 ? "1 bot has newer tools waiting." : "\(behind) bots have newer tools waiting."
        return SettingsRow(title: "Update just the bots", detail: detail) {
            if updating { ProgressView().controlSize(.small) }
            else { SettingsStatus(outdated ? "Update available" : "Up to date", tone: outdated ? .warning : .good) }
            Button(updating ? "Updating…" : "Update") { updates.start(request) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!outdated || updating || model.bots.state != .ready || !updates.canStart(request))
                .accessibilityLabel("Update just the bots on \(machine.isThisMachine ? "this Mac" : machine.name)")
        }
    }

    // MARK: Harnesses

    /// Each harness on a device, with its versions and its own Update.
    @ViewBuilder private func harnessRows(_ machine: Machine, _ state: UpdatesStore.MachineState) -> some View {
        if let harnesses = state.harnesses {
            if harnesses.isEmpty { SettingsNote("No harnesses are installed here yet.") }
            ForEach(harnesses) { harness($0, on: machine) }
        } else if let error = state.harnessError {
            SettingsRow(title: "Harnesses", detail: error) { SettingsStatus("Unavailable", tone: .warning) }
        } else if machine.isOnline {
            SettingsRow(title: "Harnesses") {
                ProgressView().controlSize(.small)
                SettingsStatus("Checking", tone: .neutral)
            }
        }
    }

    private func harness(_ harness: UpdatesStore.Harness, on machine: Machine) -> some View {
        let request = UpdatesStore.Request.harness(machineID: machine.id, harnessID: harness.id)
        let active = harness.updating || updates.isUpdating(request)
        return VStack(alignment: .leading, spacing: 4) {
            SettingsRow(title: harness.name, detail: harness.versions) {
                if active || harness.checking { ProgressView().controlSize(.small) }
                SettingsStatus(active ? "Updating" : harness.checking ? "Checking"
                               : harness.updateAvailable ? "Update available" : "Up to date",
                               tone: active || harness.checking ? .neutral : harness.updateAvailable ? .warning : .good)
                if harness.updateAvailable {
                    Button("Update") { updates.start(request) }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(active || !updates.canStart(request))
                        .accessibilityLabel("Update \(harness.name) on \(machine.isThisMachine ? "this Mac" : machine.name)")
                }
            }
            if let error = harness.error { SettingsError(error) }
        }
    }

    // MARK: Dialogs

    private var busyTitle: String { "Before you update" }
}

/// Elsewhere in Settings, mismatched versions are one line that opens Settings → Updates.
struct UpdatesStatusLink: View {
    @Bindable var updates: UpdatesStore
    let onOpen: () -> Void

    var body: some View {
        if updates.versionsDiffer || updates.running {
            SettingsSection {
                SettingsSummaryLink(
                    title: "Versions don't match",
                    value: updates.running ? "Updating…" : "Open Updates",
                    tone: .warning,
                    action: onOpen
                )
            }
        }
    }
}
