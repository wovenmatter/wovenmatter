import Foundation

/// An observation from an execution owner. Persisted history never proves liveness.
public struct RuntimeInspection: Codable, Equatable, Sendable {
  public struct Item: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var parentID: String?
    public var conversationID: String?
    public var nativeSessionID: String?
    public var kind: String
    public var title: String
    public var state: String
    public var processID: Int32?
    public var startedAt: Date?
    public var detail: String?
    public var cpuPercent: Double?
    public var residentBytes: Int64?

    public init(id: String, parentID: String? = nil, conversationID: String? = nil,
                kind: String, title: String, state: String, processID: Int32? = nil,
                startedAt: Date? = nil, detail: String? = nil,
                cpuPercent: Double? = nil, residentBytes: Int64? = nil) {
      self.id = id; self.parentID = parentID; self.conversationID = conversationID
      self.kind = kind; self.title = title; self.state = state; self.processID = processID
      self.startedAt = startedAt; self.detail = detail
      self.cpuPercent = cpuPercent; self.residentBytes = residentBytes
    }
  }
  public var ownerID: String
  public var observedAt: Date
  public var items: [Item]
  public init(ownerID: String, observedAt: Date = Date(), items: [Item]) {
    self.ownerID = ownerID; self.observedAt = observedAt; self.items = items
  }
}

public struct RuntimeInspectionRequest: Codable, Sendable {
  public var workspaceID: UUID?
  public var conversationID: String?
  public init(workspaceID: UUID? = nil, conversationID: String? = nil) {
    self.workspaceID = workspaceID; self.conversationID = conversationID
  }
}

public struct BackgroundServerStopRequest: Codable, Sendable {
  public var confirmed: Bool
  public init(confirmed: Bool = false) { self.confirmed = confirmed }
}

public struct BackgroundServerStopResult: Codable, Sendable {
  public var confirmationRequired: Bool
  public var activeWorkCount: Int
  public init(confirmationRequired: Bool, activeWorkCount: Int) {
    self.confirmationRequired = confirmationRequired; self.activeWorkCount = activeWorkCount
  }
}
