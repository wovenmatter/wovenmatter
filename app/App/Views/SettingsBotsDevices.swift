import Observation
import SwiftUI
import WovenMatterClient
import WovenMatterLibraryStore

/// Install bots on another device: online Linux and macOS tailnet peers and what each
/// needs before it can run bots. Closed on the Bots page until needed.
struct BotsDiscoverDevicesRow: View {
    @Bindable var bots: BotsModel
    @State private var searching = false
    /// The install request being sent; the install itself runs in the background server
    /// and reports through the device's state.
    @State private var starting: String?
    @State private var error: String?
    @State private var users: [String: String] = [:]
    @State private var confirming: BotDiscoveredDevice?

    private var installing: Bool {
        starting != nil || bots.devices?.contains(where: \.isInstalling) == true
    }

    private var failed: Bool {
        bots.devices?.contains { if case .failed = $0.state { true } else { false } } == true
    }

    private var value: String? {
        if failed { return "Needs attention" }
        if installing { return "Installing…" }
        guard let devices = bots.devices else { return nil }
        let waiting = devices.filter { $0.state != .ready }.count
        return waiting == 0 ? nil : waiting == 1 ? "1 device found" : "\(waiting) devices found"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Opens on its own when an install is running or failed.
            SettingsSummaryRow("Install on another device", value: value, tone: failed ? .warning : nil,
                               initiallyExpanded: failed || installing) {
                SettingsNote("Finds online Macs and Linux machines on your Tailscale network.")
                Button(searching ? "Searching…" : "Find devices") { discover() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(searching || installing)
                if let devices = bots.devices {
                    if devices.isEmpty { SettingsEmpty("No other Macs or Linux machines are online on your tailnet.") }
                    ForEach(devices) { device in row(device) }
                }
            }
            // Stays visible when the row is collapsed.
            if let error { SettingsError(error) }
        }
        .confirmationDialog("Install bots on \(confirming?.displayName ?? "")?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), titleVisibility: .visible, presenting: confirming) { device in
            Button("Install") { install(device) }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { _ in
            Text("This installs the Woven server with bots over Tailscale SSH. It uses the SSH account's passwordless sudo to prepare the machine and set up its own container engine. You can add a workspace to it later.")
        }
    }

    @ViewBuilder private func row(_ device: BotDiscoveredDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(title: device.displayName, detail: summary(device)) {
                if starting == device.id || device.isInstalling { ProgressView().controlSize(.small) }
                if device.state == .installBots { installControls(device) }
            }
            switch device.state {
            case .installApp:
                VStack(alignment: .leading, spacing: 2) {
                    SettingsNote("Install Woven Matter on \(device.displayName) first:")
                    ForEach(Array(BotDiscoveredDevice.macSetupSteps.enumerated()), id: \.offset) { index, step in
                        SettingsNote("\(index + 1). \(step)")
                    }
                }
            case .installing(let message): SettingsNote(message)
            case .failed(let message):
                SettingsError(message)
                // A Linux machine can be tried again once the cause is fixed.
                if device.system == .linux { HStack(spacing: 8) { installControls(device) } }
            case .installBots, .ready: EmptyView()
            }
        }
    }

    @ViewBuilder private func installControls(_ device: BotDiscoveredDevice) -> some View {
        TextField("SSH user (optional)", text: Binding(get: { users[device.id] ?? "" }, set: { users[device.id] = $0 }))
            .wovenInput().frame(width: 170)
        Button("Install bots") { confirming = device }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(installing)
    }

    private func summary(_ device: BotDiscoveredDevice) -> String {
        let system = device.system == .linux ? "Linux" : "Mac"
        switch device.state {
        case .ready: return system + " · Ready"
        case .installBots: return system + " · No Woven server yet"
        case .installApp: return system + " · Woven Matter isn't connected"
        case .installing: return system + " · Installing…"
        case .failed: return system + " · Needs attention"
        }
    }

    private func discover() {
        searching = true
        error = nil
        Task {
            defer { searching = false }
            do { try await bots.send(.discoverDevices) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Starts the install. It keeps running if this window closes; its progress and any
    /// failure come back as the device's state.
    private func install(_ device: BotDiscoveredDevice) {
        confirming = nil
        starting = device.id
        error = nil
        Task {
            defer { starting = nil }
            do { try await bots.send(.installBots(hostName: device.hostName, userName: users[device.id]?.nilIfBlank)) }
            catch { self.error = "\(device.displayName): " + error.localizedDescription }
        }
    }
}

/// Shown when devices run different versions: what differs, and one button for all of it.
struct BotsVersionNotice: View {
    @Bindable var bots: BotsModel
    @State private var updater = BotsUpdateCoordinator.shared

    var body: some View {
        let report = bots.versionReport
        if report.needsUpdate || updater.running || !updater.failures.isEmpty {
            SettingsSection(title: "Versions don't match", detail: report.message) {
                ForEach(report.outdated) { part in
                    SettingsRow(title: part.kind == .bots ? "Bots on \(part.name)" : part.name) {
                        Text([part.current, part.expected].compactMap { $0 }.joined(separator: " → "))
                            .font(.settingsBody)
                            .foregroundStyle(WovenPalette.mutedForeground)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 8) {
                    Button(updater.running ? "Updating…" : "Update everything") { Task { await updater.updateEverything(bots: bots) } }
                        .buttonStyle(WovenPrimaryButtonStyle())
                        .disabled(updater.running)
                    if let step = updater.current { SettingsNote(step) }
                }
                ForEach(updater.failures, id: \.self) { SettingsError($0) }
            }
        }
    }
}

/// Elsewhere in Settings, mismatched versions are one line that opens the Bots page.
struct BotsVersionStatusLink: View {
    @Bindable var bots: BotsModel
    let onOpen: () -> Void
    @State private var updater = BotsUpdateCoordinator.shared

    var body: some View {
        let report = bots.versionReport
        if report.needsUpdate || updater.running || !updater.failures.isEmpty {
            SettingsSection {
                SettingsSummaryLink(
                    title: "Versions don't match",
                    value: updater.running ? "Updating…" : "Update everything on the Bots page",
                    tone: .warning,
                    action: onOpen
                )
            }
        }
    }
}

/// "Update everything" across devices, one part at a time, this Mac's app last because it restarts.
@MainActor @Observable
final class BotsUpdateCoordinator {
    static let shared = BotsUpdateCoordinator()
    private(set) var running = false
    private(set) var current: String?
    private(set) var failures: [String] = []

    func updateEverything(bots: BotsModel) async {
        guard !running else { return }
        running = true
        failures = []
        defer { running = false; current = nil }
        await bots.refresh()
        for step in BotUpdatePlan.steps(machines: bots.machines, thisMacVersion: bots.thisMacVersion) {
            switch step {
            case let .linuxHost(id, name):
                current = "Updating \(name)…"
                if let failure = await updateLinuxHost(machineID: id, name: name, bots: bots) { failures.append("\(name): \(failure)") }
            case let .mac(_, name):
                current = "Updating Woven Matter on \(name)…"
                if let failure = await updateMac(named: name) { failures.append("\(name): \(failure)") }
            case let .engine(machineID, name):
                current = "Updating the bots VM on \(name)…"
                if let failure = await updateEngine(machineID: machineID, bots: bots) { failures.append("Bots VM on \(name): \(failure)") }
            case let .bots(machineID, name):
                current = "Updating bots on \(name)…"
                if let session = bots.session(for: machineID) {
                    await session.updateBots()
                    await session.waitForUpdate()
                    if let error = session.progress?.error { failures.append("Bots on \(name): \(error)") }
                }
            case .thisMacApp:
                current = "Checking for an update to this Mac…"
                DesktopUpdater.shared.checkForUpdates()
            }
        }
        await bots.refresh()
    }

    /// Starts a Mac's VM update and follows that machine until it finishes; nil on success.
    private func updateEngine(machineID: String, bots: BotsModel, timeout: Duration = .seconds(3_600)) async -> String? {
        do { try await bots.send(.updateEngine(machineID: machineID)) }
        catch { return error.localizedDescription }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            await bots.refresh()
            guard let machine = bots.machines.first(where: { $0.id == machineID }) else { return "It stopped answering." }
            if !machine.updating { return machine.engineUpdateFailure }
        }
        return "It did not finish in time."
    }

    /// Starts a Linux host's update in the background server and follows its job until it
    /// finishes; nil on success.
    private func updateLinuxHost(machineID: String, name: String, bots: BotsModel, timeout: Duration = .seconds(3_600)) async -> String? {
        do { try await bots.send(.updateLinuxHost(machineID: machineID)) }
        catch { return error.localizedDescription }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let job = bots.job(.updateLinuxHost, target: machineID) else { return "It stopped answering." }
            guard job.running else { return job.error }
            if let progress = job.progress { current = "Updating \(name): \(progress)" }
            try? await Task.sleep(for: .seconds(2))
            await bots.refresh()
        }
        return "It did not finish in time."
    }

    /// Other Macs update over the same Tailscale SSH path as pairing in Apple Devices.
    private func updateMac(named name: String) async -> String? {
        let setup = MacDeviceSetupModel()
        await setup.discover()
        guard let row = setup.rows.first(where: { $0.mac.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return "It wasn't found on your tailnet."
        }
        await setup.perform(.update, row: row, endpoint: nil)
        return row.error
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
