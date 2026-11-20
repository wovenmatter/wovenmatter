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
      try db.query("SELECT * FROM sessions WHERE id = ? AND deleted = 0", [.text(id)]).first.map(Self.session)
    }
  }

  /// Sessions, newest first.
  public func sessions(machineID: String? = nil, includeArchived: Bool = false) async throws -> [Session] {
    try await read { db in
      var sql = "SELECT * FROM sessions WHERE deleted = 0"
      var values: [SQLValue] = []
      if let machineID {
        sql += " AND machine_id = ?"
        values.append(.text(machineID))
      }
      if !includeArchived { sql += " AND archived = 0" }
      return try db.query(sql + " ORDER BY created_at DESC, id", values).map(Self.session)
    }
  }

  /// Changes a session's title, folder or archived flag; nil leaves a field.
  public func updateSession(_ id: String, title: String? = nil, archived: Bool? = nil, folderID: String?? = nil,
                            goal: String?? = nil) async throws -> Session {
    var values: [String: SQLValue] = [:]
    if let title { values["title"] = .text(title) }
    if let archived { values["archived"] = .integer(archived ? 1 : 0) }
    if let folderID { values["folder_id"] = folderID.map(SQLValue.text) ?? .null }
    if let goal { values["goal"] = goal.map(SQLValue.text) ?? .null }
    let changes = values
    try await write { writer in
      guard let row = try writer.row("sessions", id), !row.bool("deleted") else {
        throw LibraryError(.notFound, "No session \(id).")
      }
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
                         content: ItemContent, createdAt: Date = Date()) async throws -> SessionItem {
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
      let last = try writer.db.query("SELECT MAX(sequence) AS last FROM session_items WHERE session_id = ?",
                                     [.text(sessionID)]).first?.integer("last") ?? 0
      let item = SessionItem(id: id, sessionID: sessionID, sequence: Int(last) + 1, createdAt: createdAt, content: content)
      try writer.put("session_items", id: id, [
        "session_id": .text(sessionID), "sequence": .integer(Int64(item.sequence)),
        "kind": .text(content.kindName), "body": .text(body), "created_at": .integer(Self.millis(createdAt)),
      ])
      return item
    }
  }

  /// A session's saved items in order, after `afterSequence`.
  public func items(sessionID: String, afterSequence: Int = 0, limit: Int? = nil) async throws -> [SessionItem] {
    try await read { db in
      var sql = "SELECT * FROM session_items WHERE session_id = ? AND sequence > ? AND deleted = 0 ORDER BY sequence"
      var values: [SQLValue] = [.text(sessionID), .integer(Int64(afterSequence))]
      if let limit {
        sql += " LIMIT ?"
        values.append(.integer(Int64(limit)))
      }
      return try db.query(sql, values).map(Self.item)
    }
  }

  // MARK: Folders

  public func createFolder(name: String, path: String) async throws -> Folder {
    let folder = Folder(id: UUID().uuidString.lowercased(), machineID: machineID, name: name, path: path, createdAt: Self.now())
    try await put("folders", id: folder.id, [
      "machine_id": .text(machineID), "name": .text(name), "path": .text(path),
      "created_at": .integer(Self.millis(folder.createdAt)),
    ])
    return folder
  }

  public func folder(_ id: String) async throws -> Folder? {
    try await read { db in
      try db.query("SELECT * FROM folders WHERE id = ? AND deleted = 0", [.text(id)]).first.map(Self.folder)
    }
  }

  public func folders(machineID: String? = nil) async throws -> [Folder] {
    try await read { db in
      if let machineID {
        return try db.query("SELECT * FROM folders WHERE deleted = 0 AND machine_id = ? ORDER BY name, id", [.text(machineID)])
          .map(Self.folder)
      }
      return try db.query("SELECT * FROM folders WHERE deleted = 0 ORDER BY name, id").map(Self.folder)
    }
  }

  public func renameFolder(_ id: String, to name: String) async throws -> Folder {
    try await write { writer in
      guard let row = try writer.row("folders", id), !row.bool("deleted") else { throw LibraryError(.notFound, "No folder \(id).") }
      try writer.put("folders", id: id, ["name": .text(name)])
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
  static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  private static func machine(_ row: Row) -> Machine {
    Machine(id: row.text("id") ?? "", name: row.text("name") ?? "",
            platform: MachinePlatform(rawValue: row.text("platform") ?? "") ?? .mac)
  }

  private static func session(_ row: Row) -> Session {
    Session(id: row.text("id") ?? "", machineID: row.text("machine_id") ?? "",
            runtime: RuntimeKind(rawValue: row.text("runtime") ?? ""), title: row.text("title") ?? "",
            folderID: row.text("folder_id"), directory: row.text("directory") ?? "", model: row.text("model"),
            thinking: row.text("thinking"), permission: row.text("permission"), archived: row.bool("archived"), goal: row.text("goal"),
            createdAt: row.date("created_at"))
  }

  private static func item(_ row: Row) throws -> SessionItem {
    SessionItem(id: row.text("id") ?? "", sessionID: row.text("session_id") ?? "",
                sequence: Int(row.integer("sequence") ?? 0), createdAt: row.date("created_at"),
                content: try Wire.decoder.decode(ItemContent.self, from: Data((row.text("body") ?? "").utf8)))
  }

  private static func folder(_ row: Row) -> Folder {
    Folder(id: row.text("id") ?? "", machineID: row.text("machine_id") ?? "", name: row.text("name") ?? "",
           path: row.text("path") ?? "", createdAt: row.date("created_at"))
  }

  private static func setting(_ row: Row) throws -> Setting {
    Setting(key: row.text("id") ?? "",
            value: try Wire.decoder.decode(JSONValue.self, from: Data((row.text("value") ?? "null").utf8)))
  }
}

// MARK: Usage

extension Library {
  /// Writes one usage record for a finished turn of a session on this machine.
  public func recordUsage(sessionID: String?, runtime: RuntimeKind, model: String, input: Int64, output: Int64,
                          cacheRead: Int64, cacheWrite: Int64, cost: Double) async throws {
    try await put("usage_records", id: UUID().uuidString.lowercased(), [
      "machine_id": .text(machineID), "session_id": sessionID.map(SQLValue.text) ?? .null, "runtime": .text(runtime.rawValue),
      "model": .text(model), "input_tokens": .integer(input), "output_tokens": .integer(output),
      "cache_read_tokens": .integer(cacheRead), "cache_write_tokens": .integer(cacheWrite), "cost": .real(cost),
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
    }
  }
}
