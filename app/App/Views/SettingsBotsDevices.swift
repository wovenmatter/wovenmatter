import Observation
import SwiftUI
import WovenMatterClient
import WovenMatterDashboardStore

/// Discover devices: online Linux and macOS tailnet peers and what each needs before it
/// can run bots. Shown on the Bots page and on Mac connections.
struct BotsDiscoverDevicesCard: View {
    @Bindable var bots: BotsModel
    @State private var searching = false
    @State private var installing: String?
    @State private var error: String?
    @State private var users: [String: String] = [:]
    @State private var confirming: BotDiscoveredDevice?

    var body: some View {
        SettingsCard(title: "Discover devices", detail: "Online Macs and Linux machines on your Tailscale network.") {
            VStack(alignment: .leading, spacing: 12) {
                Button(searching ? "Searching…" : "Find devices") { discover() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(searching || installing != nil)
                if let error { SettingsError(error) }
                if let devices = bots.devices {
                    if devices.isEmpty { SettingsEmpty("No other Macs or Linux machines are online on your tailnet.") }
                    ForEach(devices) { device in row(device) }
                }
            }
            .font(.system(size: 13))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DashboardLucideIcon(glyph: device.system == .linux ? .container : .monitor, size: 15).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.system(size: 13, weight: .medium))
                    Text(summary(device)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer(minLength: 8)
                if installing == device.id { ProgressView().controlSize(.small) }
            }
            Group {
                switch device.state {
                case .installBots:
                    HStack(spacing: 8) {
                        TextField("SSH user (optional)", text: Binding(get: { users[device.id] ?? "" }, set: { users[device.id] = $0 }))
                            .dashboardInput().frame(maxWidth: 200)
                        Button("Install bots") { confirming = device }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(installing != nil)
                    }
                case .installApp:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Install Woven Matter on this Mac first").font(.system(size: 12, weight: .medium))
                        ForEach(Array(BotDiscoveredDevice.macSetupSteps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)").font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                case .installing(let message): SettingsNote(message)
                case .failed(let message): SettingsError(message)
                case .ready: EmptyView()
                }
            }
            .padding(.leading, 34)
        }
    }

    private func summary(_ device: BotDiscoveredDevice) -> String {
        let system = device.system == .linux ? "Linux" : "Mac"
        switch device.state {
        case .ready: return system + " · Ready"
        case .installBots: return system + " · No Woven server yet"
        case .installApp: return system + " · Woven Matter isn't connected"
        case .installing: return system + " · Installing…"
        case .failed: return system + " · Install failed"
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

    private func install(_ device: BotDiscoveredDevice) {
        confirming = nil
        installing = device.id
        error = nil
        Task {
            defer { installing = nil }
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
            SettingsCard(title: "Versions don't match", detail: report.message) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.outdated) { part in
                        SettingsValueRow(label: part.name, value: [part.current, part.expected].compactMap { $0 }.joined(separator: " → "))
                    }
                    HStack(spacing: 8) {
                        Button(updater.running ? "Updating…" : "Update everything") { Task { await updater.updateEverything(bots: bots) } }
                            .buttonStyle(DashboardPrimaryButtonStyle())
                            .disabled(updater.running)
                        if let step = updater.current { SettingsNote(step) }
                    }
                    ForEach(updater.failures, id: \.self) { SettingsError($0) }
                }
                .font(.system(size: 13))
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
                do { try await bots.send(.updateLinuxHost(machineID: id)) }
                catch { failures.append("\(name): \(error.localizedDescription)") }
            case let .mac(_, name):
                current = "Updating Woven Matter on \(name)…"
                if let failure = await updateMac(named: name) { failures.append("\(name): \(failure)") }
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

    /// Other Macs update over the same Tailscale SSH path as Mac connections.
    private func updateMac(named name: String) async -> String? {
        let setup = MacDeviceSetupModel()
        await setup.discover()
        guard let row = setup.rows.first(where: { $0.mac.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return "It wasn't found on your tailnet."
        }
        await setup.perform(.update, row: row, central: nil)
        return row.error
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
