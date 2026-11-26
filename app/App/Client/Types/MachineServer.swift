import Foundation

/// Stopping a server with active work asks first.
struct ServerStopResult: Hashable, Sendable {
    var confirmationRequired: Bool
}

/// A Linux machine on the tailnet that does not run the Woven server yet. Adding a
/// workspace lists these and installs the server over SSH.
struct MachineToAdd: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var hostName: String
    var address: String
}

/// What inspecting a Linux machine over SSH found, before installing the server there.
struct MachinePreflight: Hashable, Sendable {
    var hostName: String
    var ready: Bool
    var architecture: String
    var limitations: [String] = []
    var storageCapacityBytes: Int64?
    var storageAvailableBytes: Int64?
}
