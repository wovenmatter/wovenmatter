import Foundation

public enum MobileSyncLane: String, Codable, CaseIterable, Sendable { case library, calendar, journal, artifacts, offlineCache }
public struct MobileSyncLaneStatus: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable { case idle, syncing, current, pending, blocked, unsupported }
  public var phase: Phase = .idle
  public var pendingCount = 0
  public var conflictCount = 0
  public var hasMoreRemoteChanges = false
  public var lastSuccessfulSync: Date?
  public var lastError: String?
  public init() {}
}
public struct MobileSynchronizationStatus: Codable, Equatable, Sendable {
  /// Connectivity is independent of conflicts or a failed individual transfer.
  public var centralReachable: Bool?
  public var lastContactAt: Date?
  public var lanes: [MobileSyncLane: MobileSyncLaneStatus] = [:]
  public init() {}
}
