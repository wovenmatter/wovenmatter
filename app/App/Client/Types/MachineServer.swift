import Foundation

/// The Woven server on one machine, as Settings shows it.
struct MachineServerStatus: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case running
        case stopped
        case unavailable

        var displayName: String {
            switch self {
            case .running: "Running"
            case .stopped: "Stopped"
            case .unavailable: "Server unavailable"
            }
        }
    }

    var state: State
    var hostName: String?
    var health: String?
    var storageUsedBytes: Int64?
    var storageCapacityBytes: Int64?
    var storageAvailableBytes: Int64?
    var storageWarning: String?

    var isRunning: Bool { state == .running }
}

/// Stopping a server with active work asks first.
struct ServerStopResult: Hashable, Sendable {
    var confirmationRequired: Bool
}

/// A Linux computer on the tailnet that does not run the Woven server yet. Adding a
/// workspace lists these and installs the server over SSH.
struct TailnetComputer: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var hostName: String
    var address: String
}

/// What inspecting a Linux computer over SSH found, before installing the server there.
struct MachinePreflight: Hashable, Sendable {
    var hostName: String
    var ready: Bool
    var architecture: String
    var limitations: [String] = []
    var storageCapacityBytes: Int64?
    var storageAvailableBytes: Int64?
}
