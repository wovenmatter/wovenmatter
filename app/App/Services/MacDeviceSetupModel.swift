import Foundation
import Observation
import WovenMatterDashboardStore

@MainActor @Observable
final class MacDeviceRow: Identifiable {
    var mac: CompanionTailnetMac
    nonisolated let id: String
    var connection: CompanionMacSSHConnection
    var installation: CompanionMacInstallation?
    var error: String?
    var message: String?
    var busy = false
    var checking = false
    init(_ mac: CompanionTailnetMac) { self.mac = mac; id = mac.id; connection = .init(alias: mac.sshName) }
}

@MainActor @Observable
final class MacDeviceSetupModel {
    enum Action { case pair, installAndPair, download, update, open }
    private(set) var rows: [MacDeviceRow] = []
    private(set) var searching = false
    private(set) var searched = false
    private(set) var error: String?
    private(set) var release: CompanionMacRelease?
    private(set) var releaseError: String?
    private let management: CompanionMacManagement
    private let getRelease: @Sendable () async throws -> CompanionMacRelease
    private let pollDelay: @Sendable () async throws -> Void
    init(management: CompanionMacManagement = .init(), getRelease: (@Sendable () async throws -> CompanionMacRelease)? = nil,
         pollDelay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) {
        self.management = management
        self.getRelease = getRelease ?? { try await management.latestRelease() }
        self.pollDelay = pollDelay
    }

    func discover() async {
        guard !searching, !rows.contains(where: \.busy) else { return }
        searching = true; error = nil; searched = false
        defer { searching = false }
        do {
            let inventory = try await management.inventory()
            rows = inventory.map { mac in
                let row = rows.first(where: { $0.id == mac.id }) ?? MacDeviceRow(mac)
                row.mac = mac
                if !mac.online { row.installation = nil; row.error = nil }
                return row
            }
            searched = true
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.checkRelease() }
                // Limit SSH inspection concurrency on large tailnets.
                for offset in stride(from: 0, to: rows.count, by: 4) {
                    for row in rows[offset..<min(offset + 4, rows.count)] where row.mac.online {
                        group.addTask { await self.inspect(row) }
                    }
                    await group.waitForAll()
                }
            }
        } catch { rows = []; self.error = error.localizedDescription }
    }
    func checkRelease() async {
        releaseError = nil
        do { release = try await getRelease() }
        catch { releaseError = error.localizedDescription }
    }
    func inspect(_ row: MacDeviceRow) async {
        guard !row.checking, !row.busy else { return }
        row.checking = true; row.error = nil; row.installation = nil
        defer { row.checking = false }
        do { row.installation = try await management.inspect(row.mac, connection: row.connection) }
        catch { row.error = "Installation could not be checked. Verify existing SSH access in Connection settings, then retry. " + error.localizedDescription }
    }
    func perform(_ action: Action, row: MacDeviceRow, central: URL?, requestRemoteCentral: (@MainActor () async throws -> Void)? = nil) async {
        guard !row.busy, !row.checking else { return }
        row.busy = true; row.error = nil; row.message = nil
        defer { row.busy = false }
        do {
            if action == .open {
                try await management.open(row.mac, connection: row.connection)
                row.message = "Opened Woven Matter. In Apple Devices on that Mac, change it to a node and make it discoverable, then find devices here to pair."
                return
            }
            if action == .update || action == .installAndPair || action == .download {
                guard let release else { throw MacDeviceSetupError("Check for updates before downloading Woven Matter.") }
                row.message = "Downloading and verifying Woven Matter \(release.version)…"
                try await management.install(row.mac, connection: row.connection, release: release,
                    requirePairingSupport: action == .installAndPair && central != nil)
                row.installation = try await management.inspect(row.mac, connection: row.connection)
                row.message = "Woven Matter \(row.installation?.version ?? release.version) installed."
            }
            if action != .update && action != .download {
                guard let central else {
                    guard let requestRemoteCentral else { throw MacDeviceSetupError("Wait for this Mac’s central database to become available before pairing.") }
                    row.message = "Opening Woven Matter on the central Mac…"
                    try await management.open(row.mac, connection: row.connection)
                    try await requestRemoteCentral()
                    row.message = "Waiting for pairing approval on the other Mac."
                    return
                }
                guard row.installation?.supportsSetup == true else {
                    throw MacDeviceSetupError("This version needs to be updated before pairing from here. You can also open Apple Devices on that Mac to pair manually.")
                }
                row.message = "Opening Woven Matter and requesting pairing…"
                let requestID = try await management.requestPairing(row.mac, connection: row.connection, central: central)
                // Surface target-side transition failures instead of implying success
                // merely because LaunchServices accepted an open request.
                for _ in 0..<30 {
                    try await pollDelay()
                    let state = try await management.inspect(row.mac, connection: row.connection)
                    row.installation = state
                    if let status = state.setupResult, status.requestID == requestID {
                        row.message = status.message
                        if status.phase == .failed { throw MacDeviceSetupError(status.message) }
                        if status.phase == .waiting || status.phase == .paired { return }
                    }
                }
                throw MacDeviceSetupError("The Mac has not confirmed its pairing request. Check Woven Matter on that Mac, then retry.")
            }
        } catch { row.message = nil; row.error = error.localizedDescription }
    }
}

struct MacDeviceSetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
