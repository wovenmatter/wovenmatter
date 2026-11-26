import Foundation
import WovenProtocol

// Typed reads and writes for machines, sessions, session items, folders and
// settings. Other areas get theirs when they are built.

extension Library {
  // MARK: Machines

  public func machines() async throws -> [Machine] {
    try await read { db in
      try db.query("SELECT id, name, platform FROM machines WHERE deleted = 0 ORDER BY name, id").map(Self.machine)
    }
  }

  public func machine(_ id: String) async throws -> Machine? {
    try await read { db in
      try db.query("SELECT id, name, platform FROM machines WHERE id = ? AND deleted = 0", [.text(id)]).first.map(Self.machine)
    }
  }

  @discardableResult
  public func renameMachine(_ id: String, to name: String) async throws -> Machine {
    try await write { writer -> Machine in
      guard let row = try writer.row("machines", id) else { throw LibraryError(.notFound, "No machine \(id).") }
      try writer.put("machines", id: id, ["name": .text(name)])
      return Machine(id: id, name: name, platform: MachinePlatform(rawValue: row.text("platform") ?? "") ?? .mac)
    }
  }

  /// How a Mac reaches this Linux machine over SSH: the host and user given
  /// when it was installed, or nil when it was not installed from a Mac.
  public func sshRoute(of id: String) async throws -> (host: String, user: String?)? {
    try await read { db in
      guard let row = try db.query("SELECT ssh_host, ssh_user FROM machines WHERE id = ? AND deleted = 0", [.text(id)]).first,
            let host = row.text("ssh_host"), !host.isEmpty else { return nil }
      let user = row.text("ssh_user") ?? ""
      return (host, user.isEmpty ? nil : user)
    }
  }

  /// Records how this machine was installed over SSH, for every Mac. Writes
  /// nothing when that is already recorded.
  public func setSSHRoute(of id: String, host: String, user: String?) async throws {
    try await write { writer in
      guard let row = try writer.row("machines", id) else { throw LibraryError(.notFound, "No machine \(id).") }
      guard row.text("ssh_host") != host || (row.text("ssh_user") ?? "") != (user ?? "") else { return }
      _ = try writer.put("machines", id: id, ["ssh_host": .text(host), "ssh_user": .text(user ?? "")])
    }
  }

  /// Deletes a machine with its sessions (and their transcripts) and its
  /// folders, schedules, databases and sealed secrets, in every library.
  public func removeMachine(_ id: String) async throws {
    guard id != machineID else { throw LibraryError(.invalid, "A machine cannot remove itself.") }
    try await delete("machines", id: id)
  }

  // MARK: Sessions

  /// A new session on this machine. `directory` is where its runtime works.
  public func createSession(id: String = UUID().uuidString.lowercased(), runtime: RuntimeKind, title: String,
                            folderID: String? = nil, directory: String = "") async throws -> Session {
    let session = Session(id: id, machineID: machineID, runtime: runtime, title: title,
                          folderID: folderID, directory: directory, archived: false, goal: nil, createdAt: Self.now())
    _ = try await write { writer in
      try writer.put("sessions", id: session.id, [
        "machine_id": .text(session.machineID), "runtime": .text(runtime.rawValue), "title": .text(title),
        "folder_id": folderID.map(SQLValue.text) ?? .null, "directory": .text(directory),
        "created_at": .integer(Self.millis(session.createdAt)),
      ])
    }
    return session
  }

  /// Records the model, thinking level and permission mode a session runs
  /// with now. Nil leaves one as it is.
  public func setSessionChoices(_ id: String, model: String?, thinking: String?, permission: String?) async throws {
    var values: [String: SQLValue] = [:]
    if let model { values["model"] = .text(model) }
    if let thinking { values["thinking"] = .text(thinking) }
    if let permission { values["permission"] = .text(permission) }
    let changes = values
    try await write { writer in
      guard let row = try writer.row("sessions", id), !row.bool("deleted") else { throw LibraryError(.notFound, "No session \(id).") }
      let unchanged = changes.allSatisfy { row[$0.key] == $0.value }
      if !unchanged { try writer.put("sessions", id: id, changes) }
    }
  }

  public func session(_ id: String) async throws -> Session? {
    try await read { db in
      try db.query(Self.sessionSelect + " WHERE s.id = ? AND s.deleted = 0", [.text(id)]).first.map(Self.session)
    }
  }

  /// Sessions, most recently active first.
  public func sessions(machineID: String? = nil, includeArchived: Bool = false) async throws -> [Session] {
    try await read { db in
      var sql = Self.sessionSelect + " WHERE s.deleted = 0"
      var values: [SQLValue] = []
      if let machineID {
        sql += " AND s.machine_id = ?"
        values.append(.text(machineID))
      }
      if !includeArchived { sql += " AND s.archived = 0" }
      return try db.query(sql + " ORDER BY last_at DESC, s.id", values).map(Self.session)
    }
  }

  /// A session row with what lists show of its transcript, from its newest
  /// item and its newest message, in one query.
  private static let sessionSelect = """
    SELECT s.*, COALESCE(last.created_at, s.created_at) AS last_at, last.kind AS last_kind,
      substr(json_extract(message.body, '$.text'), 1, 400) AS preview_text
    FROM sessions s
    LEFT JOIN session_items last ON last.id = (
      SELECT id FROM session_items WHERE session_id = s.id AND deleted = 0 ORDER BY sequence DESC LIMIT 1)
    LEFT JOIN session_items message ON message.id = (
      SELECT id FROM session_items WHERE session_id = s.id AND deleted = 0
        AND kind IN ('userMessage', 'assistantMessage') ORDER BY sequence DESC LIMIT 1)
    """

  /// Changes a session's title, folder, archived or pinned flag, goal or tool
  /// groups; nil leaves a
  /// field. `read` true marks every item so far read, false marks it unread.
  public func updateSession(_ id: String, title: String? = nil, archived: Bool? = nil, pinned: Bool? = nil,
                            read: Bool? = nil, folderID: String?? = nil, goal: String?? = nil,
                            tools: Set<ToolGroup>? = nil) async throws -> Session {
    var values: [String: SQLValue] = [:]
    if let tools {
      values["tools"] = .text(String(decoding: try Wire.encoder.encode(tools.map(\.rawValue).sorted()), as: UTF8.self))
    }
    if let title { values["title"] = .text(title) }
    if let archived { values["archived"] = .integer(archived ? 1 : 0) }
    if let pinned { values["pinned"] = .integer(pinned ? 1 : 0) }
    if let folderID { values["folder_id"] = folderID.map(SQLValue.text) ?? .null }
    if let goal { values["goal"] = goal.map(SQLValue.text) ?? .null }
    let fixed = values
    try await write { writer in
      guard let row = try writer.row("sessions", id), !row.bool("deleted") else {
        throw LibraryError(.notFound, "No session \(id).")
      }
      var changes = fixed
      if let read {
        // Read up to the newest item, by the owner's clock that stamped it.
        let newest = try writer.db.query("SELECT MAX(created_at) AS newest FROM session_items WHERE session_id = ? AND deleted = 0",
                                         [.text(id)]).first?.integer("newest") ?? 0
        changes["read_at"] = .integer(read ? newest : 0)
      }
      changes = changes.filter { row[$0.key] != $0.value }
      if changes["archived"] == .integer(1) { changes["archived_at"] = .integer(Self.millis(Self.now())) }
      if !changes.isEmpty { try writer.put("sessions", id: id, changes) }
    }
    guard let session = try await session(id) else { throw LibraryError(.notFound, "No session \(id).") }
    return session
  }

  /// Deletes a session and its transcript, in every library.
  public func deleteSession(_ id: String) async throws {
    try await delete("sessions", id: id)
  }

  // MARK: Session items

  /// Saves a finished item of a session this machine owns, as the next in
  /// its sequence. Only the owning machine writes a session's items.
  public func appendItem(sessionID: String, id: String = UUID().uuidString.lowercased(),
                         content: ItemContent, author: ItemAuthor? = nil, createdAt: Date = Date()) async throws -> SessionItem {
    let body = String(decoding: try Wire.encoder.encode(content), as: UTF8.self)
    let machineID = machineID
    // Stored to the millisecond, so the item announced equals the item read back.
    let createdAt = Date(timeIntervalSince1970: Double(Self.millis(createdAt)) / 1000)
    return try await write { writer in
      guard let session = try writer.row("sessions", sessionID), !session.bool("deleted") else {
        throw LibraryError(.notFound, "No session \(sessionID).")
      }
      guard session.text("machine_id") == machineID else {
        throw LibraryError(.notOwner(machineID: session.text("machine_id") ?? ""), "Another machine owns this session.")
      }
      let sequence = try Self.putItem(id: id, sessionID: sessionID, content: content, body: body, author: author,
                                      createdAt: createdAt, writer)
      return SessionItem(id: id, sessionID: sessionID, sequence: sequence, createdAt: createdAt, content: content,
                         author: author)
    }
  }

  /// Writes one session item after the session's last: the one way a
  /// session's items and a bot's are saved. Returns its sequence.
  static func putItem(id: String, sessionID: String, content: ItemContent, body: String? = nil, author: ItemAuthor?,
                      createdAt: Date, _ writer: Writer) throws -> Int {
    let last = try writer.db.query("SELECT MAX(sequence) AS last FROM session_items WHERE session_id = ?",
                                   [.text(sessionID)]).first?.integer("last") ?? 0
    let body = try body ?? String(decoding: try Wire.encoder.encode(content), as: UTF8.self)
    try writer.put("session_items", id: id, [
      "session_id": .text(sessionID), "sequence": .integer(last + 1),
      "kind": .text(content.kindName), "body": .text(body), "created_at": .integer(millis(createdAt)),
      "author": try author.map { .text(String(decoding: try Wire.encoder.encode($0), as: UTF8.self)) } ?? .null,
    ])
    return Int(last + 1)
  }

  /// Whether a session holds an item from `author`: the other session (by
  /// its id) or the bot (by its id) it names.
  public func hasItem(in sessionID: String, from author: ItemAuthor) async throws -> Bool {
    let (path, id) = author.sessionID.map { ("$.sessionID", $0) } ?? ("$.botID", author.botID ?? "")
    return try await read { db in
      try !db.query("""
        SELECT 1 FROM session_items WHERE session_id = ? AND deleted = 0 AND author IS NOT NULL
        AND json_extract(author, '\(path)') = ? LIMIT 1
        """, [.text(sessionID), .text(id)]).isEmpty
    }
  }

  /// A session's saved items in order, after `afterSequence`.
  /// A session's items in order: those after `afterSequence`, or with
  /// `beforeSequence` the newest before it. A page with a limit or
  /// `beforeSequence` ends once its size reaches `byteBudget` (with at least
  /// one item), so it always fits in one message.
  public func items(sessionID: String, afterSequence: Int = 0, beforeSequence: Int? = nil, limit: Int? = nil,
                    byteBudget: Int = 8 << 20) async throws -> [SessionItem] {
    try await read { db in
      var sql = "SELECT * FROM session_items WHERE session_id = ? AND sequence > ? AND deleted = 0"
      var values: [SQLValue] = [.text(sessionID), .integer(Int64(afterSequence))]
      if let beforeSequence {
        sql += " AND sequence < ? ORDER BY sequence DESC"
        values.append(.integer(Int64(beforeSequence)))
      } else {
        sql += " ORDER BY sequence"
      }
      if let limit {
        sql += " LIMIT ?"
        values.append(.integer(Int64(limit)))
      }
      guard limit != nil || beforeSequence != nil else { return try db.query(sql, values).map(Self.item) }
      var rows: [Row] = []
      var bytes = 0
      for row in try db.query(sql, values) {
        if !rows.isEmpty && bytes >= byteBudget { break }
        rows.append(row)
        bytes += Writer.size(of: row.values(excluding: []))
      }
      if beforeSequence != nil { rows.reverse() }
      return try rows.map(Self.item)
    }
  }

  // MARK: Folders

  /// A new folder on this machine, after its other folders. `managed` says
  /// the server made `path` for it.
  public func createFolder(name: String, path: String, managed: Bool = false) async throws -> Folder {
    let machineID = machineID
    return try await write { writer in
      let last = try writer.db.query("SELECT MAX(position) AS last FROM folders WHERE machine_id = ? AND deleted = 0",
                                     [.text(machineID)]).first?.integer("last")
      let folder = Folder(id: UUID().uuidString.lowercased(), machineID: machineID, name: name, path: path,
                          position: last.map { Int($0) + 1 } ?? 0, managed: managed, createdAt: Self.now())
      try writer.put("folders", id: folder.id, [
        "machine_id": .text(machineID), "name": .text(name), "path": .text(path),
        "position": .integer(Int64(folder.position)), "managed": .integer(managed ? 1 : 0),
        "created_at": .integer(Self.millis(folder.createdAt)),
      ])
      return folder
    }
  }

  public func folder(_ id: String) async throws -> Folder? {
    try await read { db in
      try db.query("SELECT * FROM folders WHERE id = ? AND deleted = 0", [.text(id)]).first.map(Self.folder)
    }
  }

  /// Folders in sidebar order.
  public func folders(machineID: String? = nil) async throws -> [Folder] {
    try await read { db in
      if let machineID {
        return try db.query("SELECT * FROM folders WHERE deleted = 0 AND machine_id = ? ORDER BY position, name, id",
                            [.text(machineID)]).map(Self.folder)
      }
      return try db.query("SELECT * FROM folders WHERE deleted = 0 ORDER BY position, name, id").map(Self.folder)
    }
  }

  /// Changes a folder's name, pinned flag, position or other directories;
  /// nil leaves a field.
  public func updateFolder(_ id: String, name: String? = nil, pinned: Bool? = nil, position: Int? = nil,
                           references: [String]? = nil) async throws -> Folder {
    var values: [String: SQLValue] = [:]
    if let references {
      values["other_directories"] = .text(String(decoding: try Wire.encoder.encode(Array(Set(references)).sorted()), as: UTF8.self))
    }
    if let name { values["name"] = .text(name) }
    if let pinned { values["pinned"] = .integer(pinned ? 1 : 0) }
    if let position { values["position"] = .integer(Int64(position)) }
    let requested = values
    try await write { writer in
      guard let row = try writer.row("folders", id), !row.bool("deleted") else { throw LibraryError(.notFound, "No folder \(id).") }
      let changes = requested.filter { row[$0.key] != $0.value }
      if !changes.isEmpty { try writer.put("folders", id: id, changes) }
    }
    guard let folder = try await folder(id) else { throw LibraryError(.notFound, "No folder \(id).") }
    return folder
  }

  public func deleteFolder(_ id: String) async throws {
    try await delete("folders", id: id)
  }

  // MARK: Settings

  public func settings() async throws -> [Setting] {
    try await read { db in
      try db.query("SELECT id, value FROM settings WHERE deleted = 0 AND value != 'null' ORDER BY id").map(Self.setting)
    }
  }

  public func setting(_ key: String) async throws -> Setting? {
    try await read { db in
      try db.query("SELECT id, value FROM settings WHERE id = ? AND deleted = 0 AND value != 'null'", [.text(key)]).first
        .map(Self.setting)
    }
  }

  /// Sets a setting everywhere; setting `null` unsets it.
  @discardableResult
  public func setSetting(_ key: String, to value: JSONValue) async throws -> Setting {
    if value == .null {
      try await delete("settings", id: key)
      return Setting(key: key, value: .null)
    }
    let text = String(decoding: try Wire.encoder.encode(value), as: UTF8.self)
    try await put("settings", id: key, ["value": .text(text)])
    return Setting(key: key, value: value)
  }

  // MARK: Native sessions (this machine only)

  public struct NativeSession: Sendable, Equatable {
    public var handle: String
    public var gone: Bool
  }

  public func nativeSession(for sessionID: String) async throws -> NativeSession? {
    try await read { db in
      try db.query("SELECT handle, gone FROM native_sessions WHERE session_id = ?", [.text(sessionID)]).first.map {
        NativeSession(handle: $0.text("handle") ?? "", gone: $0.bool("gone"))
      }
    }
  }

  /// The session a runtime's native session serves, by the runtime's handle.
  public func session(runtime: RuntimeKind, nativeHandle: String) async throws -> String? {
    try await read { db in
      try db.query("SELECT session_id FROM native_sessions WHERE runtime = ? AND handle = ?",
                   [.text(runtime.rawValue), .text(nativeHandle)]).first?.text("session_id")
    }
  }

  public func setNativeSession(_ sessionID: String, runtime: RuntimeKind, handle: String) async throws {
    try await write { writer in
      try writer.db.run("""
        INSERT INTO native_sessions (session_id, runtime, handle, gone, updated_at) VALUES (?, ?, ?, 0, ?)
        ON CONFLICT(session_id) DO UPDATE SET runtime = excluded.runtime, handle = excluded.handle, gone = 0,
          updated_at = excluded.updated_at
        """, [.text(sessionID), .text(runtime.rawValue), .text(handle), .integer(Writer.now())])
    }
  }

  /// Marks that a turn of this session is running, or no longer is.
  public func setTurnRunning(_ sessionID: String, _ running: Bool) async throws {
    try await write { writer in
      try writer.db.run("UPDATE native_sessions SET turn_running = ?, updated_at = ? WHERE session_id = ?",
                        [.integer(running ? 1 : 0), .integer(Writer.now()), .text(sessionID)])
    }
  }

  /// Sessions whose turn was still running when the server last stopped.
  public func sessionsStoppedMidTurn() async throws -> [String] {
    try await read { db in
      try db.query("SELECT session_id FROM native_sessions WHERE turn_running = 1").compactMap { $0.text("session_id") }
    }
  }

  /// Whether the session has any saved item.
  public func hasItems(_ sessionID: String) async throws -> Bool {
    try await read { db in
      try !db.query("SELECT id FROM session_items WHERE session_id = ? AND deleted = 0 LIMIT 1", [.text(sessionID)]).isEmpty
    }
  }

  /// Records that the runtime no longer has this session's native session.
  public func markNativeSessionGone(_ sessionID: String) async throws {
    try await write { writer in
      try writer.db.run("UPDATE native_sessions SET gone = 1, updated_at = ? WHERE session_id = ?",
                        [.integer(Writer.now()), .text(sessionID)])
    }
  }

  // MARK: Mapping

  static func now() -> Date { Date(timeIntervalSince1970: Double(Writer.now()) / 1000) }
  /// Milliseconds since 1970, held to the years a library can mean, so a
  /// time read from anywhere never overflows.
  static func millis(_ date: Date) -> Int64 {
    let value = (date.timeIntervalSince1970 * 1000).rounded()
    return value.isNaN ? 0 : Int64(min(max(value, -1e15), 1e15))
  }

  private static func machine(_ row: Row) -> Machine {
    Machine(id: row.text("id") ?? "", name: row.text("name") ?? "",
            platform: MachinePlatform(rawValue: row.text("platform") ?? "") ?? .mac)
  }

  /// Maps a row of `sessionSelect`.
  private static func session(_ row: Row) -> Session {
    let lastAt = row.integer("last_at") ?? 0
    let unread = row.text("last_kind").map { $0 != "userMessage" } == true && lastAt > (row.integer("read_at") ?? 0)
    return Session(id: row.text("id") ?? "", machineID: row.text("machine_id") ?? "",
                   runtime: RuntimeKind(rawValue: row.text("runtime") ?? ""), title: row.text("title") ?? "",
                   folderID: row.text("folder_id"), directory: row.text("directory") ?? "", model: row.text("model"),
                   thinking: row.text("thinking"), permission: row.text("permission"), archived: row.bool("archived"),
                   pinned: row.bool("pinned"), goal: row.text("goal"), createdAt: row.date("created_at"),
                   lastActivityAt: row.date("last_at"), preview: row.text("preview_text").flatMap(Self.preview),
                   unread: unread, tools: row.text("tools").flatMap(Self.toolGroups),
                   archivedAt: row.bool("archived") ? row.date("archived_at") : nil)
  }

  private static func toolGroups(_ json: String) -> Set<ToolGroup>? {
    (try? Wire.decoder.decode([String].self, from: Data(json.utf8))).map { Set($0.compactMap(ToolGroup.init(rawValue:))) }
  }

  /// One line from the start of a message: whitespace runs become one space.
  private static func preview(_ text: String) -> String? {
    let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.isEmpty ? nil : String(line.prefix(200))
  }

  static func item(_ row: Row) throws -> SessionItem {
    SessionItem(id: row.text("id") ?? "", sessionID: row.text("session_id") ?? "",
                sequence: Int(row.integer("sequence") ?? 0), createdAt: row.date("created_at"),
                content: try Wire.decoder.decode(ItemContent.self, from: Data((row.text("body") ?? "").utf8)),
                author: try row.text("author").map { try Wire.decoder.decode(ItemAuthor.self, from: Data($0.utf8)) })
  }

  private static func folder(_ row: Row) -> Folder {
    Folder(id: row.text("id") ?? "", machineID: row.text("machine_id") ?? "", name: row.text("name") ?? "",
           path: row.text("path") ?? "", pinned: row.bool("pinned"), position: Int(row.integer("position") ?? 0),
           managed: row.bool("managed"),
           references: (try? Wire.decoder.decode([String].self, from: Data((row.text("other_directories") ?? "[]").utf8))) ?? [],
           createdAt: row.date("created_at"))
  }

  private static func setting(_ row: Row) throws -> Setting {
    Setting(key: row.text("id") ?? "",
            value: try Wire.decoder.decode(JSONValue.self, from: Data((row.text("value") ?? "null").utf8)))
  }
}

// MARK: Usage

extension Library {
  /// Writes one usage record for a finished turn of a session on this
  /// machine, for a runtime without a history of its own (Pi Durable).
  public func recordUsage(sessionID: String?, runtime: RuntimeKind, model: String, input: Int64, output: Int64,
                          cacheRead: Int64, cacheWrite: Int64) async throws {
    try await put("usage_records", id: UUID().uuidString.lowercased(), [
      "machine_id": .text(machineID), "session_id": sessionID.map(SQLValue.text) ?? .null, "runtime": .text(runtime.rawValue),
      "model": .text(model), "input_tokens": .integer(input), "output_tokens": .integer(output),
      "cache_read_tokens": .integer(cacheRead), "cache_write_tokens": .integer(cacheWrite),
      "recorded_at": .integer(Writer.now()),
    ])
  }
}

extension ItemContent {
  var kindName: String {
    switch self {
    case .userMessage: "userMessage"
    case .assistantMessage: "assistantMessage"
    case .toolCall: "toolCall"
    case .notice: "notice"
    case .visualReply: "visualReply"
    }
  }
}
