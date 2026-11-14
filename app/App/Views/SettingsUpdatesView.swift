import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Settings → Updates: Woven Matter and its harnesses on this Mac and every other device,
/// each with its own Update button, and three buttons that update all of it.
struct SettingsUpdatesView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    @State private var updates = FleetUpdatesModel.shared

    var body: some View {
        SettingsPage(
            title: "Updates",
            detail: "Woven Matter and its harnesses on this Mac and your other devices.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            overview
            thisMac
            ForEach(updates.devices) { device($0) }
            SettingsHelp {
                SettingsNote("Update everything updates Woven Matter on every device first, then every harness. Update Woven Matter and Update harnesses do one half.")
                SettingsNote("Linux servers get the server release that comes with this Mac's Woven Matter. When this Mac is behind the newest release, it updates first and restarts, then the update continues with your other devices and harnesses.")
                SettingsNote("Before a Linux workspace runs a harness installer, you review its download. One review covers every download in the update.")
                SettingsNote("If an update would stop chats that are running, you're asked first.")
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
            Text(confirmation.items.map(\.text).joined(separator: "\n") + "\n\nUpdating now stops this work.")
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

    // MARK: Overview

    private var headline: String {
        if updates.checkedAt == nil && updates.checking { return "Checking for updates…" }
        switch updates.availableCount {
        case 0: return updates.checkedAt == nil ? "Updates" : "Everything is up to date"
        case 1: return "1 update available"
        case let count: return "\(count) updates available"
        }
    }

    private var checkedDetail: String? {
        var parts: [String] = []
        if let release = updates.release { parts.append("Woven Matter \(release.version) is the newest release.") }
        if let checked = updates.checkedAt {
            parts.append("Checked \(checked.formatted(.relative(presentation: .named))).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var appsAvailable: Bool {
        updates.thisMacIsBehind || updates.devices.contains { updates.canUpdate($0) || updates.botsAreOutdated($0) }
    }

    private var harnessesAvailable: Bool { updates.allHarnesses.contains(where: \.updateAvailable) }

    private var overview: some View {
        SettingsSection {
            SettingsRow(title: headline, detail: checkedDetail) {
                if updates.checking { ProgressView().controlSize(.small) }
                Button(updates.checking ? "Checking…" : "Check now") { Task { await updates.checkAll() } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(updates.checking || updates.running)
            }
            HStack(spacing: 8) {
                Button(updates.running ? "Updating…" : "Update everything") { updates.start(.scope(.everything)) }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .disabled(!(appsAvailable || harnessesAvailable))
                Button("Update Woven Matter") { updates.start(.scope(.apps)) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(!appsAvailable)
                Button("Update harnesses") { updates.start(.scope(.harnesses)) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(!harnessesAvailable)
            }
            .disabled(updates.running || updates.review != nil)
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

    // MARK: Devices

    private var thisMac: some View {
        let version = updates.thisMacVersion ?? "unknown"
        let latest = updates.release?.version
        return SettingsSection(title: "This Mac") {
            SettingsRow(title: "Woven Matter \(version)", detail: updates.thisMacIsBehind ? latest.map { "\($0) is available." } : nil) {
                if updates.thisMacIsBehind {
                    SettingsStatus("Update available", tone: .warning)
                    Button("Update") { updates.start(.thisMacApp) }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(updates.running)
                } else if latest != nil {
                    SettingsStatus("Up to date", tone: .good)
                }
            }
            if let machine = model.bots.thisMachine, machine.versions.runtime != nil { bots(machine) }
            harnesses(on: .thisMac)
        }
    }

    private func device(_ machine: BotMachine) -> some View {
        let system = machine.kind == .linux ? "Linux" : "Mac"
        let product = machine.kind == .linux ? "Woven server" : "Woven Matter"
        let version = machine.versions.app ?? (machine.kind == .linux ? "an older release" : "unknown version")
        return SettingsSection(title: machine.name) {
            if machine.state == .unreachable {
                SettingsRow(title: "\(product) \(machine.versions.app ?? "")".trimmingCharacters(in: .whitespaces),
                            detail: system + " · " + (machine.message ?? "Not reachable right now.")) {
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
                        }
                    } else {
                        SettingsStatus("Up to date", tone: .good)
                    }
                }
                if machine.versions.runtime != nil { bots(machine) }
                if let workspace = updates.workspace(for: machine) {
                    harnesses(on: .workspace(workspace.id))
                } else {
                    SettingsNote(machine.kind == .mac
                        ? "Its harnesses are updated on that Mac, in Settings → Updates."
                        : "Its harnesses are updated from the Mac that added it.")
                }
            }
        }
    }

    private func deviceDetail(_ machine: BotMachine, system: String) -> String {
        if machine.kind == .linux, updates.deviceIsOutdated(machine), !updates.canUpdate(machine) {
            return system + " · Update this Mac first. Its Woven Matter brings this server's update."
        }
        if updates.deviceIsOutdated(machine), let target = updates.targetVersion { return system + " · \(target) is available." }
        return system
    }

    private func bots(_ machine: BotMachine) -> some View {
        let outdated = updates.botsAreOutdated(machine)
        return SettingsRow(title: "Bots", detail: machine.versions.runtime.map { "Runtime \($0)" }) {
            SettingsStatus(outdated ? "Update available" : "Up to date", tone: outdated ? .warning : .good)
        }
    }

    // MARK: Harnesses

    private func harnesses(on location: FleetHarness.Location) -> some View {
        let rows = updates.harnesses(on: location)
        let outdated = rows.filter(\.updateAvailable).count
        let value = rows.isEmpty ? "None installed" : outdated == 0 ? "Up to date" : outdated == 1 ? "1 to update" : "\(outdated) to update"
        return SettingsSummaryRow("Harnesses", value: value, tone: rows.isEmpty ? nil : outdated > 0 ? .warning : .good) {
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

    private var busyTitle: String {
        let count = updates.busyConfirmation?.items.count ?? 0
        return count == 1 ? "Something is still running" : "\(count) things are still running"
    }

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
