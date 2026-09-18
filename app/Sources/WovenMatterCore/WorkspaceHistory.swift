import Foundation

/// Original transport data. The client owns its protocol; storage does not reduce
/// payloads to a lowest-common-denominator activity model.
public struct WorkspaceHistoryEvent: Sendable {
  public var id: String
  public var conversationID: String?
  public var runID: String?
  public var agentID: String?
  public var harness: String
  public var kind: String
  public var payload: String
  public var completeness: String
  public init(
    id: String = UUID().uuidString.lowercased(), conversationID: String? = nil,
    runID: String? = nil, agentID: String? = nil, harness: String,
    kind: String, payload: String, completeness: String = "observed"
  ) {
    self.id = id
    self.conversationID = conversationID
    self.runID = runID
    self.agentID = agentID
    self.harness = harness
    self.kind = kind
    self.payload = payload
    self.completeness = completeness
  }
}

public typealias WorkspaceWireRecorder =
  @Sendable (_ direction: String, _ data: Data) throws -> Void

public struct WorkspaceHTTPObservation: Codable, Sendable {
  public let method: String
  public let path: String
  public let query: [String: String]
  public let status: Int?
  public let body: String
  public init(method: String, path: String, query: [String: String], status: Int?, body: String) {
    self.method = method; self.path = path; self.query = query; self.status = status; self.body = body
  }
}

/// Versioned, read-only query contract. No caller-supplied SQL is executed.
public struct WorkspaceHistoryQuery: Codable, Sendable {
  public var schemaVersion: Int = 1
  public var command: String
  public var id: String?
  public var search: String?
  public var conversationID: String?
  public var runID: String?
  public var harness: String?
  public var folderID: String?
  public var kind: String?
  public var since: String?
  public var until: String?
  public var after: Int64 = 0
  public var limit: Int = 50
  public var offset: Int = 0
  public var characters: Int = 65536
  public var callerConversationID: String?
  public var message: String?
  public var requestID: String?
  enum CodingKeys: String, CodingKey {
    case schemaVersion, command, id, search, conversationID, runID, harness, folderID, kind, since, until
    case after, limit, offset, characters, callerConversationID, message, requestID
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    command = try c.decode(String.self, forKey: .command)
    id = try c.decodeIfPresent(String.self, forKey: .id)
    search = try c.decodeIfPresent(String.self, forKey: .search)
    conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
    runID = try c.decodeIfPresent(String.self, forKey: .runID)
    harness = try c.decodeIfPresent(String.self, forKey: .harness)
    folderID = try c.decodeIfPresent(String.self, forKey: .folderID)
    kind = try c.decodeIfPresent(String.self, forKey: .kind)
    since = try c.decodeIfPresent(String.self, forKey: .since)
    until = try c.decodeIfPresent(String.self, forKey: .until)
    after = try c.decodeIfPresent(Int64.self, forKey: .after) ?? 0
    limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50
    offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    characters = try c.decodeIfPresent(Int.self, forKey: .characters) ?? 65536
    callerConversationID = try c.decodeIfPresent(String.self, forKey: .callerConversationID)
    message = try c.decodeIfPresent(String.self, forKey: .message)
    requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
  }
  public init(
    command: String, id: String? = nil, search: String? = nil,
    conversationID: String? = nil, runID: String? = nil,
    harness: String? = nil, kind: String? = nil, after: Int64 = 0, limit: Int = 50
  ) {
    self.command = command
    self.id = id
    self.search = search
    self.conversationID = conversationID
    self.runID = runID
    self.harness = harness
    self.kind = kind
    self.after = after
    self.limit = limit
  }
}

public struct NoteAssetVersion: Codable, Identifiable, Sendable {
  public let id: String
  public let noteID: String
  public let title: String
  public let content: String
  public let revision: String
  public let createdAt: String
  public let source: String
  public init(
    id: String, noteID: String, title: String, content: String, revision: String, createdAt: String,
    source: String
  ) {
    self.id = id
    self.noteID = noteID
    self.title = title
    self.content = content
    self.revision = revision
    self.createdAt = createdAt
    self.source = source
  }
}
