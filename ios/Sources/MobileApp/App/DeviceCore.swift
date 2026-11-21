import Foundation
import UIKit
import WovenDevice
import WovenProtocol

/// The device's own core (`WovenDevice`): the server's portable core running
/// inside the app. It owns the device's library, syncs with the machines'
/// servers and runs Quick Chat. The UI reaches it only through a protocol
/// connection, as the Mac UI reaches its own server; this is the one place the
/// app touches it.
@MainActor
final class DeviceCore {
    enum Failure: LocalizedError {
        case notStarted

        var errorDescription: String? { "Woven Matter could not open this device’s library." }
    }

    private var device: WovenDevice?

    /// Starts the core and returns the UI's connection to it. Each reconnect
    /// opens a new in-memory connection.
    func start() async throws -> ServerConnection {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let device = try await WovenDevice.start(WovenDevice.Options(
            dataFolder: URL.applicationSupportDirectory.appending(path: "Woven Matter", directoryHint: .isDirectory),
            deviceName: UIDevice.current.name, appVersion: version))
        self.device = device
        return ServerConnection(connector: { device.connect() })
    }

    /// Dials the Mac a scanned or typed code names and remembers every machine
    /// it knows. Throws the core's `DeviceConnectionError`.
    func add(_ code: ConnectionCode) async throws {
        guard let device else { throw Failure.notStarted }
        try await device.add(code)
    }

    /// Forgets every machine; the device keeps its library.
    func disconnect() async {
        await device?.disconnect()
    }

    /// In the background the core leaves the machines' servers; back in front
    /// it dials them again. Quick Chat is unaffected.
    func setActive(_ active: Bool) async {
        await device?.setActive(active)
    }
}
