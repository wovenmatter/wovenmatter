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

/// Product-level inventory. OS parentage remains available in each item's
/// metadata without forcing users to navigate a process tree.
public struct RuntimeInspectionInventory: Sendable {
  public struct Agent: Identifiable, Sendable {
    public let id: String
    public let summary: RuntimeInspection.Item
    public let details: [RuntimeInspection.Item]
  }
  public let servers: [RuntimeInspection.Item]
  public let agents: [Agent]
  public let connections: [RuntimeInspection.Item]
  public let otherProcesses: [RuntimeInspection.Item]

  public init(items: [RuntimeInspection.Item]) {
    var indexed: [String: RuntimeInspection.Item] = [:]
    for item in items { indexed[item.id] = item }
    let ordered = indexed.values.sorted { $0.id < $1.id }
    servers = ordered.filter { $0.kind == "service" }
    connections = ordered.filter { ["connectionSupervisor", "connectionProcess"].contains($0.kind) }
    var grouped: [String: [RuntimeInspection.Item]] = [:], other: [RuntimeInspection.Item] = []
    func agentKey(_ item: RuntimeInspection.Item) -> String? {
      var candidate: RuntimeInspection.Item? = item, seen = Set<String>(), runtime: String?
      while let current = candidate, seen.insert(current.id).inserted {
        if let chat = current.conversationID { return "chat:" + chat }
        if let native = current.nativeSessionID { return "native:" + native }
        if current.kind == "conversation" { return current.id }
        if current.kind == "runtime", runtime == nil { runtime = current.id }
        candidate = current.parentID.flatMap { indexed[$0] }
      }
      return runtime
    }
    for item in ordered where item.kind != "service" && !["connectionSupervisor", "connectionProcess"].contains(item.kind) {
      if let key = agentKey(item) { grouped[key, default: []].append(item) }
      else { other.append(item) }
    }
    agents = grouped.map { key, members in
      let summary = members.first { $0.kind == "conversation" }
        ?? members.first { $0.kind == "runtime" } ?? members[0]
      return Agent(id: key, summary: summary, details: members.filter { $0.id != summary.id })
    }.sorted { $0.summary.title == $1.summary.title ? $0.id < $1.id : $0.summary.title < $1.summary.title }
    otherProcesses = other
  }
}
