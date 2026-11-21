import Foundation
import Observation
import WovenProtocol

/// The UI's connections: one to this Mac's server, for the library, and one
/// directly to each other machine's server, for what runs there. This Mac's
/// server never relays another machine's live streams.
///
/// A machine gets a connection once this Mac's server reports where its
/// server listens; a new address replaces it. Another machine counts as
/// online while its connection is connected.
@MainActor
@Observable
final class MachineConnections {
    let local: ServerConnection
    /// Other machines' connections, by machine id.
    private(set) var remotes: [String: ServerConnection] = [:]
    @ObservationIgnored private var observers: [@MainActor () -> Void] = []

    init(local: ServerConnection) {
        self.local = local
    }

    /// This Mac's machine id, once its server has answered.
    var thisMachineID: String? { local.remote?.machine.id }

    /// The connection to the server of `machineID`: this Mac's for its own id
    /// or nil, else that machine's direct connection, if it has an address.
    func connection(for machineID: String?) -> ServerConnection? {
        guard let machineID, machineID != thisMachineID else { return local }
        return remotes[machineID]
    }

    /// Whether the UI is connected to that machine's server now.
    func isConnected(_ machineID: String?) -> Bool { connection(for: machineID)?.isConnected == true }

    /// This Mac's connection and every other machine's.
    var all: [ServerConnection] { [local] + remotes.keys.sorted().compactMap { remotes[$0] } }

    /// Starts, replaces and stops direct connections to match `ListMachines`.
    /// A machine whose address is not known now keeps the connection it has.
    func update(_ statuses: [MachineStatus]) {
        let listed = Set(statuses.filter { !$0.isThisMachine }.map(\.machine.id))
        for (id, connection) in remotes where !listed.contains(id) {
            connection.stop()
            remotes[id] = nil
        }
        for status in statuses where !status.isThisMachine {
            guard let address = status.address, let port = status.port else { continue }
            let endpoint = ServerEndpoint.tcp(host: address, port: port)
            if let existing = remotes[status.machine.id] {
                guard existing.endpoint != endpoint else { continue }
                existing.stop()
            }
            let connection = ServerConnection(endpoint: endpoint)
            remotes[status.machine.id] = connection
            connection.start()
        }
    }

    #if os(iOS)
    /// Stops every other machine's connection, once the device has forgotten
    /// where its machines are. Connecting again makes new ones.
    func removeRemotes() {
        for connection in remotes.values { connection.stop() }
        remotes = [:]
    }
    #endif

    /// Calls `action` whenever a connection is added, replaced or removed, or
    /// one connects or disconnects.
    func whenChanged(_ action: @escaping @MainActor () -> Void) {
        observers.append(action)
        if observers.count == 1 { track() }
    }

    private func track() {
        withObservationTracking {
            _ = local.isConnected
            for connection in remotes.values { _ = connection.isConnected }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                track()
                for observer in observers { observer() }
            }
        }
    }
}
