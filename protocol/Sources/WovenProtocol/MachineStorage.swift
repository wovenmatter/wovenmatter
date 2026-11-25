import Foundation

/// The volume the answering server's data folder is on.
public struct ReadStorage: Request {
  public static let method = "machines.storage"
  public typealias Reply = MachineStorage
  public init() {}
}

public struct MachineStorage: Codable, Sendable, Hashable {
  public var capacityBytes: Int64
  public var availableBytes: Int64
  public init(capacityBytes: Int64, availableBytes: Int64) {
    self.capacityBytes = capacityBytes
    self.availableBytes = availableBytes
  }
}
