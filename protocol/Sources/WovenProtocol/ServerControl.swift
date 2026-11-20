import Foundation

// Starting, stopping and restarting a machine's server, reading its log, and
// this Mac's idle-sleep policy. A running server carries these out for itself;
// a Mac's server carries them out over SSH for a Linux machine whose server it
// cannot reach.

public enum ServerAction: String, Codable, Sendable, Hashable {
  case start, stop, restart
}

/// Starts, stops or restarts `machineID`'s server. Stopping or restarting a
/// server that has a turn running replies `confirmationRequired` and does
/// nothing unless `confirmed`. The reply comes before the server goes down.
public struct ControlServer: Request {
  public static let method = "server.control"
  public typealias Reply = ServerControlResult
  public var machineID: String
  public var action: ServerAction
  public var confirmed: Bool
  public init(machineID: String, action: ServerAction, confirmed: Bool = false) {
    self.machineID = machineID
    self.action = action
    self.confirmed = confirmed
  }
}

public struct ServerControlResult: Codable, Sendable, Hashable {
  public var confirmationRequired: Bool
  public init(confirmationRequired: Bool) { self.confirmationRequired = confirmationRequired }
}

/// The end of `machineID`'s server log.
public struct ServerLog: Request {
  public static let method = "server.log"
  public typealias Reply = String
  public var machineID: String
  public init(machineID: String) { self.machineID = machineID }
}

/// On which power sources a Mac's server keeps it from idle sleep while a
/// turn runs there. A per-machine setting under `settingKey(machineID:)`;
/// unset means both.
public struct IdleSleepPolicy: Codable, Sendable, Hashable {
  public var externalPower: Bool
  public var batteryPower: Bool
  public init(externalPower: Bool = true, batteryPower: Bool = true) {
    self.externalPower = externalPower
    self.batteryPower = batteryPower
  }

  public static func settingKey(machineID: String) -> String { "power.idleSleep.\(machineID)" }
}
