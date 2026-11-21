import Foundation
import Observation
import WovenProtocol

/// The iPhones and iPads in the library, as this Mac's server lists them, and
/// the code a device connects with: this Mac's tailnet address and port.
/// A device is never a machine; removing one goes through `machines.remove`.
@MainActor
@Observable
final class DevicesStore {
    /// Every device in the library, by name.
    private(set) var devices: [DeviceStatus] = []
    /// This Mac's code, nil while its server does not listen on the tailnet.
    private(set) var connectionCode: ConnectionCode?
    private(set) var hasLoaded = false
    var errorMessage: String?

    @ObservationIgnored private weak var server: ServerConnection?

    init() {}

    func attach(_ server: ServerConnection) {
        self.server = server
    }

    func device(id: String) -> DeviceStatus? { devices.first { $0.device.id == id } }

    /// Each device's name by id, for labelling the Quick Chats it owns.
    var names: [String: String] {
        Dictionary(devices.map { ($0.device.id, $0.device.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads the devices, and this Mac's tailnet address and port, again.
    func reload() async {
        guard let server, server.isConnected else { return }
        do {
            devices = try await server.call(ListDevices()).sorted {
                ($0.device.name.localizedLowercase, $0.device.id) < ($1.device.name.localizedLowercase, $1.device.id)
            }
            let thisMachine = try await server.call(ListMachines()).first(where: \.isThisMachine)
            connectionCode = thisMachine.flatMap { status in
                status.address.flatMap { ConnectionCode(address: $0, port: status.port ?? wovenPort) }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Deletes the device, its Quick Chats and its folders from every library;
    /// the device starts again empty.
    func remove(_ deviceID: String) async {
        guard let server, server.isConnected else { return errorMessage = ClientError.notConnected.localizedDescription }
        do {
            _ = try await server.call(RemoveMachine(machineID: deviceID))
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
