import Foundation

// Finding tailnet machines without a Woven server, and installing, updating
// and uninstalling the server on them over SSH. Only a Mac's server does this,
// with the Linux server it carries.

/// A tailnet machine with no Woven server answering on the Woven port.
public struct MachineToAdd: Codable, Sendable, Hashable, Identifiable {
  /// Its tailnet host name, which SSH reaches it by.
  public var name: String
  /// Its Tailscale address.
  public var address: String
  /// nil for a system the server cannot be installed on.
  public var platform: MachinePlatform?
  public var id: String { name }

  public init(name: String, address: String, platform: MachinePlatform?) {
    self.name = name
    self.address = address
    self.platform = platform
  }
}

/// Tailnet machines without a Woven server.
public struct FindMachines: Request {
  public static let method = "machines.find"
  public typealias Reply = [MachineToAdd]
  public init() {}
}

/// Installs the server on a Linux machine over SSH and starts it as a
/// systemd user unit. Replies once it answers; it then joins on its own.
/// `user` is the SSH user, nil for the one SSH chooses.
public struct InstallServer: Request {
  public static let method = "machines.install"
  public typealias Reply = Done
  public var host: String
  public var user: String?
  public init(host: String, user: String? = nil) {
    self.host = host
    self.user = user
  }
}

/// Replaces a Linux machine's server with the release this Mac carries and
/// restarts it. Its library stays.
public struct UpdateServer: Request {
  public static let method = "machines.update"
  public typealias Reply = Done
  public var machineID: String
  public init(machineID: String) { self.machineID = machineID }
}

/// Looks at a Linux machine over SSH before the server is installed there.
/// Changes nothing.
public struct InspectMachine: Request {
  public static let method = "machines.inspect"
  public typealias Reply = MachineFacts
  public var host: String
  public var user: String?
  public init(host: String, user: String? = nil) {
    self.host = host
    self.user = user
  }
}

/// What `InspectMachine` found. The server can be installed when `problems` is empty.
public struct MachineFacts: Codable, Sendable, Hashable {
  public var architecture: String
  public var problems: [String]
  public var storageCapacityBytes: Int64?
  public var storageAvailableBytes: Int64?
  public init(architecture: String, problems: [String], storageCapacityBytes: Int64? = nil, storageAvailableBytes: Int64? = nil) {
    self.architecture = architecture
    self.problems = problems
    self.storageCapacityBytes = storageCapacityBytes
    self.storageAvailableBytes = storageAvailableBytes
  }
}
