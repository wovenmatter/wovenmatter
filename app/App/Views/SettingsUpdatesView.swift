import SwiftUI

/// Settings → Updates: this Mac's version with Check for updates and Update this Mac, three
/// rows that update all your machines at once, then each machine, which opens to update
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
        SettingsPage(
            title: "Updates",
            detail: "Woven Matter and its harnesses on this Mac and your other machines.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            overview
            allMachines
            yourMachines
        }
        .task {
            updates.loadIfNeeded()
            await model.bots.refresh()
        }
    }

    // MARK: This Mac, then all your machines

    /// "Woven Matter 0.4.3".
    private var thisMacProduct: String {
        "Woven Matter \(thisMac?.appVersion ?? "")".trimmingCharacters(in: .whitespaces)
    }

    private static let thisMacAbout = "This updates the Woven Matter desktop app on this Mac."

    private var thisMacIsBehind: Bool { thisMacState.appUpdateAvailable }

    private var appsAvailable: Bool {
        model.machines.machines.contains { updates.state(of: $0.id).appUpdateAvailable }
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
            if updates.releaseError != nil {
                SettingsNote("The newest release couldn't be checked, so machines are compared with this Mac.")
            }
            ForEach(updates.failures, id: \.self) { SettingsError($0) }
        }
    }

    /// One kind of thing on every machine at once.
    private var allMachines: some View {
        SettingsSection {
            updateRow("Update everything", detail: "Update everything across all your machines.",
                      request: .everything, available: appsAvailable || harnessesAvailable)
            updateRow("Update just Woven Matter", detail: "Update just the Woven Matter apps across your machines.",
                      request: .apps, available: appsAvailable)
            updateRow("Update just the harnesses", detail: "Update just the harnesses across your machines.",
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

    // MARK: Your machines

    /// This Mac, then other Macs, then Linux machines.
    private var machineList: [Machine] {
        let others = model.machines.otherMachines.sorted { ($0.platform == .linux ? 1 : 0) < ($1.platform == .linux ? 1 : 0) }
        return (thisMac.map { [$0] } ?? []) + others
    }

    private var yourMachines: some View {
        SettingsSection(title: "Your machines") {
            ForEach(machineList) { machineRow($0) }
        }
    }

    private func hasBots(_ machine: Machine) -> Bool { model.bots.hostMachineID == machine.id }

    /// "Woven Matter 0.4.3 · Bots", the version it's on and whether its bots run there.
    private func machineSummary(_ machine: Machine) -> String {
        let product = machine.isThisMachine ? thisMacProduct
            : (machine.platform == .linux ? "Woven server" : "Woven Matter") + (machine.appVersion.map { " " + $0 } ?? "")
        return [product, hasBots(machine) ? "Bots" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// A machine's name and version. Opening it shows its Update buttons.
    private func machineRow(_ machine: Machine) -> some View {
        let state = updates.state(of: machine.id)
        let offline = !machine.isOnline
        return SettingsDisclosureRow(machine.name, detail: machineSummary(machine)) {
            if state.isUpdating {
                ProgressView().controlSize(.small)
                SettingsStatus("Updating", tone: .neutral)
            } else if offline {
                SettingsStatus(machine.connection.displayName, tone: .neutral)
            } else if !machine.syncs {
                SettingsStatus("Can't sync right now", tone: .warning)
            } else if state.hasUpdate {
                SettingsStatus("Update available", tone: .warning)
            } else {
                SettingsStatus("Up to date", tone: .good)
            }
        } content: {
            if !offline && !machine.syncs {
                SettingsNote("It runs another release, with a different library. Update the machine that's behind and they sync again.")
            }
            updateRow("Update everything on this machine", detail: everythingDetail(machine),
                      request: .machine(machine.id), available: !offline && state.hasUpdate,
                      accessibility: "Update everything on \(machine.name)")
            appRow(machine, state)
            harnessRows(machine, state)
        }
    }

    private func everythingDetail(_ machine: Machine) -> String {
        let product = machine.platform == .linux ? "the Woven server" : "Woven Matter"
        return "Updates \(product) and every harness on this machine."
    }

    /// One machine's Woven Matter, or a Linux machine's Woven server, alone.
    private func appRow(_ machine: Machine, _ state: UpdatesStore.MachineState) -> some View {
        let outdated = state.appUpdateAvailable
        let request = UpdatesStore.Request.app(machineID: machine.id)
        let detail = machine.isThisMachine ? Self.thisMacAbout
            : machine.platform == .mac ? "This updates Woven Matter on that Mac. It installs and relaunches there, with nothing to click."
            : outdated && state.appWaitsForThisMac ? "Update this Mac first. Its Woven Matter brings this server's update."
            : "This updates the Woven server on this machine."
        return SettingsRow(title: "Update just Woven Matter", detail: detail) {
            if state.updatingApp { ProgressView().controlSize(.small) }
            else if !machine.isOnline { SettingsStatus(machine.connection.displayName, tone: .neutral) }
            else if outdated { SettingsStatus("Update available", tone: .warning) }
            else if !machine.isThisMachine || updates.checkedAt != nil { SettingsStatus("Up to date", tone: .good) }
            Button(state.updatingApp ? "Updating…" : "Update") { updates.start(request) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!outdated || state.appWaitsForThisMac || !updates.canStart(request))
                .accessibilityLabel("Update just Woven Matter on \(machine.isThisMachine ? "this Mac" : machine.name)")
        }
    }

    // MARK: Harnesses

    /// Each harness on a machine, with its versions and its own Update.
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
}

/// Elsewhere in Settings, a machine that can't sync is one line that opens Settings → Updates.
struct UpdatesStatusLink: View {
    @Bindable var updates: UpdatesStore
    let onOpen: () -> Void

    var body: some View {
        if updates.cannotSync || updates.running {
            SettingsSection {
                SettingsSummaryLink(
                    title: "Can't sync right now",
                    value: updates.running ? "Updating…" : "Open Updates",
                    tone: .warning,
                    action: onOpen
                )
            }
        }
    }
}
