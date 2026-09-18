import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

public enum WorkspaceDatabaseError: Error, Equatable {
  case open(String)
  case execute(String)
  case prepare(String)
  case bind(String)
  case step(String)
  case corruptRow
}

public enum BuzzWorkspaceDatabaseError: LocalizedError, Equatable, Sendable {
  case workspaceNotFound
  case enrollmentNotFound
  case localACPRequired
  case enrollmentRequiresRefresh

  public var errorDescription: String? {
    switch self {
    case .workspaceNotFound:
      "The linked Buzz workspace is no longer available."
    case .enrollmentNotFound:
      "The linked Buzz agent is no longer enrolled."
    case .localACPRequired:
      "This Buzz agent is not available through a local ACP workspace."
    case .enrollmentRequiresRefresh:
      "This Buzz agent’s runtime changed. Remove and re-enroll it to use the current definition."
    }
  }
}

public enum WorkspaceNoteMutationError: LocalizedError, Equatable, Sendable {
  case folderNotFound
  case noteNotFound
  case revisionConflict

  public var errorDescription: String? {
    switch self {
    case .folderNotFound:
      "The selected folder is no longer available."
    case .noteNotFound:
      "The note is no longer available."
    case .revisionConflict:
      "The note changed since it was read. Read it again before applying edits."
    }
  }
}

public enum WorkspaceFolderMutationError: LocalizedError, Equatable, Sendable {
  case emptyName
  case folderNotFound

  public var errorDescription: String? {
    switch self {
    case .emptyName:
      "Enter a name for the folder."
    case .folderNotFound:
      "The folder is no longer available."
    }
  }
}

public enum WorkspaceCalendarMutationError: LocalizedError, Equatable, Sendable {
  case emptyTitle
  case invalidDateRange

  public var errorDescription: String? {
    switch self {
    case .emptyTitle:
      "Enter a title for the event."
    case .invalidDateRange:
      "The event must end after it starts."
    }
  }
}

public struct LocalACPSessionDescriptor: Equatable, Sendable {
  public let conversationID: String
  public let runtimeKind: AgentRuntimeKind
  public let title: String
  public let acpSessionID: String?
  public let model: String?
  public let thinking: String?
  public let buzzWorkspaceLinkID: UUID?
  public let buzzAgentID: String?
  public let remoteWorkspaceID: UUID?

  public init(
    conversationID: String,
    runtimeKind: AgentRuntimeKind,
    title: String,
    acpSessionID: String?,
    model: String? = nil,
    thinking: String? = nil,
    buzzWorkspaceLinkID: UUID? = nil,
    buzzAgentID: String? = nil,
    remoteWorkspaceID: UUID? = nil
  ) {
    self.conversationID = conversationID
    self.runtimeKind = runtimeKind
    self.title = title
    self.acpSessionID = acpSessionID
    self.model = model
    self.thinking = thinking
    self.buzzWorkspaceLinkID = buzzWorkspaceLinkID
    self.buzzAgentID = buzzAgentID
    self.remoteWorkspaceID = remoteWorkspaceID
  }
}

public struct BuzzLocalAgentLaunchSource: Equatable, Sendable {
  public let link: BuzzWorkspaceLink
  public let enrollment: BuzzWorkspaceAgentEnrollment

  public init(
    link: BuzzWorkspaceLink,
    enrollment: BuzzWorkspaceAgentEnrollment
  ) {
    self.link = link
    self.enrollment = enrollment
  }
}

public struct LocalACPRunIdentifiers: Equatable, Sendable {
  public let runID: String
  public let userMessageID: String
  public let assistantMessageID: String

  public init(runID: String, userMessageID: String, assistantMessageID: String) {
    self.runID = runID
    self.userMessageID = userMessageID
    self.assistantMessageID = assistantMessageID
  }
}

public struct PendingRemoteNoteEdit: Equatable, Sendable {
  public let runID: String
  public let assistantMessageID: String
  public let noteID: String
  public let expectedRevision: String
  public let nonce: String
  public let noteKind: NoteArtifactKind
  public let assistantContent: String
}

public struct LocalACPSteeringIdentifiers: Equatable, Sendable {
  public let runID: String
  public let userMessageID: String
  public let assistantMessageID: String

  public init(runID: String, userMessageID: String, assistantMessageID: String) {
    self.runID = runID
    self.userMessageID = userMessageID
    self.assistantMessageID = assistantMessageID
  }
}

public enum LocalACPSessionDatabaseError: LocalizedError, Equatable, Sendable {
  case runtimeUnavailable
  case sessionNotFound
  case runNotFound
  case runAlreadyActive
  case steeringUnsupported
  case anotherApplicationIsRunningPrompt

  public var errorDescription: String? {
    switch self {
    case .runtimeUnavailable:
      "The selected local ACP runtime is not available."
    case .sessionNotFound:
      "The local ACP session is no longer available."
    case .runNotFound:
      "The local ACP run is no longer available."
    case .runAlreadyActive:
      "This local ACP session is already running a prompt."
    case .steeringUnsupported:
      "This agent does not support steering during an active turn."
    case .anotherApplicationIsRunningPrompt:
      "Another Woven Matter app is already running a local prompt."
    }
  }
}

public final class WorkspaceDatabase: @unchecked Sendable {
  let lock = NSLock()
  var connection: OpaquePointer?

  public init(url: URL) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to allocate SQLite connection"
      if let database { sqlite3_close(database) }
      throw WorkspaceDatabaseError.open(message)
    }
    connection = database

    do {
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA foreign_keys = ON")
      try execute("PRAGMA busy_timeout = 5000")
      try migrate()
    } catch {
      sqlite3_close(database)
      connection = nil
      throw error
    }
  }

  deinit {
    if let connection { sqlite3_close(connection) }
  }

  func transaction<T>(_ operation: () throws -> T) throws -> T {
    try lock.withLock {
      try executeUnlocked("BEGIN IMMEDIATE")
      do {
        let result = try operation()
        try executeUnlocked("COMMIT")
        return result
      } catch {
        try? executeUnlocked("ROLLBACK")
        throw error
      }
    }
  }

  func execute(_ sql: String) throws {
    try lock.withLock { try executeUnlocked(sql) }
  }

  func executeUnlocked(_ sql: String) throws {
    guard let connection else { throw WorkspaceDatabaseError.execute("Database is closed") }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
      sqlite3_free(errorMessage)
      throw WorkspaceDatabaseError.execute(message)
    }
  }

  func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
    guard let connection else { throw WorkspaceDatabaseError.prepare("Database is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw WorkspaceDatabaseError.prepare(String(cString: sqlite3_errmsg(connection)))
    }
    return statement
  }

  func canonicalWorkspaceOperatorIDUnlocked() throws -> String? {
    let inferred = try prepareUnlocked("""
      SELECT user_id
      FROM (
        SELECT user_id FROM dashboard_conversations WHERE deleted_at IS NULL
        UNION ALL
        SELECT user_id FROM dashboard_agents WHERE deleted_at IS NULL
        UNION ALL
        SELECT user_id FROM notes WHERE deleted_at IS NULL
        UNION ALL
        SELECT user_id FROM folders
        UNION ALL
        SELECT user_id FROM dashboard_calendar_items
        UNION ALL
        SELECT id AS user_id FROM profiles
      )
      GROUP BY user_id
      ORDER BY COUNT(*) DESC, user_id
      LIMIT 1
      """)
    defer { sqlite3_finalize(inferred) }
    let inferredCode = sqlite3_step(inferred)
    if inferredCode == SQLITE_ROW { return try text(inferred, column: 0) }
    guard inferredCode == SQLITE_DONE else { throw stepError() }
    return nil
  }

  func localMutationOperatorIDUnlocked() throws -> String {
    try canonicalWorkspaceOperatorIDUnlocked() ?? "local-operator"
  }

  func validateFolderUnlocked(id: String?, operatorID: String) throws {
    guard let id else { return }
    let statement = try prepareUnlocked("""
      SELECT 1 FROM folders
      WHERE id = ? AND user_id = ?
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw WorkspaceNoteMutationError.folderNotFound
    }
  }

  func nextNotePositionUnlocked(
    folderID: String?,
    operatorID: String
  ) throws -> Int {
    let statement = try prepareUnlocked(folderID == nil ? """
      SELECT COALESCE(MAX(position), -1) + 1
      FROM notes
      WHERE user_id = ? AND folder_id IS NULL AND deleted_at IS NULL
      """ : """
      SELECT COALESCE(MAX(position), -1) + 1
      FROM notes
      WHERE user_id = ? AND folder_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(statement) }
    try bind(operatorID, at: 1, to: statement)
    if let folderID {
      try bind(folderID, at: 2, to: statement)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  func noteForEditingUnlocked(
    id: String,
    operatorID: String
  ) throws -> (title: String, content: String, revision: String) {
    let statement = try prepareUnlocked("""
      SELECT title, content, updated_at
      FROM notes
      WHERE id = ? AND user_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw WorkspaceNoteMutationError.noteNotFound
    }
    return (
      try text(statement, column: 0),
      try text(statement, column: 1),
      try text(statement, column: 2)
    )
  }

  static func noteSnippet(_ content: String) -> String {
    let content = NoteDocument.decode(content).plainText
    let replacements: [(String, String, String.CompareOptions)] = [
      (#"</p>\s*<p[^>]*>"#, " ", .regularExpression),
      (#"<br\s*/?>"#, " ", [.regularExpression, .caseInsensitive]),
      (#"</li>\s*<li[^>]*>"#, " ", [.regularExpression, .caseInsensitive]),
      (#"<[^>]+>"#, "", .regularExpression),
      ("&nbsp;", " ", []),
      ("&amp;", "&", []),
      ("&lt;", "<", []),
      ("&gt;", ">", []),
      ("&quot;", "\"", []),
      ("&#39;", "'", []),
      ("&#x27;", "'", [.caseInsensitive]),
    ]
    var text = content
    for (source, replacement, options) in replacements {
      text = text.replacingOccurrences(
        of: source,
        with: replacement,
        options: options
      )
    }
    text = text
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.count > 180 ? "\(text.prefix(177))..." : text
  }

  func decodeCanonicalRowsUnlocked<Value: Decodable>(
    _ sql: String,
    operatorID: String,
    as type: Value.Type
  ) throws -> [Value] {
    try decodeCanonicalRowsUnlocked(
      sql,
      bindings: [operatorID],
      as: type
    )
  }

  func decodeCanonicalRowsUnlocked<Value: Decodable>(
    _ sql: String,
    bindings: [String],
    as type: Value.Type
  ) throws -> [Value] {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
      try bind(value, at: Int32(offset + 1), to: statement)
    }
    let decoder = JSONDecoder()
    var values: [Value] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return values }
      guard code == SQLITE_ROW else { throw stepError() }
      do {
        values.append(try decoder.decode(Value.self, from: blob(statement, column: 0)))
      } catch {
        NSLog(
          "Ignoring incompatible cached %@ projection: %@",
          String(reflecting: Value.self),
          String(describing: error)
        )
      }
    }
  }

  func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
    guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
      throw bindError()
    }
  }

  func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
    if value.isEmpty {
      guard sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK else {
        throw bindError()
      }
      return
    }
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement,
        index,
        bytes.baseAddress,
        Int32(bytes.count),
        SQLITE_TRANSIENT
      )
    }
    guard result == SQLITE_OK else { throw bindError() }
  }

  func bindNullable(
    _ value: String?,
    at index: Int32,
    to statement: OpaquePointer
  ) throws {
    if let value {
      try bind(value, at: index, to: statement)
    } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
      throw bindError()
    }
  }

  func text(_ statement: OpaquePointer, column: Int32) throws -> String {
    guard let value = sqlite3_column_text(statement, column) else { throw WorkspaceDatabaseError.corruptRow }
    return String(cString: value)
  }

  func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }

  func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0 else { return Data() }
    guard let bytes = sqlite3_column_blob(statement, column) else { throw WorkspaceDatabaseError.corruptRow }
    return Data(bytes: bytes, count: count)
  }

  func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
  }

  func bindError() -> WorkspaceDatabaseError {
    .bind(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
  }

  func stepError() -> WorkspaceDatabaseError {
    .step(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
  }

  private static func formatter(includingFractionalSeconds: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = includingFractionalSeconds
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter
  }

  static func timestamp(_ date: Date) -> String {
    formatter(includingFractionalSeconds: true).string(from: date)
  }

  static func agentOrderJSON(_ order: [UUID]?) throws -> String {
    let data = try JSONEncoder().encode(
      (order ?? []).map { $0.uuidString.lowercased() }
    )
    guard let value = String(data: data, encoding: .utf8) else {
      throw WorkspaceDatabaseError.bind("Could not encode the local CLI agent order")
    }
    return value
  }

  static func agentOrder(from value: String) -> [UUID] {
    guard let data = value.data(using: .utf8),
          let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return identifiers.compactMap(UUID.init(uuidString:))
  }

  static func date(_ value: String) -> Date? {
    formatter(includingFractionalSeconds: true).date(from: value)
      ?? formatter(includingFractionalSeconds: false).date(from: value)
  }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension NSLock {
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try operation()
  }
}
