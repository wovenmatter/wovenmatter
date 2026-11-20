import Foundation

// Finding tailnet machines without a Woven server, and installing, updating
// and uninstalling the server on them over SSH. Only a Mac's server does this,
// with the Linux server it carries.

/// A tailnet computer with no Woven server answering on the Woven port.
public struct TailnetDevice: Codable, Sendable, Hashable, Identifiable {
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

/// Tailnet computers without a Woven server.
public struct FindDevices: Request {
  public static let method = "devices.find"
  public typealias Reply = [TailnetDevice]
  public init() {}
}

/// Installs the server on a Linux computer over SSH and starts it as a
/// systemd user unit. Replies once it answers; it then joins on its own.
/// `user` is the SSH user, nil for the one SSH chooses.
public struct InstallServer: Request {
  public static let method = "devices.install"
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
  public static let method = "devices.update"
  public typealias Reply = Done
  public var machineID: String
  public init(machineID: String) { self.machineID = machineID }
}
