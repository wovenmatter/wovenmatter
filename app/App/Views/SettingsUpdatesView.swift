import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Settings → Updates: this Mac's version with Check for updates and Update this Mac, three
/// rows that update all your devices at once, then each device, which opens to update
/// everything on it or one part. Updates run side by side; only the rows an update covers wait.
struct SettingsUpdatesView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    @State private var updates = FleetUpdatesModel.shared

    var body: some View {
        let shownBusy = updates.busyConfirmation?.id
        let shownReview = updates.review?.id
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
            get: { updates.busyConfirmation != nil }, set: { if !$0 { updates.cancelBusy(shownBusy) } }
        ), presenting: updates.busyConfirmation) { confirmation in
            Button("Update now", role: .destructive) { updates.confirmBusy() }
            Button("Cancel", role: .cancel) { updates.cancelBusy(confirmation.id) }
        } message: { confirmation in
            Text(confirmation.items.map(\.text).joined(separator: "\n\n"))
        }
        .confirmationDialog(reviewTitle, isPresented: Binding(
            get: { updates.review != nil }, set: { if !$0 { updates.cancelReview(shownReview) } }
        ), titleVisibility: .visible, presenting: updates.review) { review in
            Button("Update") { updates.confirmReview() }
            Button("Cancel", role: .cancel) { updates.cancelReview(review.id) }
        } message: { review in
            Text(review.items.map(Self.describe).joined(separator: "\n\n")
                 + "\n\nEach host downloads its source again and refuses to run it if it changed.")
        }
    }

    // MARK: This Mac, then all your devices

    /// "Woven Matter 0.4.3", or "Woven Matter development build".
    private var thisMacProduct: String {
        updates.isDevelopmentBuild ? "Woven Matter development build"
            : "Woven Matter \(updates.thisMacVersion ?? "")".trimmingCharacters(in: .whitespaces)
    }

    private static let thisMacAbout = "This updates the Woven Matter desktop app on this Mac."

    private var appsAvailable: Bool {
        updates.thisMacIsBehind || updates.devices.contains { updates.canUpdate($0) || (updates.hasBots($0) && updates.botsAreOutdated($0)) }
            || model.bots.thisMachine.map { updates.hasBots($0) && updates.botsAreOutdated($0) } == true
    }

    private var harnessesAvailable: Bool { updates.allHarnesses.contains(where: \.updateAvailable) }

    /// This Mac's version, Check for updates and, when a release is newer, the page's one
    /// primary button: Update this Mac (only its Woven Matter app).
    private var overview: some View {
        SettingsSection {
            SettingsRow(title: "This Mac · " + thisMacProduct, detail: Self.thisMacAbout) {
                if updates.checking { ProgressView().controlSize(.small) }
                else if updates.isUpdatingThisMacApp { ProgressView().controlSize(.small) }
                else if updates.thisMacIsBehind, let latest = updates.release?.version {
                    SettingsStatus("\(latest) available", tone: .warning)
                } else if updates.checkedAt != nil, !updates.isDevelopmentBuild {
                    SettingsStatus("Up to date", tone: .good)
                }
                Button(updates.checking ? "Checking…" : "Check for updates") { Task { await updates.checkAll() } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    // A check mid-update would report versions that are about to change.
                    .disabled(updates.checking || updates.running)
                if updates.thisMacIsBehind {
                    Button("Update this Mac") { updates.start(.thisMacApp) }
                        .buttonStyle(WovenPrimaryButtonStyle())
                        .disabled(!updates.canStart(.thisMacApp))
                }
            }
            ForEach(updates.progress, id: \.self) { line in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    SettingsNote(line)
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
                      request: .scope(.everything), available: appsAvailable || harnessesAvailable)
            updateRow("Update just Woven Matter", detail: "Update just the Woven Matter apps across your devices.",
                      request: .scope(.apps), available: appsAvailable)
            updateRow("Update just the harnesses", detail: "Update just the harnesses across your devices.",
                      request: .scope(.harnesses), available: harnessesAvailable)
        }
    }

    /// A row whose Update button does what its title says. It waits only while everything it
    /// covers is already updating.
    private func updateRow(_ title: String, detail: String, request: FleetUpdatesModel.Request, available: Bool,
                           accessibility: String? = nil) -> some View {
        let canStart = updates.canStart(request)
        let updating = available && !canStart && updates.running
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

    /// This Mac, then other Macs, then remote workspaces (Linux machines).
    private var deviceList: [BotMachine] {
        let others = updates.devices.sorted { ($0.kind == .linux ? 1 : 0) < ($1.kind == .linux ? 1 : 0) }
        return (model.bots.thisMachine.map { [$0] } ?? []) + others
    }

    private var yourDevices: some View {
        SettingsSection(title: "Your devices") {
            if model.bots.thisMachine == nil { thisMacOnly }
            ForEach(deviceList) { deviceRow($0) }
        }
    }

    /// Before the bots host has reported this Mac: its app and harnesses still show.
    private var thisMacOnly: some View {
        let available = updates.thisMacIsBehind || updates.harnesses(on: .thisMac).contains(where: \.updateAvailable)
        return SettingsDisclosureRow(updates.thisMacName, detail: thisMacProduct) {
            if available { SettingsStatus("Update available", tone: .warning) }
        } content: {
            thisMacAppRow
            harnessRows(.thisMac)
        }
    }

    /// "Woven Matter 0.4.3 · Bots", the version it's on and whether its bots run there.
    private func deviceSummary(_ machine: BotMachine) -> String {
        let product = machine.kind == .thisMac ? thisMacProduct
            : (machine.kind == .linux ? "Woven server" : "Woven Matter") + (machine.versions.app.map { " " + $0 } ?? "")
        return [product, updates.hasBots(machine) ? "Bots" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// A device's name and version. Opening it shows its Update buttons.
    private func deviceRow(_ machine: BotMachine) -> some View {
        let name = machine.kind == .thisMac ? updates.thisMacName : machine.name
        let offline = machine.state == .unreachable
        return SettingsDisclosureRow(name, detail: deviceSummary(machine)) {
            if updates.isUpdatingAnything(on: machine) {
                ProgressView().controlSize(.small)
                SettingsStatus("Updating", tone: .neutral)
            } else if offline {
                SettingsStatus("Offline", tone: .neutral)
            } else if updates.machineHasUpdate(machine) {
                SettingsStatus("Update available", tone: .warning)
            } else {
                SettingsStatus("Up to date", tone: .good)
            }
        } content: {
            updateRow("Update everything on this device", detail: everythingDetail(machine),
                      request: .machine(machineID: machine.id), available: !offline && updates.machineHasUpdate(machine),
                      accessibility: "Update everything on \(name)")
            if machine.kind == .thisMac { thisMacAppRow } else { appRow(machine) }
            if updates.hasBots(machine) { bots(machine) }
            if machine.kind == .thisMac {
                harnessRows(.thisMac)
            } else if let workspace = updates.workspace(for: machine) {
                harnessRows(.workspace(workspace.id))
            } else {
                memberHarnesses(machine)
            }
        }
    }

    private func everythingDetail(_ machine: BotMachine) -> String {
        let product = machine.kind == .linux ? "the Woven server" : "Woven Matter"
        return updates.hasBots(machine) ? "Updates \(product), the bots, and every harness on this device."
            : "Updates \(product) and every harness on this device."
    }

    private var thisMacAppRow: some View {
        SettingsRow(title: "Update just Woven Matter", detail: Self.thisMacAbout) {
            let updating = updates.isUpdatingThisMacApp
            if updating { ProgressView().controlSize(.small) }
            else if updates.thisMacIsBehind { SettingsStatus("Update available", tone: .warning) }
            else if updates.checkedAt != nil, !updates.isDevelopmentBuild { SettingsStatus("Up to date", tone: .good) }
            Button(updating ? "Updating…" : "Update") { updates.start(.thisMacApp) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!updates.thisMacIsBehind || !updates.canStart(.thisMacApp))
                .accessibilityLabel("Update just Woven Matter on this Mac")
        }
    }

    /// Another device's Woven Matter or Woven server, alone.
    private func appRow(_ machine: BotMachine) -> some View {
        let linux = machine.kind == .linux
        let outdated = updates.deviceIsOutdated(machine)
        let updating = updates.isUpdatingApp(machine)
        let detail = linux && outdated && !updates.canUpdate(machine)
            ? "Update this Mac first. Its Woven Matter brings this server's update."
            : linux ? "This updates the Woven server on this device."
            : "This updates the Woven Matter desktop app on this device."
        return SettingsRow(title: "Update just Woven Matter", detail: detail) {
            if updating { ProgressView().controlSize(.small) }
            else if machine.state == .unreachable { SettingsStatus("Offline", tone: .neutral) }
            else if outdated { SettingsStatus("Update available", tone: .warning) }
            else { SettingsStatus("Up to date", tone: .good) }
            Button(updating ? "Updating…" : "Update") { updates.start(.device(machineID: machine.id)) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!outdated || !updates.canUpdate(machine) || !updates.canStart(.device(machineID: machine.id)))
                .accessibilityLabel("Update just Woven Matter on \(machine.name)")
        }
    }

    private func bots(_ machine: BotMachine) -> some View {
        let outdated = updates.botsAreOutdated(machine)
        let updating = updates.isUpdatingBots(machine) || machine.updating
        let behind = updates.botsToUpdate(machine)
        let tools = model.bots.session(for: machine.id)?.runtimeStatus?.image?.tools
        let waiting = behind == 0 ? nil : behind == 1 ? "1 bot has newer tools waiting." : "\(behind) bots have newer tools waiting."
        let detail = [tools, waiting ?? "They keep their files and sign-ins."].compactMap { $0 }.joined(separator: " · ")
        return SettingsRow(title: "Update just the bots", detail: detail) {
            if updating { ProgressView().controlSize(.small) }
            else { SettingsStatus(outdated ? "Update available" : "Up to date", tone: outdated ? .warning : .good) }
            Button(updating ? "Updating…" : "Update") { updates.start(.bots(machineID: machine.id)) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!outdated || updating || machine.state != .ready || !updates.canStart(.bots(machineID: machine.id)))
                .accessibilityLabel("Update just the bots on \(machine.kind == .thisMac ? "this Mac" : machine.name)")
        }
    }

    // MARK: Harnesses

    /// Another machine's harnesses, as it reports them.
    @ViewBuilder private func memberHarnesses(_ machine: BotMachine) -> some View {
        let id = machine.id.lowercased()
        if let inventory = updates.memberInventories[id], inventory.unsupported {
            SettingsNote("Update its Woven Matter to see and update its harnesses here.")
        } else if updates.memberInventories[id] == nil, let error = updates.memberErrors[id] {
            SettingsRow(title: "Harnesses", detail: error) { SettingsStatus("Unavailable", tone: .warning) }
        } else if updates.memberInventories[id] == nil {
            SettingsRow(title: "Harnesses") {
                ProgressView().controlSize(.small)
                SettingsStatus("Checking", tone: .neutral)
            }
        } else {
            harnessRows(.member(machine.id))
        }
    }

    /// Each harness on a device, with its versions and its own Update.
    @ViewBuilder private func harnessRows(_ location: FleetHarness.Location) -> some View {
        let rows = updates.harnesses(on: location)
        if rows.isEmpty { SettingsNote("No harnesses are installed here yet.") }
        ForEach(rows) { harness($0) }
    }

    private func harness(_ harness: FleetHarness) -> some View {
        let active = harness.updating || updates.isUpdatingHarness(harness)
        return VStack(alignment: .leading, spacing: 4) {
            SettingsRow(title: harness.name, detail: harness.versions) {
                if active || harness.checking { ProgressView().controlSize(.small) }
                SettingsStatus(active ? "Updating" : harness.checking ? "Checking"
                               : harness.updateAvailable ? "Update available" : "Up to date",
                               tone: active || harness.checking ? .neutral : harness.updateAvailable ? .warning : .good)
                if harness.updateAvailable {
                    Button("Update") { updates.start(.harness(id: harness.id)) }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(active || !updates.canStart(.harness(id: harness.id)))
                        .accessibilityLabel("Update \(harness.name)")
                }
            }
            if let error = harness.error { SettingsError(error) }
        }
    }

    // MARK: Dialogs

    private var busyTitle: String { "Before you update" }

    private var reviewTitle: String {
        let count = updates.review?.items.count ?? 0
        return count == 1 ? "Review this download?" : "Review \(count) downloads?"
    }

    private static func describe(_ item: FleetUpdatesModel.DownloadReview.Item) -> String {
        var lines = [item.title, "Source: \(item.preview.source)"]
        if let sha256 = item.preview.sha256 { lines.append("SHA-256: \(sha256)") }
        else if let package = item.preview.packageSpec { lines.append("Package: \(package)") }
        else { lines.append("Command: \(item.preview.command)") }
        return lines.joined(separator: "\n")
    }
}

/// Elsewhere in Settings, mismatched versions are one line that opens Settings → Updates.
struct UpdatesStatusLink: View {
    @Bindable var bots: BotsModel
    let onOpen: () -> Void
    @State private var updates = FleetUpdatesModel.shared

    var body: some View {
        if bots.versionReport.needsUpdate || updates.running {
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
