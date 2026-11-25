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

/// Where an install has got to, in the order the stages happen.
public enum InstallStage: String, Codable, Sendable, CaseIterable {
  /// Looking at the machine over SSH.
  case checking
  /// Packing the release on this Mac.
  case packing
  /// Uploading and unpacking it there.
  case sending
  /// Downloading Node there; skipped when it is already there.
  case node
  /// Writing and starting the unit, and waiting for the server to come up.
  case starting
  /// Waiting for this Mac to link to the new server.
  case connecting
}

/// What an install reports while it runs. Exactly one of `finished` and
/// `failed` ends it.
public enum InstallEvent: Codable, Sendable, Hashable {
  case stage(InstallStage)
  /// This Mac is linked to the new server and has its machine row.
  case finished(machineID: String)
  case failed(message: String)

  private enum Key: String, CodingKey { case type, stage, machineID, message }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "stage": self = .stage(try container.decode(InstallStage.self, forKey: .stage))
    case "finished": self = .finished(machineID: try container.decode(String.self, forKey: .machineID))
    case "failed": self = .failed(message: try container.decode(String.self, forKey: .message))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown install event \(other)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .stage(let stage):
      try container.encode("stage", forKey: .type)
      try container.encode(stage, forKey: .stage)
    case .finished(let machineID):
      try container.encode("finished", forKey: .type)
      try container.encode(machineID, forKey: .machineID)
    case .failed(let message):
      try container.encode("failed", forKey: .type)
      try container.encode(message, forKey: .message)
    }
  }
}

/// Installs the server on a Linux machine over SSH and starts it as a
/// systemd user unit. The reply says the install has begun; its stages
/// follow, which may skip one but never go back, then `finished` once this Mac
/// is linked to it, or `failed`. Unsubscribing stops only the events: the
/// install goes on to the end. `user` is the SSH user, nil for the one SSH chooses.
public struct InstallServer: Subscription {
  public static let method = "machines.install"
  public typealias Reply = Done
  public typealias Event = InstallEvent
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

/// Updates Woven Matter on the Mac whose server is asked to the newest
/// release, with no window or click there: its server opens the app if it is
/// closed, and the app downloads the update, installs it and relaunches.
/// Replies once the download has started, or why it could not; the Mac
/// reports its new release when it is back. Another Mac's UI sends it
/// straight to that Mac's server.
public struct UpdateApp: Request {
  public static let method = "app.update"
  public typealias Reply = Done
  public init() {}
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
