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
            thisMac
            ForEach(updates.devices) { device($0) }
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

    /// What the top row's buttons do, and where things stand.
    private var thisMacDetail: String {
        if updates.isDevelopmentBuild {
            return "A development build can't update itself. Check for updates still checks your other devices and harnesses."
        }
        if updates.thisMacIsBehind, let latest = updates.release?.version {
            return "Woven Matter \(latest) is available. Update this Mac installs it on this Mac only, then restarts Woven Matter."
        }
        if updates.checking { return "Checking for a newer Woven Matter and newer harnesses…" }
        if let checked = updates.checkedAt {
            return "Up to date. Checked \(checked.formatted(.relative(presentation: .named)))."
        }
        return "Check for updates looks for a newer Woven Matter and newer harnesses on all your devices."
    }

    private var appsAvailable: Bool {
        updates.thisMacIsBehind || updates.devices.contains { updates.canUpdate($0) || updates.botsAreOutdated($0) }
            || model.bots.thisMachine.map(updates.botsAreOutdated) == true
    }

    private var harnessesAvailable: Bool { updates.allHarnesses.contains(where: \.updateAvailable) }

    /// "Mac mini 0.4.3 · Workstation 0.4.2 (update available) · box (offline)"
    private var otherDevices: String {
        updates.devices.map { machine in
            let version = machine.versions.app.map { " " + $0 } ?? ""
            if machine.state == .unreachable { return machine.name + version + " (offline)" }
            return machine.name + version + (updates.deviceIsOutdated(machine) ? " (update available)" : "")
        }.joined(separator: " · ")
    }

    /// This Mac's version with Check for updates and, when a release is newer, the page's one
    /// primary button: Update this Mac (only its Woven Matter app). Then every other device.
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
            if !updates.devices.isEmpty {
                SettingsRow(title: "Your other devices", detail: otherDevices) { EmptyView() }
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

    /// Update one kind of thing on every device at once.
    private var allDevices: some View {
        SettingsSection(title: "All your devices", detail: "Update one kind of thing on every device at once. Anything already up to date is skipped.") {
            allDevicesRow("Everything",
                          detail: "Woven Matter, bots, and harnesses across all your devices. Devices update first, then harnesses.",
                          available: appsAvailable || harnessesAvailable, accessibility: "Update everything across all your devices") {
                updates.start(.scope(.everything))
            }
            allDevicesRow("Woven Matter",
                          detail: "The app on each Mac and the server on each Linux machine, with their bots. If this Mac is behind, it updates first.",
                          available: appsAvailable, accessibility: "Update Woven Matter across all your devices") {
                updates.start(.scope(.apps))
            }
            allDevicesRow("Harnesses",
                          detail: "Codex, Claude Code, Grok Build, OpenCode, the Pi Durable SDK, and Executor across all your devices.",
                          available: harnessesAvailable, accessibility: "Update harnesses across all your devices") {
                updates.start(.scope(.harnesses))
            }
        }
    }

    private func allDevicesRow(_ title: String, detail: String, available: Bool, accessibility: String,
                               action: @escaping () -> Void) -> some View {
        SettingsRow(title: title, detail: detail) {
            if updates.checkedAt != nil || available {
                SettingsStatus(available ? "Update available" : "Up to date", tone: available ? .warning : .good)
            }
            Button(updates.running ? "Updating…" : "Update", action: action)
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(!available || updates.running || updates.review != nil)
                .accessibilityLabel(accessibility)
        }
    }

    // MARK: Devices

    private var thisMac: some View {
        let latest = updates.release?.version
        let detail = updates.isDevelopmentBuild ? "A development build doesn't update itself. Everything under Included with Woven Matter comes with it."
            : updates.thisMacIsBehind ? latest.map { "\($0) is available. Update installs it on this Mac and restarts Woven Matter." }
            : "The app on this Mac. Everything under Included with Woven Matter updates with it."
        return SettingsSection(title: "This Mac", detail: "Woven Matter on this Mac, its bots, and the harnesses installed here.") {
            SettingsRow(title: thisMacProduct, detail: detail) {
                if updates.thisMacIsBehind {
                    SettingsStatus("Update available", tone: .warning)
                    Button("Update") { updates.start(.thisMacApp) }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(updates.running)
                } else if latest != nil, !updates.isDevelopmentBuild {
                    SettingsStatus("Up to date", tone: .good)
                }
            }
            // A machine runs bots when its bots runtime answers (its version is never shown).
            if let machine = model.bots.thisMachine, machine.versions.runtime != nil { bots(machine) }
            harnesses(on: .thisMac)
            if !Self.bundled.isEmpty {
                SettingsSummaryRow("Included with Woven Matter", detail: "Ships inside the app and updates with it.", value: nil) {
                    ForEach(Self.bundled) { SettingsValueRow(label: $0.name, value: $0.version) }
                }
            }
        }
    }

    private func device(_ machine: BotMachine) -> some View {
        let system = machine.kind == .linux ? "Linux" : "Mac"
        let product = machine.kind == .linux ? "Woven server" : "Woven Matter"
        let version = machine.versions.app ?? (machine.kind == .linux ? "an older release" : "unknown version")
        let about = machine.kind == .linux ? "The Woven server on this Linux machine, its bots, and its harnesses."
            : "Woven Matter on this Mac, its bots, and the harnesses installed there."
        return SettingsSection(title: machine.name, detail: about) {
            if machine.state == .unreachable {
                SettingsRow(title: "\(product) \(machine.versions.app ?? "")".trimmingCharacters(in: .whitespaces),
                            detail: system + " · " + (machine.message ?? "Not reachable right now.") + " It shows the last version it reported.") {
                    SettingsStatus("Offline", tone: .neutral)
                }
            } else {
                SettingsRow(title: "\(product) \(version)", detail: deviceDetail(machine, system: system)) {
                    if updates.running && updates.currentItem == machine.id { ProgressView().controlSize(.small) }
                    if updates.deviceIsOutdated(machine) {
                        SettingsStatus("Update available", tone: .warning)
                        if updates.canUpdate(machine) {
                            Button("Update") { updates.start(.device(machineID: machine.id)) }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .disabled(updates.running)
                                .accessibilityLabel("Update \(machine.name)")
                        }
                    } else {
                        SettingsStatus("Up to date", tone: .good)
                    }
                }
                if machine.versions.runtime != nil { bots(machine) }
                if machine.kind == .linux, let tools = Self.linuxServerTools {
                    SettingsNote((updates.deviceIsOutdated(machine) ? "Updating the server brings " : "With the server: ") + tools + ".")
                }
                if let workspace = updates.workspace(for: machine) {
                    harnesses(on: .workspace(workspace.id))
                } else {
                    memberHarnesses(machine)
                }
            }
        }
    }

    private func deviceDetail(_ machine: BotMachine, system: String) -> String {
        if machine.kind == .linux, updates.deviceIsOutdated(machine), !updates.canUpdate(machine) {
            return system + " · Update this Mac first. Its Woven Matter brings this server's update."
        }
        if updates.deviceIsOutdated(machine), let target = updates.targetVersion {
            return system + (machine.kind == .linux
                ? " · \(target) is available. Update installs this Mac's server release there."
                : " · \(target) is available. Update installs it on \(machine.name) over Tailscale.")
        }
        return system + " · Up to date with " + (machine.kind == .linux ? "this Mac's server release." : "the newest release.")
    }

    private func bots(_ machine: BotMachine) -> some View {
        let outdated = updates.botsAreOutdated(machine)
        let busy = updates.running && updates.currentItem == machine.id
        let session = model.bots.session(for: machine.id)
        let behind = updates.botsToUpdate(machine)
        let tools = session?.runtimeStatus?.image?.tools
        let state = behind == 0 ? "Updating refreshes each bot's tools and Ubuntu packages."
            : (behind == 1 ? "1 bot has" : "\(behind) bots have") + " newer tools waiting."
        let detail = [tools, state + " Bots keep their files and sign-ins."].compactMap { $0 }.joined(separator: " · ")
        return SettingsRow(title: "Bots", detail: detail) {
            if busy || machine.updating { ProgressView().controlSize(.small) }
            SettingsStatus(outdated ? "Update available" : "Up to date", tone: outdated ? .warning : .good)
            Button("Update") { updates.start(.bots(machineID: machine.id)) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(updates.running || machine.updating || machine.state != .ready)
                .help("Updates the bots VM, then each bot and the tools in its container.")
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
            harnesses(on: .member(machine.id))
        }
    }

    private func harnesses(on location: FleetHarness.Location) -> some View {
        let rows = updates.harnesses(on: location)
        let outdated = rows.filter(\.updateAvailable).count
        let value = rows.isEmpty ? "None installed" : outdated == 0 ? "Up to date" : "Update available"
        return SettingsSummaryRow("Harnesses", detail: "The agents chats run on here. Open to see each version and update one on its own.",
                                  value: value, tone: rows.isEmpty ? nil : outdated > 0 ? .warning : .good) {
            if rows.isEmpty { SettingsEmpty("No harnesses are installed here yet.") }
            ForEach(rows) { harness($0) }
        }
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
