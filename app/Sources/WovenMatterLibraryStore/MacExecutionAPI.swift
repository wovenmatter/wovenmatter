import Foundation
import WovenMatterCore

/// The local Mac execution surface shares native command receipts with the
/// desktop and with the library API. It cannot launch or control other hosts.
@MainActor
public final class MacExecutionAPI: ExecutionStreamSource {
  private let database: WorkspaceDatabase
  private let commands: any DeviceCommandServing
  private let descriptor: ExecutionWorkspace
  private let events: (@MainActor @Sendable (Int64) async throws -> ExecutionJournalPage)?
  private let isActive: @MainActor @Sendable () -> Bool
  /// Signed member requests: any Mac or phone member controls this Mac's
  /// local sessions with its own signature; nothing is issued or managed.
  private let members: MemberDirectory?
  private struct Scope { let deviceID: String; let libraryID: String; let workspaceID: String }
  public init(database: WorkspaceDatabase, commands: any DeviceCommandServing, descriptor: ExecutionWorkspace,
              isActive: @escaping @MainActor @Sendable () -> Bool,
              events: (@MainActor @Sendable (Int64) async throws -> ExecutionJournalPage)? = nil,
              members: MemberDirectory? = nil) {
    self.members = members
    self.database = database; self.commands = commands
    self.descriptor = descriptor; self.isActive = isActive; self.events = events
  }

  public func handle(_ request: LibraryHTTPRequest) async -> LibraryHTTPResponse {
    guard isActive() else { return .error("unavailable", "This Mac execution workspace is stopped.", status: 503) }
    do {
      guard let url = URLComponents(string: "http://localhost" + request.target) else { return .error("invalid_request", "Invalid execution path.", status: 400) }
      var path = url.path
      if path.hasPrefix("/wovenmatter/") { path = String(path.dropFirst("/wovenmatter".count)) }
      guard path == "/v1/execution" || path.hasPrefix("/v1/execution/") else { return .error("not_found", "Unknown execution endpoint.", status: 404) }
      guard request.headers["x-woven-protocol"] == String(LibraryProtocol.version) else { return .error("version_mismatch", "Update both clients to compatible versions.", status: 426) }
      // Every caller is a member signing with its own key.
      guard MemberRequestVerifier.isSigned(request.headers) else {
        return .error("unauthorized", "Sign this request with a member device key.", status: 401)
      }
      guard let members else { return .error("unauthorized", "This Mac does not accept member requests yet.", status: 401) }
      let member: MemberKey
      do {
        member = try await members.verifier.verify(method: request.method, target: request.target, headers: request.headers,
                                                   body: request.body, allowing: [.mac, .ios, .linux])
      } catch let error as MemberRequestError { return .error(error.code, error.message, status: error.code == "wrong_device" ? 403 : 401) }
      guard request.headers["x-woven-workspace"].map({ $0 == descriptor.id }) ?? true else {
        return .error("wrong_workspace", "This request names another workspace.", status: 403)
      }
      let scope = Scope(deviceID: member.deviceID, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
      let authorize: @MainActor () async throws -> Void = {
        guard await members.member(member.deviceID) != nil else { throw LibraryAPIError(code: "unauthorized", message: MemberRequestError.unknown.message) }
      }
      try await authorize()
      guard isActive() else { return .error("unavailable", "This Mac execution workspace stopped.", status: 503) }
      let parts = path.split(separator: "/").map(String.init)
      func query(_ key: String) -> String? { url.queryItems?.first(where: { $0.name == key })?.value }
      if request.method == "GET" {
        switch path {
        case "/v1/execution": return try .json(descriptor)
        case "/v1/execution/providers": return try .json(commands.providers().filter { $0.id.hasPrefix("local:") })
        case "/v1/execution/conversations": return try .json(try await localConversations())
        case "/v1/execution/interactions": return try .json(try await localPendingInteractions())
        case "/v1/execution/events":
          if let events {
            guard let cursor = Int64(query("after") ?? "0"), cursor >= 0 else { return .error("invalid_cursor", "Invalid execution history cursor.", status: 400) }
            return try .json(try await events(cursor))
          }
          // This Mac's library already holds these records: it advertises
          // history.library.v1, and members read the library change feed instead.
          guard query("after") == nil || query("after") == "0" else { return .error("invalid_cursor", "This Mac's history comes from the library change feed.", status: 400) }
          return try .json(ExecutionJournalPage(libraryID: descriptor.libraryID, cursor: 0))
        default: break
        }
        if parts.count == 4, parts[2] == "attachments" { return try await attachment(contentHash: parts[3], name: query("name")) }
        if parts.count == 4, parts[2] == "commands" {
          guard let receipt = try await localReceipt(commandID: parts[3], deviceID: scope.deviceID) else { return .error("not_found", "No receipt exists for this command.", status: 404) }
          return try .json(receipt)
        }
        if parts.count == 5, parts[2] == "conversations" {
          try await requireLocal(parts[3])
          if parts[4] == "transcript" { return try .json(try await commands.transcript(conversationID: parts[3], before: query("before"))) }
          if parts[4] == "capabilities" { return try .json(try await commands.sessionCapabilities(conversationID: parts[3])) }
          if parts[4] == "activity" {
            return try .json(try await database.libraryActivityDetails(conversationID: parts[3], runID: query("run"), activityID: query("id") ?? ""))
          }
        }
      } else if request.method == "POST" {
        if path == "/v1/execution/commands" {
          let command = try JSONDecoder().decode(LibraryCommand.self, from: request.body)
          guard command.deviceID == scope.deviceID, command.libraryID == scope.libraryID, command.workspaceID == scope.workspaceID else { return .error("wrong_workspace", "Command identity does not match its authenticated execution scope.", status: 403) }
          return try .json(try await executeLocal(command, deviceID: scope.deviceID, authorize: authorize))
        }
        if path == "/v1/execution/workspace-read" {
          let read = try JSONDecoder().decode(LibraryWorkspaceRead.self, from: request.body)
          switch read {
          case .session(let id), .exportConversation(let id, _): try await requireLocal(id)
          default: throw LibraryAPIError(code: "unsupported", message: "Shared app data syncs through the library.")
          }
          return try .json(try await commands.readWorkspace(read))
        }
      }
      return .error("not_found", "Unknown execution endpoint.", status: 404)
    } catch let error as LibraryAPIError {
      let status = error.code == "unauthorized" ? 401 : ["wrong_workspace", "execution_disabled"].contains(error.code) ? 403 : 400
      return .error(error.code, error.message, status: status)
    } catch is DecodingError { return .error("invalid_request", "Invalid execution request.", status: 400) }
    catch { return .error("execution_error", "The Mac could not complete this execution request. Check its receipt before retrying.", status: 500) }
  }
  /// The conversations this Mac runs, named as this workspace's.
  public func localConversations() async throws -> [LibraryConversation] {
    try await database.librarySnapshot(bodyByteBudget: 0).conversations.filter(isLocal).map { value in
      var copy = value; copy.workspaceID = descriptor.id; copy.libraryID = descriptor.libraryID; return copy
    }
  }
  /// The named conversations that this Mac runs; any other is absent.
  public func localConversations(ids: Set<String>) async throws -> [String: LibraryConversation] {
    try await database.libraryConversations(ids: ids).filter { isLocal($0.value) }.mapValues { value in
      var copy = value; copy.workspaceID = descriptor.id; copy.libraryID = descriptor.libraryID; return copy
    }
  }
  public func localPendingInteractions() async throws -> [PendingInteraction] {
    let pending = await commands.pendingInteractions()
    let local = try await database.libraryConversations(ids: Set(pending.map(\.conversationID))).filter { isLocal($0.value) }
    return pending.filter { local[$0.conversationID] != nil }
  }
  public func localTranscript(conversationID: String, before: String? = nil) async throws -> LibraryTranscript {
    try await requireLocal(conversationID)
    return try await commands.transcript(conversationID: conversationID, before: before)
  }
  public func localCapabilities(conversationID: String) async throws -> HarnessCapabilities {
    try await requireLocal(conversationID)
    return try await commands.sessionCapabilities(conversationID: conversationID)
  }
  /// The session settings, as `POST v1/execution/workspace-read` `.session` answers them.
  public func localSessionSettings(conversationID: String) async throws -> SessionSettings {
    try await requireLocal(conversationID)
    guard case .session(let settings) = try await commands.readWorkspace(.session(id: conversationID)) else {
      throw LibraryAPIError(code: "unsupported", message: "This Mac read no settings for this session.")
    }
    return settings
  }
  public func localReceipt(commandID: String, deviceID: String) async throws -> LibraryCommandReceipt? {
    guard let receipt = try await commands.receipt(commandID: commandID, deviceID: deviceID) else { return nil }
    if let id = receipt.conversationID { try await requireLocal(id) }
    return scoped(receipt)
  }
  /// `POST v1/execution/commands` once the caller is authenticated: only agents
  /// this Mac runs, with the shared idempotent command receipts. The stream's
  /// `execution.command` uses the same path.
  public func executeLocal(_ command: LibraryCommand, deviceID: String,
                           authorize: @MainActor () async throws -> Void = {}) async throws -> LibraryCommandReceipt {
    guard command.deviceID == deviceID, command.libraryID == descriptor.libraryID, command.workspaceID == descriptor.id else {
      throw LibraryAPIError(code: "wrong_workspace", message: "Command identity does not match its authenticated execution scope.")
    }
    if let route = command.routeID, !route.hasPrefix("local:") { throw notLocal }
    if let provider = command.providerID, !provider.hasPrefix("local:") { throw notLocal }
    if command.kind == .createSession {
      guard let route = command.providerID ?? command.routeID, route.hasPrefix("local:"),
            commands.providers().contains(where: { $0.id == route }) else { throw notLocal }
    } else if command.kind == .workspace {
      guard let action = command.workspaceAction else { throw notLocal }
      switch action {
      case .goal(let id, _), .conversation(let id, _, _, _), .configureSession(let id, _, _, _), .sessionTools(let id, _, _): try await requireLocal(id)
      default: throw LibraryAPIError(code: "unsupported", message: "This app-data change syncs through the library.")
      }
    } else {
      guard let id = command.conversationID else { throw notLocal }
      try await requireLocal(id)
    }
    try await authorize()
    return scoped(try await commands.execute(command, deviceID: deviceID))
  }
  /// `GET v1/execution/attachments/<sha256>?name=`: a message file of a
  /// session this Mac runs, from this library's attachment store, with the
  /// type it was sent with. Nothing outside that store is read, and only
  /// bytes that still match the digest are served.
  func attachment(contentHash: String, name: String?) async throws -> LibraryHTTPResponse {
    guard LibraryAttachmentReference.isDigest(contentHash) else {
      return .error("invalid_request", "An attachment is named by its SHA-256 digest.", status: 400)
    }
    // The named file first, then any other message of a local session that carries these bytes.
    let rows = try await database.messageAttachmentRows(contentHash: contentHash).sorted { ($0.fileName == name ? 0 : 1) < ($1.fileName == name ? 0 : 1) }
    var owned: String?
    for row in rows {
      guard (try? await requireLocal(row.conversationID)) != nil else { continue }
      owned = row.mimeType; break
    }
    guard let owned else { return .error("not_found", "This attachment is not in a session this Mac runs.", status: 404) }
    let files = database.libraryFiles
    let data: Data
    do { data = try await Task.detached { try files.messageAttachment(contentHash: contentHash) }.value }
    catch AgentMessageAttachmentError.fileTooLarge { return .error("too_large", "The attachment is larger than the 25 MB limit.", status: 413) }
    catch AgentMessageAttachmentError.unsupportedForAgent(let message) { return .error("conflict", message, status: 409) }
    catch { return .error("not_found", "This attachment is not on this Mac.", status: 404) }
    return .init(status: 200, contentType: Self.attachmentType(owned),
                 headers: ["Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"], body: data)
  }
  nonisolated static func attachmentType(_ value: String) -> String {
    let lowered = value.lowercased()
    return lowered.wholeMatch(of: /[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}/) != nil ? lowered : "application/octet-stream"
  }
  public var workspaceDescriptor: ExecutionWorkspace { descriptor }
  public var isServing: Bool { isActive() }

  private var notLocal: LibraryAPIError { .init(code: "wrong_workspace", message: "This endpoint can only control agents executing on this Mac.") }
  private func isLocal(_ value: LibraryConversation) -> Bool { Self.runsLocally(value) }
  /// A conversation this Mac runs: a local agent's, not one synchronized from another machine.
  public nonisolated static func runsLocally(_ value: LibraryConversation) -> Bool {
    value.workspaceID == nil && (value.routeID ?? value.providerID)?.hasPrefix("local:") == true
  }
  private func requireLocal(_ id: String) async throws {
    guard let value = try await database.libraryConversations(ids: [id])[id], isLocal(value) else { throw notLocal }
  }
  private func scoped(_ receipt: LibraryCommandReceipt) -> LibraryCommandReceipt {
    var value = receipt; value.libraryID = descriptor.libraryID; value.workspaceID = descriptor.id; return value
  }
}

extension WorkspaceDatabase {
  /// The messages that carry a file, by its SHA-256.
  func messageAttachmentRows(contentHash: String) async throws -> [(conversationID: String, fileName: String, mimeType: String)] {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("""
          SELECT conversation_id, file_name, mime_type FROM message_attachments
          WHERE content_hash = ? ORDER BY created_at, id LIMIT 64
          """, values: [contentHash])
      }.compactMap { row in
        guard let value = row.objectValue, let conversation = value["conversation_id"]?.stringValue else { return nil }
        return (conversation, value["file_name"]?.stringValue ?? "", value["mime_type"]?.stringValue ?? "")
      }
    }
  }
}
