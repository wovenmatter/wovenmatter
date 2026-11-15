import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Settings → Updates: this Mac's version with Check for updates and Update this Mac, every
/// other device's version, rows that update all your devices at once, then one section per
/// device (This Mac first) with its app or server, bots, and harnesses, each updatable alone.
struct SettingsUpdatesView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    @State private var updates = FleetUpdatesModel.shared
    /// The app's own resources don't change while it runs.
    private static let bundled = BundledComponents.onThisMac()
    private static let linuxServerTools = BundledComponents.linuxServer()

    var body: some View {
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
            SettingsHelp {
                SettingsNote("Update this Mac updates only the Woven Matter app on this Mac. Updating everything across all your devices updates Woven Matter on every device first, then every harness.")
                SettingsNote("Linux servers get the server release that comes with this Mac's Woven Matter. When this Mac is behind the newest release, it updates first and restarts, then the update continues with your other devices and harnesses.")
                SettingsNote("Before a Linux workspace runs a harness installer, you review its download. One review covers every download in the update.")
                SettingsNote("Updating bots brings the Node, Playwright, Chromium and Ubuntu packages inside them up to date. Each bot keeps its files, home folder, browser sign-ins and what it installed, and is snapshotted first and rolled back if the update fails.")
                SettingsNote("If an update would stop chats that are running, or replace bot containers, you're asked first.")
                SettingsNote("iPhone and iPad update through TestFlight.")
            }
        }
        .task {
            updates.loadIfNeeded()
            await model.bots.refresh()
        }
        .alert(busyTitle, isPresented: Binding(
            get: { updates.busyConfirmation != nil }, set: { if !$0 { updates.busyConfirmation = nil } }
        ), presenting: updates.busyConfirmation) { _ in
            Button("Update now", role: .destructive) { updates.confirmBusy() }
            Button("Cancel", role: .cancel) { updates.busyConfirmation = nil }
        } message: { confirmation in
            Text(confirmation.items.map(\.text).joined(separator: "\n\n"))
        }
        .confirmationDialog(reviewTitle, isPresented: Binding(
            get: { updates.review != nil }, set: { if !$0 { updates.cancelReview() } }
        ), titleVisibility: .visible, presenting: updates.review) { _ in
            Button("Update") { updates.confirmReview() }
            Button("Cancel", role: .cancel) { updates.cancelReview() }
        } message: { review in
            Text(review.items.map(Self.describe).joined(separator: "\n\n")
                 + "\n\nEach host downloads its source again and refuses to run it if it changed.")
        }
    }

    // MARK: This Mac, then all your devices

    /// "Woven Matter 0.4.3", or "Development build".
    private var thisMacProduct: String {
        updates.isDevelopmentBuild ? "Development build" : "Woven Matter \(updates.thisMacVersion ?? "")".trimmingCharacters(in: .whitespaces)
    }

    private var thisMacDetail: String {
        if updates.isDevelopmentBuild { return "Development builds don't update here." }
        if updates.thisMacIsBehind, let latest = updates.release?.version {
            return "\(latest) is available. Updates just the Woven Matter app on this Mac."
        }
        if updates.checking { return "Checking for updates…" }
        if let checked = updates.checkedAt { return "Up to date. Checked \(checked.formatted(.relative(presentation: .named)))." }
        return "Updates just the Woven Matter app on this Mac."
    }

    private var appsAvailable: Bool {
        updates.thisMacIsBehind || updates.devices.contains { updates.canUpdate($0) || (updates.hasBots($0) && updates.botsAreOutdated($0)) }
            || model.bots.thisMachine.map { updates.hasBots($0) && updates.botsAreOutdated($0) } == true
    }

    private var harnessesAvailable: Bool { updates.allHarnesses.contains(where: \.updateAvailable) }

    /// This Mac's version, Check for updates and, when a release is newer, the page's one
    /// primary button: Update this Mac (only its Woven Matter app).
    private var overview: some View {
        SettingsSection {
            SettingsRow(title: "This Mac · " + thisMacProduct, detail: thisMacDetail) {
                if updates.checking { ProgressView().controlSize(.small) }
                Button(updates.checking ? "Checking…" : "Check for updates") { Task { await updates.checkAll() } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(updates.checking || updates.running)
                if updates.thisMacIsBehind {
                    Button("Update this Mac") { updates.start(.thisMacApp) }
                        .buttonStyle(WovenPrimaryButtonStyle())
                        .disabled(updates.running)
                }
            }
            if let current = updates.current {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    SettingsNote(current)
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
            allDevicesRow("Update everything across all of your devices", available: appsAvailable || harnessesAvailable) {
                updates.start(.scope(.everything))
            }
            allDevicesRow("Update just the Woven Matter apps across your devices", available: appsAvailable) {
                updates.start(.scope(.apps))
            }
            allDevicesRow("Update just the harnesses across your devices", available: harnessesAvailable) {
                updates.start(.scope(.harnesses))
            }
        }
    }

    private func allDevicesRow(_ title: String, available: Bool, action: @escaping () -> Void) -> some View {
        SettingsRow(title: title) {
            if !available, updates.checkedAt != nil { SettingsStatus("Up to date", tone: .good) }
            Button(updates.running ? "Updating…" : "Update", action: action)
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!available || updates.running || updates.review != nil)
                .accessibilityLabel(title)
        }
    }

    // MARK: Your devices

    /// This Mac, then other Macs, then remote workspaces (Linux machines).
    private var deviceList: [BotMachine] {
        let others = updates.devices.sorted { ($0.kind == .linux ? 1 : 0) < ($1.kind == .linux ? 1 : 0) }
        return (model.bots.thisMachine.map { [$0] } ?? []) + others
    }

    private var yourDevices: some View {
        SettingsSection(title: "Your devices", detail: "Update on a device updates everything on it. Open a device to update one part.") {
            if model.bots.thisMachine == nil { thisMacOnly }
            ForEach(deviceList) { deviceRow($0) }
        }
    }

    /// Before the bots host has reported this Mac: its app and harnesses still show.
    private var thisMacOnly: some View {
        SettingsDisclosureRow(updates.thisMacName, detail: "This Mac · " + thisMacProduct) {
            if updates.thisMacIsBehind || updates.harnesses(on: .thisMac).contains(where: \.updateAvailable) {
                SettingsStatus("Update available", tone: .warning)
            }
        } content: {
            thisMacAppRow
            harnessRows(.thisMac)
            includedRow
        }
    }

    private func deviceSummary(_ machine: BotMachine) -> String {
        let kind = machine.kind == .thisMac ? "This Mac" : machine.kind == .linux ? "Remote workspace" : "Mac"
        let product = machine.kind == .thisMac ? thisMacProduct
            : (machine.kind == .linux ? "Woven server" : "Woven Matter") + (machine.versions.app.map { " " + $0 } ?? "")
        return [kind, product, updates.hasBots(machine) ? "Bots" : nil,
                machine.state == .unreachable ? "Offline" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func deviceRow(_ machine: BotMachine) -> some View {
        let name = machine.kind == .thisMac ? updates.thisMacName : machine.name
        let hasUpdate = machine.state != .unreachable && updates.machineHasUpdate(machine)
        return SettingsDisclosureRow(name, detail: deviceSummary(machine)) {
            if updates.running && updates.currentItem == machine.id { ProgressView().controlSize(.small) }
            if machine.state == .unreachable {
                SettingsStatus("Offline", tone: .neutral)
            } else if hasUpdate {
                SettingsStatus("Update available", tone: .warning)
                Button("Update") { updates.start(.machine(machineID: machine.id)) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(updates.running)
                    .accessibilityLabel("Update everything on \(name)")
            } else {
                SettingsStatus("Up to date", tone: .good)
            }
        } content: {
            if machine.kind == .thisMac { thisMacAppRow } else { appRow(machine) }
            if updates.hasBots(machine) { bots(machine) }
            if machine.kind == .linux, let tools = Self.linuxServerTools {
                SettingsNote((updates.deviceIsOutdated(machine) ? "Updating the server brings " : "With the server: ") + tools + ".")
            }
            if machine.kind == .thisMac {
                harnessRows(.thisMac)
                includedRow
            } else if let workspace = updates.workspace(for: machine) {
                harnessRows(.workspace(workspace.id))
            } else {
                memberHarnesses(machine)
            }
        }
    }

    private var thisMacAppRow: some View {
        SettingsRow(title: thisMacProduct, detail: updates.isDevelopmentBuild ? "Development builds don't update here."
                    : "Updates just the Woven Matter app on this Mac.") {
            if updates.thisMacIsBehind {
                SettingsStatus("Update available", tone: .warning)
                Button("Update") { updates.start(.thisMacApp) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(updates.running)
                    .accessibilityLabel("Update Woven Matter on this Mac")
            } else if updates.release != nil, !updates.isDevelopmentBuild {
                SettingsStatus("Up to date", tone: .good)
            }
        }
    }

    private var includedRow: some View {
        Group {
            if !Self.bundled.isEmpty {
                SettingsSummaryRow("Included with Woven Matter", detail: "Ships inside the app and updates with it.") {
                    ForEach(Self.bundled) { SettingsValueRow(label: $0.name, value: $0.version) }
                }
            }
        }
    }

    /// Another device's Woven Matter or Woven server, alone.
    private func appRow(_ machine: BotMachine) -> some View {
        let product = machine.kind == .linux ? "Woven server" : "Woven Matter"
        let version = machine.versions.app ?? (machine.kind == .linux ? "an older release" : "unknown version")
        let about = machine.kind == .linux ? "Updates just the Woven server on \(machine.name)." : "Updates just the Woven Matter app on \(machine.name)."
        let detail = machine.kind == .linux && updates.deviceIsOutdated(machine) && !updates.canUpdate(machine)
            ? "Update this Mac first. Its Woven Matter brings this server's update." : about
        return SettingsRow(title: "\(product) \(version)", detail: detail) {
            if machine.state == .unreachable {
                SettingsStatus("Offline", tone: .neutral)
            } else if updates.deviceIsOutdated(machine) {
                SettingsStatus("Update available", tone: .warning)
                if updates.canUpdate(machine) {
                    Button("Update") { updates.start(.device(machineID: machine.id)) }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(updates.running)
                        .accessibilityLabel("Update \(product) on \(machine.name)")
                }
            } else {
                SettingsStatus("Up to date", tone: .good)
            }
        }
    }

    private func bots(_ machine: BotMachine) -> some View {
        let outdated = updates.botsAreOutdated(machine)
        let busy = updates.running && updates.currentItem == machine.id
        let session = model.bots.session(for: machine.id)
        let behind = updates.botsToUpdate(machine)
        let tools = session?.runtimeStatus?.image?.tools
        let waiting = behind == 0 ? nil : behind == 1 ? "1 bot has newer tools waiting." : "\(behind) bots have newer tools waiting."
        let detail = [tools, waiting ?? "Updates just the bots here. They keep their files and sign-ins."]
            .compactMap { $0 }.joined(separator: " · ")
        return SettingsRow(title: "Bots", detail: detail) {
            if busy || machine.updating { ProgressView().controlSize(.small) }
            SettingsStatus(outdated ? "Update available" : "Up to date", tone: outdated ? .warning : .good)
            if outdated {
                Button("Update") { updates.start(.bots(machineID: machine.id)) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(updates.running || machine.updating || machine.state != .ready)
                    .accessibilityLabel("Update just the bots on \(machine.kind == .thisMac ? "this Mac" : machine.name)")
            }
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
        let active = harness.updating || (updates.running && updates.currentItem == harness.id)
        return VStack(alignment: .leading, spacing: 4) {
            SettingsRow(title: harness.name, detail: harness.versions) {
                if active || harness.checking { ProgressView().controlSize(.small) }
                SettingsStatus(active ? "Updating" : harness.checking ? "Checking"
                               : harness.updateAvailable ? "Update available" : "Up to date",
                               tone: harness.updateAvailable ? .warning : active || harness.checking ? .neutral : .good)
                if harness.updateAvailable {
                    Button("Update") { updates.start(.harness(id: harness.id)) }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(updates.running || active)
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
