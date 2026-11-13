import Foundation
import WovenMatterCore

/// Host services a tool call may need beyond the library database. The Mac app
/// supplies all of them; a headless library host leaves the session, usage,
/// executor and automation handlers unset, and note edits then go straight to
/// the database (`readNoteForEditing` / `applyNoteEdits`), as the Mac does
/// after saving drafts.
public struct WorkspaceToolHandlers: Sendable {
  public typealias Session = @Sendable (String, WovenMatterToolCommand, WovenMatterToolRequest) async throws -> WovenMatterToolResponse
  public typealias Note = @Sendable (String, NoteEditingRequest, String) async throws -> NoteEditingResponse
  public typealias NoteRestore = @Sendable (String, String, String, String, String) async throws -> NoteEditingResponse
  public typealias Usage = @Sendable (WovenMatterToolCommand) async throws -> WovenMatterToolResponse
  public typealias CalendarTask = @Sendable (String, WovenMatterToolCommand, WorkspaceCalendarTask?) async throws -> WorkspaceCalendarTask
  public typealias ReplicaRead = @Sendable (WovenMatterToolRequest, WovenMatterToolCommand, String) async throws -> WovenMatterToolResponse?

  public var session: Session?
  public var note: Note?
  public var noteRestore: NoteRestore?
  public var usage: Usage?
  public var calendarTask: CalendarTask?
  public var calendarProjection: (@Sendable () async throws -> Void)?
  public var replicaRead: ReplicaRead?
  public var automation: Session?
  public var executor: Session?
  /// A session another member's workspace runs (one this caller created there,
  /// or one named with `workspace`): `status`, `list`, `send`, `stop` and
  /// `respond` go to that workspace. Nil means this workspace handles it.
  public var memberSession: ReplicaRead?
  /// Runs after every admitted call, before its response is returned.
  public var afterExecution: @Sendable () async throws -> Void

  public init(session: Session? = nil, note: Note? = nil, noteRestore: NoteRestore? = nil, usage: Usage? = nil,
              calendarTask: CalendarTask? = nil, calendarProjection: (@Sendable () async throws -> Void)? = nil,
              replicaRead: ReplicaRead? = nil, automation: Session? = nil, executor: Session? = nil,
              afterExecution: @escaping @Sendable () async throws -> Void = {}) {
    self.session = session; self.note = note; self.noteRestore = noteRestore; self.usage = usage
    self.calendarTask = calendarTask; self.calendarProjection = calendarProjection; self.replicaRead = replicaRead
    self.automation = automation; self.executor = executor; self.afterExecution = afterExecution
  }
}

/// Executes Woven tool requests against one library database. The Mac app's
/// `WorkspaceAgentToolsModel` and the headless `wovenmatter-library` host share
/// this code, so notes, history, calendar, library and artifact tools behave
/// identically on every machine.
public struct WorkspaceToolExecutor: Sendable {
  /// The largest `after` cursor a tool takes or returns, and the newest-first
  /// start. Results carry numbers as Double, and JavaScript callers parse them
  /// as one, so a larger cursor (such as Int64.max) would come back rounded,
  /// as 9.223372036854776e+18. Row sequences never come near it.
  public static let maximumCursor = 9_007_199_254_740_991
  public let database: WorkspaceDatabase
  public init(database: WorkspaceDatabase) { self.database = database }

  public func execute(_ request: WovenMatterToolRequest, callerID: String,
                      handlers: WorkspaceToolHandlers) async -> WovenMatterToolResponse {
    var parsedCommand: WovenMatterToolCommand?
    do {
      guard request.schemaVersion == 1, let requestUUID = UUID(uuidString: request.requestID) else {
        throw WorkspaceToolError.invalid("Unsupported tool request.")
      }
      var request = request
      request.requestID = requestUUID.uuidString.lowercased()
      let command = try WovenMatterToolCommand(request.arguments)
      guard try JSONEncoder().encode(request).count <= request.maximumEncodedBytes else {
        throw WorkspaceToolError.invalid("This tool request exceeds its size limit.")
      }
      parsedCommand = command
      if request.targetSessionID != nil, !WovenMCPCaller.isAppWide(callerID) {
        throw WorkspaceToolError.invalid("Conversation callers cannot choose another chat as their tool identity.")
      }
      if let suppliedRequestID = command.options["request-id"] {
        guard let suppliedUUID = UUID(uuidString: suppliedRequestID),
              suppliedUUID.uuidString.lowercased() == request.requestID else {
          throw WorkspaceToolError.invalid("--request-id must match the request envelope.")
        }
      }
      if command.action == "context", WovenMCPCaller.isAppWide(callerID) {
        try await database.requireTool(.notes, sessionID: callerID)
        return .init(result: .null, requestID: request.requestID)
      }
      if command.action == "context" {
        let id = try await database.inputContext(id: request.contextID, callerID: callerID)
        return .init(result: id.map(GatewayJSONValue.string) ?? .null, requestID: request.requestID)
      }
      guard let group = command.group else { throw WorkspaceToolError.invalid("Choose a tool.") }
      // Scoped history reads have their own independent attachment/management
      // checks. All other commands require the group's current capability.
      if group != .history && !(group.isAutomation && command.action == "cancel") {
        try await database.requireTool(group, sessionID: callerID)
      }
      let result: WovenMatterToolResponse
      if group == .sessions, ["list", "status", "send", "stop", "respond"].contains(command.action),
         let member = try await handlers.memberSession?(request, command, callerID) { result = member }
      else if let replica = try await handlers.replicaRead?(request, command, callerID) { result = replica }
      else { switch group {
      case .history:
        result = .init(result: try await database.queryAgentHistory(Self.historyQuery(command), callerID: callerID,
          allWorkspace: command.options["all-workspace"] != nil))
      case .notes:
        if command.isDatabaseCommand { result = try await Self.require(handlers.session, "Agent databases are unavailable on this host.")(callerID, command, request) }
        else if command.isPageCommand { result = try await pages(command, request: request, callerID: callerID, handlers: handlers) }
        else { result = try await notes(command, request: request, callerID: callerID, handlers: handlers) }
      case .sessions:
        if command.action == "list" || command.action == "status" {
          var query = try Self.historyQuery(command)
          query.command = "conversations"
          if command.action == "status" { query.id = try command.required("id", allowPositional: true) }
          var page = try await database.queryAgentHistory(query, callerID: callerID,
            allWorkspace: command.options["all-workspace"] != nil)
          if command.action == "status", var object = page.objectValue, let id = query.id {
            guard object["rows"]?.arrayValue?.isEmpty == false else {
              throw WorkspaceToolError.notFound("The requested session was not found.")
            }
            object["relationship"] = try WovenMatterToolResponse.value(
              await database.sessionRelationship(id)).result ?? .null
            page = .object(object)
          }
          result = .init(result: page)
        } else if command.action == "folders" {
          result = .init(result: try await database.listAgentFolders(callerID: callerID,
            after: Int64(command.integer("after", default: 0, range: 0...WorkspaceToolExecutor.maximumCursor)),
            limit: command.integer("limit", default: 100, range: 1...200)))
        } else { result = try await Self.require(handlers.session, "Session management is unavailable on this host.")(callerID, command, request) }
      case .goals: result = try await goal(command, callerID: callerID, requestID: request.requestID, targetID: request.targetSessionID)
      case .timers: result = try await timer(command, callerID: callerID, requestID: request.requestID, targetID: request.targetSessionID)
      case .calendar:
        try await handlers.calendarProjection?()
        result = try await calendar(command, callerID: callerID, requestID: request.requestID, calendarTask: handlers.calendarTask)
        if command.isMutation, result.success { try await handlers.calendarProjection?() }
      case .usage: result = try await Self.require(handlers.usage, "Usage data is unavailable on this host.")(command)
      case .library: result = try await library(command, callerID: callerID)
      case .html:
        if command.action == "call" {
          let input = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(command.required("json").utf8))
          guard let object = input.objectValue, let html = object["html"]?.stringValue,
                let action = object["action"]?.stringValue, ["preview", "render"].contains(action) else {
            throw WorkspaceToolError.invalid("Provide an HTML render or preview action.")
          }
          let allowed: Set<String> = action == "render" ? ["action", "html", "title", "height"] : ["action", "html", "width", "appearance", "missingImages"]
          guard Set(object.keys).isSubset(of: allowed) else { throw WorkspaceToolError.invalid("Unknown HTML parameter.") }
          let page = try ConversationHTMLPage(html: html, title: object["title"]?.stringValue ?? "HTML preview",
            height: object["height"]?.intValue ?? 400)
          if action == "render" {
            guard object["title"]?.stringValue != nil, object["height"]?.intValue != nil else {
              throw WorkspaceToolError.invalid("Rendering requires a title and integer height.")
            }
            let reference = try await database.publishConversationHTML(page, callerID: callerID, requestID: request.requestID, targetID: request.targetSessionID)
            result = .init(result: .object([
              "htmlRender": try WovenMatterToolResponse.value(reference).result ?? .null,
              "message": .string("Shown above your reply. Reply with only what the page does not already say.")
            ]))
          } else {
            guard let automationHandler = handlers.automation else { throw WorkspaceToolError.invalid("Open Woven Matter to preview HTML.") }
            result = try await automationHandler(callerID, command, request)
          }
        } else {
          guard let automationHandler = handlers.automation else { throw WorkspaceToolError.invalid("The HTML preview host is unavailable.") }
          result = try await automationHandler(callerID, command, request)
        }
      case .executor:
        guard let executorHandler = handlers.executor else { throw WorkspaceToolError.invalid("Executor manager is unavailable.") }
        result = try await executorHandler(callerID, command, request)
      case .browser, .computer:
        guard let automationHandler = handlers.automation else { throw WorkspaceToolError.invalid("Open Woven Matter to use browser and computer tools.") }
        result = try await automationHandler(callerID, command, request)
      }
      }
      if command.isMutation {
        try await recordMCPMutation(command: command, callerID: callerID, requestID: request.requestID,
          success: result.success, code: result.code)
      }
      try await handlers.afterExecution()
      return .init(success: result.success, result: result.result, error: result.error,
        code: result.code, silent: result.silent, requestID: request.requestID)
    } catch {
      let code = Self.errorCode(error)
      if let command = parsedCommand, command.isMutation {
        let canonicalID = UUID(uuidString: request.requestID)?.uuidString.lowercased() ?? request.requestID
        try? await recordMCPMutation(command: command, callerID: callerID, requestID: canonicalID,
          success: false, code: code)
      }
      return .init(success: false, error: error.localizedDescription, code: code,
        requestID: UUID(uuidString: request.requestID)?.uuidString.lowercased() ?? request.requestID)
    }
  }

  private static func require<T>(_ handler: T?, _ message: String) throws -> T {
    guard let handler else { throw WorkspaceToolError.invalid(message) }
    return handler
  }

  private func recordMCPMutation(command: WovenMatterToolCommand, callerID: String,
                                 requestID: String, success: Bool, code: String?) async throws {
    var payload: [String: String] = [
      "group": command.group?.rawValue ?? "unknown", "action": command.action,
      "requestID": requestID, "success": success ? "true" : "false"
    ]
    if let code { payload["code"] = code }
    try await database.recordHistory(.init(conversationID: callerID, harness: "wovenmatter",
      kind: "mcp.mutation", payload: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)))
  }

  public static func errorCode(_ error: any Error) -> String {
    if let error = error as? WorkspaceToolError {
      switch error {
      case .disabled: return "tool_disabled"
      case .accessRequired: return "access_required"
      case .coordinationConflict: return "coordination_conflict"
      case .managedLimit: return "managed_limit"
      case .atCapacity: return "at_capacity"
      case .notFound: return "not_found"
      case .revisionRequired: return "revision_required"
      case .revisionConflict: return "revision_conflict"
      case .timerPauseConfirmation: return "confirmation_required"
      case .invalid: return "invalid_request"
      }
    }
    if let error = error as? WorkspaceNoteMutationError {
      switch error {
      case .folderNotFound, .noteNotFound: return "not_found"
      case .revisionConflict: return "revision_conflict"
      }
    }
    if let error = error as? NoteEditError {
      switch error {
      case .blockNotFound, .tableNotFound, .pageTargetMissing: return "not_found"
      case .boardItemConflict, .pageSubtreeConflict: return "revision_conflict"
      default: return "invalid_request"
      }
    }
    if let error = error as? ArtifactStateError {
      if case .conflict = error { return "revision_conflict" }
      return "invalid_request"
    }
    if error is NoteDocumentSafetyError || error is RemoteNoteEditError { return "invalid_request" }
    if error is CancellationError { return "cancelled" }
    return "operation_failed"
  }

  public static func historyQuery(_ command: WovenMatterToolCommand) throws -> WorkspaceHistoryQuery {
    var query = WorkspaceHistoryQuery(command: command.action)
    if command.action == "search" { query.search = try command.required("search", allowPositional: true) }
    else { query.id = command.options["id"] ?? command.positional.first; query.search = command.options["search"] }
    query.conversationID = command.options["conversation"]
    query.runID = command.options["run"]
    query.harness = command.options["harness"]
    query.sourceID = command.options["source-id"]
    query.nativeSessionID = command.options["native-session-id"]
    query.nativeRecordID = command.options["native-record-id"]
    query.nativeConversationID = command.options["native-conversation-id"]
    query.folderID = command.options["folder"]
    query.kind = command.options["kind"]
    query.since = command.options["since"]
    query.until = command.options["until"]
    query.sort = command.options["sort"] ?? (command.action == "conversations" ||
      (command.group == .sessions && command.action == "list") ? "newest" : "oldest")
    let initialCursor = query.sort == "newest" ? WorkspaceToolExecutor.maximumCursor : 0
    query.after = Int64(try command.integer("after", default: initialCursor, range: 0...WorkspaceToolExecutor.maximumCursor))
    query.limit = try command.integer("limit", default: 50, range: 1...200)
    query.offset = try command.integer("offset", default: 0, range: 0...(Int.max - 1))
    query.characters = try command.integer("characters", default: 65_536, range: 1...65_536)
    return query
  }

  private func notes(_ command: WovenMatterToolCommand, request: WovenMatterToolRequest, callerID: String,
                     handlers: WorkspaceToolHandlers) async throws -> WovenMatterToolResponse {
    switch command.action {
    case "list":
      let newest = (command.options["sort"] ?? "newest") == "newest"
      let initialCursor = newest ? WorkspaceToolExecutor.maximumCursor : 0
      return .init(result: try await database.listAgentNotes(callerID: callerID, search: command.options["search"], folderID: command.options["folder"],
        after: Int64(try command.integer("after", default: initialCursor, range: 0...WorkspaceToolExecutor.maximumCursor)),
        limit: try command.integer("limit", default: 50, range: 1...200), newestFirst: newest))
    case "folders":
      return .init(result: try await database.listAgentFolders(callerID: callerID, requiredTool: .notes,
        after: Int64(command.integer("after", default: 0, range: 0...WorkspaceToolExecutor.maximumCursor)),
        limit: command.integer("limit", default: 100, range: 1...200)))
    case "create":
      guard let kind = NoteArtifactKind(rawValue: command.options["kind"] ?? "note"), kind != .canvas else {
        throw WorkspaceToolError.invalid("Choose note, spreadsheet or html. Use woven_pages_create for a Page.")
      }
      let id = try await database.createNote(folderID: command.options["folder"], title: command.required("title"), kind: kind, callerConversationID: callerID, requestID: request.requestID)
      return .init(result: .object(["id": .string(id)]))
    case "versions", "version":
      var query = try Self.historyQuery(command)
      query.id = command.options[command.action == "versions" ? "note-id" : "version"]
        ?? command.options["id"] ?? command.positional.first
      return .init(result: try await database.queryAgentHistory(query, callerID: callerID))
    case "restore":
      let restore = handlers.noteRestore ?? { [database] caller, noteID, versionID, revision, requestID in
        try await database.restoreNoteAssetVersion(noteID: noteID, versionID: versionID,
          expectedRevision: revision, callerConversationID: caller, requestID: requestID)
      }
      return try Self.noteMutationAcknowledgement(await restore(callerID,
        command.required("note-id", allowPositional: true), command.required("version"),
        command.required("revision"), request.requestID))
    case "artifact-state":
      let response = try await noteEditor(handlers)(callerID, .init(command: .read, noteID: command.required("note-id")), request.requestID)
      guard let document = response.document, document.kind == .html else { throw ArtifactStateError.notArtifact }
      return .init(result: .object(["id": .string(response.noteID),
        "revision": response.revision.map(GatewayJSONValue.string) ?? .null,
        "state": try WovenMCPCatalog.json(document.artifactStateSnapshot)]))
    case "artifact-state-edit":
      let edit = try NoteToolEdits.request(command)
      do {
        let response = try await noteEditor(handlers)(callerID, edit, request.requestID)
        var object = try Self.noteMutationAcknowledgement(response).result?.objectValue ?? [:]
        // A replay carries only its acknowledgement, never another copy of the state.
        if let document = response.document { object["state"] = try WovenMCPCatalog.json(document.artifactStateSnapshot) }
        return .init(success: response.success, result: .object(object), error: response.error,
          code: response.success ? nil : "mutation_failed")
      } catch ArtifactStateError.conflict(let key, let current) {
        // The failed transaction changed nothing, so this is current state to act on.
        var object: [String: GatewayJSONValue] = ["id": .string(edit.noteID), "key": .string(key),
          "currentVersion": .number(Double(current?.version ?? 0))]
        if let value = current?.value { object["currentValue"] = value }
        let message = ArtifactStateError.conflict(key: key, current: current).localizedDescription
        return .init(success: false, result: .object(object), error: message, code: "revision_conflict")
      }
    default:
      let edit = try NoteToolEdits.request(command)
      let response = try await noteEditor(handlers)(callerID, edit, request.requestID)
      if command.action == "read" {
        return try Self.noteReadChunk(response,
          offset: command.integer("offset", default: 0, range: 0...(Int.max - 1)),
          characters: command.integer("characters", default: 65_536, range: 1...65_536))
      }
      return try Self.noteMutationAcknowledgement(response)
    }
  }

  /// The host's note editor (which saves open drafts first on the Mac), or the
  /// database directly on a headless library host.
  private func noteEditor(_ handlers: WorkspaceToolHandlers) -> WorkspaceToolHandlers.Note {
    handlers.note ?? { [database] caller, edit, requestID in
      switch edit.command {
      case .read: try await database.readNoteForEditing(id: edit.noteID, callerConversationID: caller)
      case .apply: try await database.applyNoteEdits(edit, callerConversationID: caller, requestID: requestID)
      }
    }
  }

  private func pages(_ command: WovenMatterToolCommand, request: WovenMatterToolRequest, callerID: String,
                     handlers: WorkspaceToolHandlers) async throws -> WovenMatterToolResponse {
    let note = noteEditor(handlers)
    switch command.action {
    case "page-list":
      return .init(result: try await database.listAgentPages(callerID: callerID, search: command.options["search"], folderID: command.options["folder"],
        after: Int64(try command.integer("after", default: WorkspaceToolExecutor.maximumCursor, range: 0...WorkspaceToolExecutor.maximumCursor)),
        limit: try command.integer("limit", default: 50, range: 1...200)))
    case "page-create":
      let content = try PageTool.newPageContent(purpose: command.options["purpose"])
      let id = try await database.createNote(folderID: command.options["folder"], title: command.required("title"), content: content, kind: .canvas,
        callerConversationID: callerID, requestID: request.requestID)
      return .init(result: .object(["id": .string(id), "kind": .string("page")]))
    case "page-read":
      let filter = try BoardReadFilter(command: command)
      let (document, response) = try await readPage(command.required("note-id"), callerID: callerID, requestID: request.requestID, note: note)
      let assets = try await database.boardAssetSummaries(callerID: callerID, ids: document.boardAssetIDs(filter: filter))
      return .init(result: try document.pageReadValue(id: response.noteID, title: response.title ?? "",
        revision: response.revision ?? "", filter: filter, assets: assets))
    default:
      let edit = try PageTool.request(command, requestID: request.requestID)
      let componentID = command.action == "page-add-component" ? request.requestID : command.options["id"]
      do {
        let response = try await note(callerID, edit, request.requestID)
        return try await pageAcknowledgement(response, componentID: componentID, callerID: callerID)
      } catch let error where PageTool.conflictComponent(error) != nil {
        return await pageConflict(pageID: edit.noteID, componentID: PageTool.conflictComponent(error)!, callerID: callerID, requestID: request.requestID, note: note)
      } catch WorkspaceNoteMutationError.revisionConflict {
        return await pageConflict(pageID: edit.noteID, componentID: nil, callerID: callerID, requestID: request.requestID, note: note)
      } catch NoteEditError.artifactKindMismatch {
        throw WorkspaceToolError.invalid("This asset is not a Page. Use the woven_notes tools.")
      } catch RemoteNoteEditError.operationNotAllowed {
        // Also thrown for an invalid block on a real Page, which needs its own message.
        guard (try? await readPage(edit.noteID, callerID: callerID, requestID: request.requestID, note: note)) != nil else {
          throw WorkspaceToolError.invalid("This asset is not a Page. Use the woven_notes tools.")
        }
        throw WorkspaceToolError.invalid("This component is not valid for a Page. Check its size, table shape and links.")
      }
    }
  }

  private func readPage(_ id: String, callerID: String, requestID: String,
                        note: WorkspaceToolHandlers.Note) async throws -> (NoteDocument, NoteEditingResponse) {
    let response = try await note(callerID, .init(command: .read, noteID: id), requestID)
    guard let document = response.document, document.kind == .canvas else {
      throw WorkspaceToolError.invalid("This asset is not a Page. Use woven_notes_read.")
    }
    return (document, response)
  }

  /// A replay acknowledges the original revision; it never returns old contents.
  private func pageAcknowledgement(_ response: NoteEditingResponse, componentID: String?, callerID: String) async throws -> WovenMatterToolResponse {
    let assets = try await database.boardAssetSummaries(callerID: callerID, ids: PageTool.linkedAssetIDs(response.document, componentID: componentID))
    let result = try PageTool.acknowledgement(pageID: response.noteID, title: response.title, revision: response.revision,
      replayed: response.replayed == true, componentID: componentID, document: response.document, assets: assets)
    return .init(success: response.success, result: result, error: response.error,
      code: response.success ? nil : "mutation_failed")
  }

  /// Reports the current Page after a conflicting write, which changed nothing.
  private func pageConflict(pageID: String, componentID: String?, callerID: String, requestID: String,
                            note: WorkspaceToolHandlers.Note) async -> WovenMatterToolResponse {
    let stored = try? await readPage(pageID, callerID: callerID, requestID: requestID, note: note)
    let ids = stored.map { PageTool.linkedAssetIDs($0.0.materializedPage(), componentID: componentID) } ?? []
    let assets = (try? await database.boardAssetSummaries(callerID: callerID, ids: ids)) ?? [:]
    return PageTool.conflict(pageID: pageID, componentID: componentID, stored: stored?.0, revision: stored?.1.revision, assets: assets)
  }

  private static func noteMutationAcknowledgement(_ response: NoteEditingResponse) throws -> WovenMatterToolResponse {
    var object: [String: GatewayJSONValue] = ["id": .string(response.noteID)]
    object["title"] = response.title.map(GatewayJSONValue.string) ?? .null
    object["revision"] = response.revision.map(GatewayJSONValue.string) ?? .null
    object["replayed"] = .bool(response.replayed == true)
    return .init(success: response.success, result: .object(object), error: response.error,
      code: response.success ? nil : "mutation_failed")
  }

  private static func noteReadChunk(_ response: NoteEditingResponse, offset: Int,
                                    characters: Int) throws -> WovenMatterToolResponse {
    guard response.success, let document = response.document else {
      return .init(success: false, error: response.error ?? "The note could not be read.", code: "read_failed")
    }
    let content = try document.encoded()
    let actualOffset = min(offset, content.count)
    let start = content.index(content.startIndex, offsetBy: actualOffset)
    let end = content.index(start, offsetBy: min(characters, content.distance(from: start, to: content.endIndex)))
    let next = content.distance(from: content.startIndex, to: end)
    return .init(result: .object([
      "id": .string(response.noteID),
      "title": response.title.map(GatewayJSONValue.string) ?? .null,
      "revision": response.revision.map(GatewayJSONValue.string) ?? .null,
      "kind": .string(document.kind.rawValue),
      "content": .string(String(content[start..<end])),
      "contentCharacters": .number(Double(content.count)),
      "offset": .number(Double(actualOffset)),
      "hasMore": .bool(next < content.count),
      "nextOffset": .number(Double(next))
    ]))
  }

  private func goal(_ command: WovenMatterToolCommand, callerID: String, requestID: String, targetID: String? = nil) async throws -> WovenMatterToolResponse {
    let target = WovenMCPCaller.isAppWide(callerID) ? targetID ?? callerID : callerID
    guard !WovenMCPCaller.isAppWide(target) else { throw WorkspaceToolError.invalid("App-wide callers must supply sessionID for goals.") }
    if command.action == "get" {
      return try .value(await database.sessionGoals().first { $0.sessionID == target })
    }
    let mutation: WorkspaceGoalMutation
    if command.action == "set" {
      let tokens = try command.options["token-budget"].map { _ in Int64(try command.integer("token-budget", default: 1, range: 1...1_000_000_000)) }
      let turns = try command.options["turn-budget"].map { _ in try command.integer("turn-budget", default: 1, range: 1...10_000) }
      mutation = .set(objective: try command.required("objective"), tokenBudget: tokens, turnBudget: turns)
    } else {
      let id = try command.required("id")
      switch command.action {
      case "pause": mutation = .pause(id: id)
      case "resume": mutation = .resume(id: id)
      case "clear": mutation = .clear(id: id)
      case "complete": mutation = .complete(id: id, evidence: try command.required("evidence"))
      case "block": mutation = .block(id: id, evidence: try command.required("evidence"))
      case "checkpoint": mutation = .checkpoint(id: id, evidence: try command.required("evidence"))
      default: throw WorkspaceToolError.invalid("Unsupported goal operation.")
      }
    }
    return try .value(await database.mutateGoal(sessionID: target, mutation: mutation,
      callerID: callerID, requestID: requestID))
  }

  private func timer(_ command: WovenMatterToolCommand, callerID: String, requestID: String, targetID: String? = nil) async throws -> WovenMatterToolResponse {
    let target = targetID ?? command.options["session"] ?? callerID
    // A bot without a session sets its own timers: they are its schedules.
    if WovenMCPCaller.isAppWide(callerID), target == callerID, WovenMCPCaller.parseBot(callerID) == nil {
      throw WorkspaceToolError.invalid("App-wide callers must supply sessionID for timers.")
    }
    if target != callerID && !WovenMCPCaller.isAppWide(callerID) {
      try await database.requireTool(.sessions, sessionID: callerID)
      guard try await database.sessionRelationship(target).coordinatorID == callerID else { throw WorkspaceToolError.accessRequired(target) }
    }
    if command.action == "list" {
      return .init(result: try await database.querySessionTimers(callerID: callerID, sessionID: target,
        after: Int64(command.integer("after", default: 0, range: 0...WorkspaceToolExecutor.maximumCursor)),
        limit: command.integer("limit", default: 100, range: 1...200)))
    }
    if command.action == "create" || command.action == "update" {
      let id = command.action == "create" ? requestID : try command.required("id", allowPositional: true)
      let interval: Double?
      if let raw = command.options["every"] {
        guard let value = Double(raw) else { throw WorkspaceToolError.invalid("--every requires seconds.") }
        interval = value
      } else { interval = nil }
      let timer = WorkspaceSessionTimer(id: id, sessionID: target,
        instruction: try command.required("text"), nextFireAt: try Self.date(command.required("at")),
        intervalSeconds: interval, isPaused: command.options["paused"] != nil)
      return try await .value(database.saveSessionTimer(timer, callerID: callerID, requestID: requestID,
        creating: command.action == "create"))
    }
    let id = try command.required("id", allowPositional: true)
    if command.action == "remove" { try await database.removeSessionTimer(id: id, callerID: callerID, requestID: requestID) }
    else { try await database.pauseSessionTimer(id: id, paused: command.action == "pause", callerID: callerID, requestID: requestID) }
    return .init(result: .object(["id": .string(id), "status": .string(command.action)]))
  }

  public func library(_ command: WovenMatterToolCommand, callerID: String) async throws -> WovenMatterToolResponse {
    var query = LibraryQuery()
    query.search = command.options["search"] ?? ""
    if let workspace = command.options["workspace"] {
      query.workspaces = Set(workspace.split(separator: ",").map { String($0).lowercased() })
    }
    if let harness = command.options["harness"] {
      query.harnesses = Set(harness.split(separator: ",").map(String.init))
    }
    if let kind = command.options["kind"] {
      guard let value = LibraryItemKind(rawValue: kind) else { throw WorkspaceToolError.invalid("Use file, link, or photo.") }
      query.kind = value
    }
    if let sender = command.options["sender"] {
      guard let value = LibrarySender(rawValue: sender) else { throw WorkspaceToolError.invalid("Use me or agent.") }
      query.sender = value
    }
    query.since = try command.options["since"].map(Self.date)
    query.until = try command.options["until"].map(Self.date)
    if let since = query.since, let until = query.until, until < since {
      throw WorkspaceToolError.invalid("--until must be at or after --since.")
    }
    return .init(result: try await database.queryAgentLibrary(callerID: callerID,
      id: command.action == "read" ? try command.required("id", allowPositional: true) : nil,
      query: query, limit: command.integer("limit", default: 100, range: 1...200),
      offset: command.integer("offset", default: 0, range: 0...Int.max)))
  }

  public static func date(_ raw: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: raw) else { throw WorkspaceToolError.invalid("Use an ISO 8601 date with a time zone.") }
    return date
  }

  private func calendar(_ command: WovenMatterToolCommand, callerID: String, requestID: String,
                        calendarTask: WorkspaceToolHandlers.CalendarTask?) async throws -> WovenMatterToolResponse {
    if command.action == "list" {
      let since = try command.options["since"].map(Self.date)
      let until = try command.options["until"].map(Self.date)
      if let since, let until, until < since {
        throw WorkspaceToolError.invalid("--until must be at or after --since.")
      }
      return .init(result: try await database.listAgentCalendar(callerID: callerID,
        since: since, until: until,
        after: Int64(command.integer("after", default: 0, range: 0...WorkspaceToolExecutor.maximumCursor)),
        limit: command.integer("limit", default: 100, range: 1...200)))
    }
    if command.action == "read" || command.action == "occurrences" {
      let event = try await database.calendarEvent(id: command.required("id", allowPositional: true), callerID: callerID)
      if command.action == "read" {
        return .init(result: .object(["event": try WovenMatterToolResponse.value(event).result ?? .null,
          "runs": try await database.queryCalendarRuns(eventID: event.id,
            after: command.integer("after", default: 0, range: 0...WorkspaceToolExecutor.maximumCursor),
            limit: command.integer("limit", default: 100, range: 1...200))]))
      }
      let since = try Self.date(command.required("since")), until = try Self.date(command.required("until"))
      guard until > since, until.timeIntervalSince(since) <= 366 * 86_400 else {
        throw WorkspaceToolError.invalid("Choose an occurrence window of at most one year.")
      }
      let values = WorkspaceCalendarSchedule.occurrences(event, in: .init(start: since, end: until))
      let offset = try command.integer("after", default: 0, range: 0...WorkspaceToolExecutor.maximumCursor)
      let limit = try command.integer("limit", default: 100, range: 1...200)
      let page = Array(values.dropFirst(offset).prefix(limit))
      let next = offset + page.count
      return .init(result: .object(["rows": .array(page.map {
        .object(["eventID": .string(event.id), "occurrence": .number(Double($0.index)),
          "startsAt": .string(WorkspaceCalendarSchedule.timestamp($0.startsAt)),
          "endsAt": $0.endsAt.map { .string(WorkspaceCalendarSchedule.timestamp($0)) } ?? .null])
      }), "hasMore": .bool(next < values.count), "nextCursor": .number(Double(next))]))
    }
    let input = String(decoding: try JSONEncoder().encode(command.operationArguments), as: UTF8.self)
    if let id = try await database.replayCalendarRequest(callerID: callerID, requestID: requestID, input: input) {
      return .init(result: .object(["id": .string(id)]))
    }
    let creating = command.action == "create"
    let id = creating ? requestID : try command.required("id", allowPositional: true)
    let existing = creating ? nil : try await database.calendarEvent(id: id, callerID: callerID)
    let revision = try command.options["revision"].map { _ in try command.integer("revision", default: 0, range: 0...Int.max) }
    let occurrence = try command.options["occurrence"].map { _ in try command.integer("occurrence", default: 0, range: 0...Int.max) }
    if ["update", "remove", "detach"].contains(command.action), revision == nil {
      throw WorkspaceToolError.revisionRequired("This calendar operation requires --revision. Read the event again and pass its current revision.")
    }
    if command.action == "remove" {
      try await database.deleteCalendarEvent(id: id, occurrence: occurrence, expectedRevision: revision,
        callerID: callerID, requestID: requestID, requestInput: input)
      return .init(result: .object(["id": .string(id)]))
    }
    var draft = try existing.map(WorkspaceCalendarDraft.init) ?? .init(startsAt: Self.date(command.required("starts-at")))
    if let occurrence, let existing {
      guard let value = WorkspaceCalendarSchedule.occurrence(existing, index: occurrence) else { throw WorkspaceToolError.notFound("Occurrence not found.") }
      draft = value.draft
    }
    if let title = command.options["title"] { draft.title = title }
    if let details = command.options["description"] { draft.details = details }
    if let date = command.options["starts-at"] {
      let next = try Self.date(date)
      draft.endsAt = draft.endsAt.map { $0.addingTimeInterval(next.timeIntervalSince(draft.startsAt)) }
      draft.startsAt = next
    }
    if let date = command.options["ends-at"] { draft.endsAt = try Self.date(date) }
    if command.options["all-day"] != nil { draft.allDay = true }
    if command.options["timed"] != nil { draft.allDay = false }
    if let zone = command.options["time-zone"] { draft.timeZoneID = zone }
    if let raw = command.options["repeat-unit"] {
      guard let unit = WorkspaceCalendarRecurrence.Unit(rawValue: raw) else { throw WorkspaceToolError.invalid("Repeat units are day, week, or month.") }
      draft.recurrence = .init(unit: unit, interval: try command.integer("repeat-interval", default: 1, range: 1...365))
    } else if command.options["repeat-interval"] != nil {
      guard draft.recurrence != nil else { throw WorkspaceToolError.invalid("Choose --repeat-unit with --repeat-interval.") }
      draft.recurrence?.interval = try command.integer("repeat-interval", default: 1, range: 1...365)
    }
    if command.options["no-repeat"] != nil { draft.recurrence = nil }
    if command.options["regular-event"] != nil { draft.task = nil }
    else if draft.task != nil || command.options["prompt"] != nil {
      guard let calendarTask else { throw WorkspaceToolError.invalid("Scheduled session creation is unavailable.") }
      draft.task = try await calendarTask(callerID, command, draft.task)
    }
    var targetID = id
    var create = creating
    var detach: Int?
    if command.action == "detach" {
      guard let occurrence else { throw WorkspaceToolError.invalid("Choose the --occurrence to detach.") }
      detach = occurrence; draft.recurrence = nil
    } else if command.action == "copy" {
      _ = try command.required("starts-at")
      targetID = requestID; create = true; draft.recurrence = nil
    } else if occurrence != nil { throw WorkspaceToolError.invalid("Use detach to change a single recurring occurrence, or update without --occurrence to change the series.") }
    let saved = try await database.saveCalendarEvent(id: targetID, draft: draft, creating: create,
      expectedRevision: create ? nil : revision ?? existing?.calendar.revision, detaching: detach,
      callerID: callerID, requestID: requestID, requestInput: input)
    return .init(result: .object(["id": .string(saved)]))
  }
}

extension WorkspaceDatabase {
  /// Whether a tool caller exists, without loading the workspace overview.
  public func hasActiveConversation(_ id: String) async throws -> Bool {
    try await read { connection in
      try !connection.historyRowsUnlocked("SELECT id FROM dashboard_conversations WHERE id=? AND deleted_at IS NULL", values: [id]).isEmpty
    }
  }
}
