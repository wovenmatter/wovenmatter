import Foundation
import WovenMatterCompanion

extension MobileStore {
  /// Native MCP tools and sandboxed Python share this dispatcher. Permissions
  /// are checked on every call, including a retry of a previously successful write.
  public func executeLocalTool(_ request: WovenMatterToolRequest, context: MobileToolContext) async -> WovenMatterToolResponse {
    do {
      try Task.checkCancellation()
      guard request.schemaVersion == 1, let uuid = UUID(uuidString: request.requestID) else { throw WorkspaceToolError.invalid("Unsupported tool request.") }
      let command = try WovenMatterToolCommand(request.arguments)
      if let id = command.options["request-id"], UUID(uuidString: id) != uuid { throw WorkspaceToolError.invalid("--request-id must match the request envelope.") }
      try context.authorize(command)
      guard !command.wantsHelp else { throw WorkspaceToolError.invalid("Use a named Woven MCP tool with structured arguments.") }
      if command.action == "context" { return .init(result: request.contextID.map(GatewayJSONValue.string) ?? .null) }
      let key = context.sessionID + ":" + uuid.uuidString.lowercased()
      if command.isMutation, let receipt = state.toolReceipts?[key] {
        guard receipt.arguments == command.operationArguments else { throw WorkspaceToolError.invalid("This request ID was already used for a different operation.") }
        return receipt.response
      }
      let result: GatewayJSONValue
      switch command.group {
      case .notes:
        var response: GatewayJSONValue = .null
        // Receipt, version snapshot, note body, and sync outbox commit together.
        try transaction { next in
          response = try Self.notesTool(command, requestID: uuid.uuidString.lowercased(), context: context, state: &next)
          if command.isMutation {
            var receipts = next.toolReceipts ?? [:]
            receipts[key] = .init(requestID: uuid.uuidString.lowercased(), sessionID: context.sessionID, arguments: command.operationArguments,
              response: .init(result: response, requestID: uuid.uuidString.lowercased()))
            next.toolReceipts = receipts
            if let id = response.objectValue?["id"]?.stringValue { try enforceNoteBudget(&next, protecting: id) }
          }
        }
        result = response
      case .timers:
        var response: GatewayJSONValue = .null
        try transaction { next in
          response = try Self.timerTool(command, requestID: uuid.uuidString.lowercased(), context: context, state: &next)
          if command.isMutation {
            var receipts = next.toolReceipts ?? [:]
            receipts[key] = .init(requestID: uuid.uuidString.lowercased(), sessionID: context.sessionID, arguments: command.operationArguments,
              response: .init(result: response, requestID: uuid.uuidString.lowercased()))
            next.toolReceipts = receipts
          }
        }
        result = response
      case .history, .sessions:
        result = try Self.historyTool(command, context: context, state: state, journal: await journal.snapshot())
      case .library:
        result = try await libraryTool(command)
      case .usage:
        let from = try command.options["since"].map(MobileToolSupport.date) ?? .distantPast
        let to = try command.options["until"].map(MobileToolSupport.date) ?? Date()
        let samples = try DeviceUsageProjection.samples(in: await journal.snapshot(), workspaceID: context.workspaceID, from: from, to: to)
        result = .object(["records": try MobileToolSupport.page(samples.map(MobileToolSupport.value), command: command, offsetKey: "offset"), "accountLimits": .array([]), "accountLimitsAvailable": .bool(false)])
      default: throw WorkspaceToolError.invalid("This operation requires the device runtime adapter.")
      }
      return WovenMatterToolResponse(result: result, requestID: uuid.uuidString.lowercased()).bounded()
    } catch { return MobileToolSupport.response(error: error, requestID: request.requestID) }
  }

  private static func notesTool(_ command: WovenMatterToolCommand, requestID: String, context: MobileToolContext, state: inout MobileStoreState) throws -> GatewayJSONValue {
    let query = command.options["search"] ?? ""
    if command.action == "folders" { return try MobileToolSupport.page(state.folders.values.sorted { $0.id < $1.id }.map(MobileToolSupport.value), command: command) }
    if command.action == "list" {
      let rows = state.notes.values.filter { note in
        !state.deletedNotes.contains(note.id) && (query.isEmpty || note.title.localizedCaseInsensitiveContains(query) || note.content.localizedCaseInsensitiveContains(query)) && (command.options["folder"] == nil || command.options["folder"] == note.folderID)
      }.sorted { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
        return command.options["sort"] == "oldest" ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
      }
      return try MobileToolSupport.page(rows.map { note in .object(["id": .string(note.id), "title": .string(note.title), "revision": .string(try MobileToolSupport.fingerprint(note)), "kind": .string(note.kind?.rawValue ?? "note"), "cached": .bool(!state.uncachedNoteIDs.contains(note.id))]) }, command: command)
    }
    if command.action == "version" {
      let id = command.options["id"] ?? command.options["version"] ?? command.positional.first ?? ""
      guard let version = state.toolNoteVersions?.first(where: { $0.id == id }) else { throw WorkspaceToolError.notFound("This note version is not saved on this device.") }
      return try noteRead(version.note, command: command)
    }
    let id = command.action == "create" ? requestID : try command.required("note-id", allowPositional: true)
    if command.action == "create" {
      guard state.notes[id] == nil, !state.deletedNotes.contains(id), let kind = NoteArtifactKind(rawValue: command.options["kind"] ?? "note") else { throw WorkspaceToolError.invalid("Choose a new note, spreadsheet, or HTML artifact.") }
      let folder = command.options["folder"] ?? context.folderID
      if let folder, state.folders[folder] == nil { throw WorkspaceToolError.notFound("This folder is not available on this device.") }
      let content = try NoteDocument(kind: kind).encoded()
      let note = CompanionNote(id: id, folderID: folder, title: try command.required("title"), content: content, revision: 0, updatedAt: ISO8601DateFormatter().string(from: Date()), kind: kind)
      guard note.title.utf8.count <= 4096 else { throw WorkspaceToolError.invalid("The title is too long.") }
      state.notes[id] = note
      state.outbox.append(.init(mutation: mutation(for: note, kind: .createNote, deviceID: state.deviceID)))
      return .object(["id": .string(id), "revision": .string(try MobileToolSupport.fingerprint(note))])
    }
    guard var note = state.notes[id], !state.deletedNotes.contains(id), !state.uncachedNoteIDs.contains(id) else { throw WorkspaceToolError.notFound("This note is not saved on this device. Download it from the central library first.") }
    if command.action == "read" { return try noteRead(note, command: command) }
    if command.action == "versions" { return try MobileToolSupport.page((state.toolNoteVersions ?? []).filter { $0.note.id == id }.reversed().map { .object(["id": .string($0.id), "noteID": .string(id), "title": .string($0.note.title), "createdAt": .string($0.savedAt)]) }, command: command) }
    guard state.conflicts[id] == nil else { throw WorkspaceToolError.revisionConflict("Resolve this note's sync conflict before editing.") }
    let revision = try MobileToolSupport.fingerprint(note)
    let appendOnly = command.action == "append" || (command.action == "table" && ["add-row", "add-column"].contains(command.subaction ?? "") && command.options["after"] == nil)
    if let expected = command.options["revision"] {
      guard expected == revision else { throw WorkspaceToolError.revisionConflict("The note changed. Read it again before editing.") }
    } else if !appendOnly { throw WorkspaceToolError.revisionRequired("Read the note and supply its current --revision before changing existing content.") }
    let original = note
    if command.action == "restore" {
      let versionID = try command.required("version")
      guard let version = state.toolNoteVersions?.first(where: { $0.id == versionID && $0.note.id == id }) else { throw WorkspaceToolError.notFound("The requested version is not saved on this device.") }
      note.title = version.note.title; note.content = version.note.content; note.kind = version.note.kind
    } else {
      var document = try NoteDocument.editableDocument(from: note.content)
      if let title = try document.apply(noteOperations(command)) { note.title = title }
      note.content = try document.encoded(); note.kind = document.kind
    }
    guard note.content.utf8.count <= CompanionProtocol.maximumNoteBytes else { throw Failure.noteTooLarge }
    let candidateDocument = try NoteDocument.editableDocument(from: note.content)
    let hasLinkedTable = candidateDocument.blocks.contains { block in if case .table(let table) = block { return table.databaseLink != nil }; return false }
    guard candidateDocument.databaseLink == nil, !hasLinkedTable else { throw WorkspaceToolError.invalid("Linked database artifacts are edited in their owning workspace. Use target central when connected; this device has not changed the note.") }
    note.updatedAt = ISO8601DateFormatter().string(from: Date()); note.contentByteCount = note.content.utf8.count
    var versions = state.toolNoteVersions ?? []
    if !versions.contains(where: { $0.id == revision }) { versions.append(.init(id: revision, note: original, savedAt: note.updatedAt)) }
    state.toolNoteVersions = versions; state.notes[id] = note
    if let index = state.outbox.firstIndex(where: { $0.mutation.resourceID == id && !$0.submitted }) {
      state.outbox[index].mutation.title = note.title; state.outbox[index].mutation.content = note.content; state.outbox[index].mutation.folderID = note.folderID
    } else if !state.outbox.contains(where: { $0.mutation.resourceID == id }) {
      state.outbox.append(.init(mutation: mutation(for: note, kind: .updateNote, deviceID: state.deviceID)))
    }
    return .object(["id": .string(id), "title": .string(note.title), "revision": .string(try MobileToolSupport.fingerprint(note)), "replayed": .bool(false)])
  }
  private static func noteRead(_ note: CompanionNote, command: WovenMatterToolCommand) throws -> GatewayJSONValue {
    var value = try MobileToolSupport.chunk(note.content, command: command)
    value["id"] = .string(note.id); value["title"] = .string(note.title); value["revision"] = .string(try MobileToolSupport.fingerprint(note)); value["kind"] = .string(note.kind?.rawValue ?? NoteDocument.decode(note.content).kind.rawValue)
    return .object(value)
  }
  private static func noteOperations(_ c: WovenMatterToolCommand) throws -> [NoteEditOperation] {
    func style() throws -> NoteParagraphStyle {
      guard let value = NoteParagraphStyle(rawValue: c.options["style"] ?? "paragraph") else { throw WorkspaceToolError.invalid("Unknown paragraph style.") }; return value
    }
    func integer(_ key: String, fallback: Int = 0, minimum: Int = 0) throws -> Int { try c.integer(key, default: fallback, range: minimum...1_000) }
    func tableID() throws -> String { try c.required("table-id") }
    switch c.action {
    case "append": return [.appendText(try c.required("text"), try style())]
    case "insert": return [.insertText(afterBlockID: c.options["after"], text: try c.required("text"), style: try style())]
    case "replace-block": return [.replaceBlock(id: try c.required("id"), block: try JSONDecoder().decode(NoteBlock.self, from: Data(c.required("json").utf8)))]
    case "delete-block": return [.deleteBlock(id: try c.required("id"))]
    case "format": return [.setParagraphStyle(blockID: try c.required("block-id"), style: try style())]
    case "set-title": return [.setTitle(try c.required("title"))]
    case "set-html": return [.setHTML(try c.required("html"))]
    case "apply": return try JSONDecoder().decode([NoteEditOperation].self, from: Data(c.required("json").utf8))
    case "link", "unlink":
      let link: DatabaseArtifactLink? = c.action == "unlink" ? nil : .init(sourceID: try c.required("source-id"), databaseID: try c.required("database-id"), relativePath: try c.required("path"), sqliteQuery: c.options["query"])
      return [c.options["table-id"].map { .setTableDatabaseLink(tableID: $0, link: link) } ?? .setArtifactDatabaseLink(link)]
    case "table":
      switch c.subaction {
      case "create": return [.createTable(afterBlockID: c.options["after"], rows: try integer("rows", fallback: 3, minimum: 1), columns: try integer("columns", fallback: 3, minimum: 1), headerRow: c.options["header"] != nil)]
      case "set-cell": return [.setTableCell(tableID: try tableID(), row: try integer("row"), column: try integer("column"), runs: [.init(text: try c.required("text"))])]
      case "add-row": return [.addTableRow(tableID: try tableID(), after: try c.options["after"].map { _ in try integer("after", minimum: -1) })]
      case "add-column": return [.addTableColumn(tableID: try tableID(), after: try c.options["after"].map { _ in try integer("after", minimum: -1) })]
      case "remove-row": return [.removeTableRow(tableID: try tableID(), row: try integer("row"))]
      case "remove-column": return [.removeTableColumn(tableID: try tableID(), column: try integer("column"))]
      default: throw WorkspaceToolError.invalid("Choose a table operation.")
      }
    default: throw WorkspaceToolError.invalid("Unsupported note operation.")
    }
  }

  private static func timerTool(_ c: WovenMatterToolCommand, requestID: String, context: MobileToolContext, state: inout MobileStoreState) throws -> GatewayJSONValue {
    let existingTimerID = c.options["id"] ?? c.positional.first
    let sessionID = c.options["session"] ?? existingTimerID.flatMap { state.toolTimers?[$0]?.sessionID } ?? context.sessionID
    if sessionID != context.sessionID {
      guard context.enabled.contains(.sessions), state.localToolCoordinations?[sessionID]?.coordinatorID == context.sessionID else { throw WorkspaceToolError.accessRequired(sessionID) }
    }
    var timers = state.toolTimers ?? [:]
    if c.action == "list" { return try MobileToolSupport.page(timers.values.filter { $0.sessionID == sessionID && !$0.removed }.sorted { $0.id < $1.id }.map(MobileToolSupport.value), command: c) }
    let id = c.action == "create" ? requestID : try c.required("id", allowPositional: true)
    if c.action == "create" || c.action == "update" {
      if c.action == "update" { guard let existing = timers[id], existing.sessionID == sessionID, !existing.removed else { throw WorkspaceToolError.notFound("The timer does not exist in this session.") } }
      else if timers[id] != nil { throw WorkspaceToolError.invalid("The timer ID already exists.") }
      var interval: Double?
      if let raw = c.options["every"] {
        guard let value = Double(raw), value.isFinite, value >= 1, value <= 365 * 86_400 else { throw WorkspaceToolError.invalid("--every must be between 1 second and 365 days.") }; interval = value
      }
      let instruction = try c.required("text")
      guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instruction.utf8.count <= 64 * 1_024 else { throw WorkspaceToolError.invalid("The timer instruction is too long.") }
      timers[id] = .init(id: id, sessionID: sessionID, instruction: instruction, nextFireAt: try MobileToolSupport.date(c.required("at")), intervalSeconds: interval, isPaused: c.options["paused"] != nil)
    } else {
      guard var timer = timers[id], timer.sessionID == sessionID, !timer.removed else { throw WorkspaceToolError.notFound("The timer does not exist in this session.") }
      if c.action == "remove" { timer.removed = true; timer.pendingFireID = nil; timer.pendingFireAt = nil }
      else { timer.isPaused = c.action == "pause"; if timer.isPaused { timer.pendingFireID = nil; timer.pendingFireAt = nil } }
      timers[id] = timer
    }
    state.toolTimers = timers
    return try MobileToolSupport.value(timers[id]!)
  }
  /// Claim a stable firing identity. A crash before acceptance leaves it pending;
  /// a retry uses that same command ID instead of creating a second agent turn.
  public func claimDueToolTimers(now: Date = Date()) throws -> [MobileToolTimer] {
    var due: [MobileToolTimer] = []
    try transaction { next in
      var timers = next.toolTimers ?? [:]
      for (id, var timer) in timers where !timer.removed && !timer.isPaused && timer.nextFireAt <= now {
        if timer.pendingFireID == nil { timer.pendingFireID = UUID().uuidString.lowercased(); timer.pendingFireAt = timer.nextFireAt; timers[id] = timer }
        due.append(timer)
      }
      next.toolTimers = timers
    }
    return due.sorted { $0.nextFireAt < $1.nextFireAt }
  }
  public func enqueueClaimedToolTimer(id: String, fireID: String, now: Date = Date()) throws -> MobileToolSubmission? {
    var result: MobileToolSubmission?
    try transaction { next in
      guard var timer = next.toolTimers?[id], !timer.removed, !timer.isPaused, timer.pendingFireID == fireID else { return }
      var submissions = next.toolSubmissions ?? [:]
      let submission = MobileToolSubmission(id: fireID, sessionID: timer.sessionID, text: timer.instruction, state: "queued", submittedAt: now)
      if let prior = submissions[fireID] {
        guard prior.sessionID == submission.sessionID, prior.text == submission.text else { throw WorkspaceToolError.invalid("The timer receipt was reused.") }; result = prior
      } else { submissions[fireID] = submission; result = submission }
      next.toolSubmissions = submissions
      if let interval = timer.intervalSeconds {
        let missed = floor(max(0, now.timeIntervalSince(timer.nextFireAt)) / interval) + 1
        timer.nextFireAt = timer.nextFireAt.addingTimeInterval(missed * interval)
      } else { timer.isPaused = true }
      timer.pendingFireID = nil; timer.pendingFireAt = nil; next.toolTimers?[id] = timer
    }
    return result
  }
  public func acknowledgeToolTimer(id: String, fireID: String, now: Date = Date()) throws {
    try transaction { next in
      guard var timer = next.toolTimers?[id], timer.pendingFireID == fireID else { throw WorkspaceToolError.invalid("This timer firing is no longer current.") }
      if let interval = timer.intervalSeconds {
        let missed = floor(max(0, now.timeIntervalSince(timer.nextFireAt)) / interval) + 1
        timer.nextFireAt = timer.nextFireAt.addingTimeInterval(missed * interval)
      } else { timer.isPaused = true }
      timer.pendingFireID = nil; timer.pendingFireAt = nil; next.toolTimers?[id] = timer
    }
  }
}
