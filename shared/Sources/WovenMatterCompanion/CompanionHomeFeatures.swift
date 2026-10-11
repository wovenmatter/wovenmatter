import Foundation

public struct CompanionScheduledTaskItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String { event.id }
  public var event: CompanionCalendarEvent
  public var showsOnCalendar: Bool
  public var runtimeName: String
  public var workspaceName: String
  public var lastRunAt: Date?
  public init(event: CompanionCalendarEvent, showsOnCalendar: Bool, runtimeName: String, workspaceName: String, lastRunAt: Date?) {
    self.event = event; self.showsOnCalendar = showsOnCalendar; self.runtimeName = runtimeName
    self.workspaceName = workspaceName; self.lastRunAt = lastRunAt
  }
}

public struct CompanionDatabaseSource: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var kind: String
  public var databases: [CompanionDatabaseItem]
  public var error: String?
  public init(id: String, name: String, kind: String, databases: [CompanionDatabaseItem], error: String?) {
    self.id = id; self.name = name; self.kind = kind; self.databases = databases; self.error = error
  }
}

public struct CompanionDatabaseItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var format: String
  public var isExternal: Bool
  public init(id: String, name: String, format: String, isExternal: Bool) {
    self.id = id; self.name = name; self.format = format; self.isExternal = isExternal
  }
}

/// Recorded usage only. A nil cost is unknown or subscription usage, never zero spend.
public struct CompanionUsageSample: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var timestamp: Date
  public var provider: String
  public var model: String
  public var account: String
  public var workspace: String?
  public var sessionID: String
  public var inputTokens: Int64
  public var outputTokens: Int64
  public var cacheTokens: Int64
  public var totalTokens: Int64
  public var requests: Int
  public var costUSD: Double?
  public init(id: String, timestamp: Date, provider: String, model: String, account: String, workspace: String?, sessionID: String,
              inputTokens: Int64, outputTokens: Int64, cacheTokens: Int64, totalTokens: Int64, requests: Int, costUSD: Double?) {
    self.id = id; self.timestamp = timestamp; self.provider = provider; self.model = model; self.account = account
    self.workspace = workspace; self.sessionID = sessionID; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    self.cacheTokens = cacheTokens; self.totalTokens = totalTokens; self.requests = requests; self.costUSD = costUSD
  }
}
