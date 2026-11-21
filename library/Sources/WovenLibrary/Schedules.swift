import Foundation
import WovenProtocol

// Typed reads and writes for scheduler entries (`schedules`, synced) and
// what this machine has fired of them (`schedule_state`, local). An entry
// belongs to its machine, and only that machine's server writes it.

extension Library {
  /// Every machine's entries; those this machine owns carry their state.
  public func schedules() async throws -> [ScheduleEntry] {
    let machineID = machineID
    return try await read { db in
      try db.query("""
        SELECT s.*, st.next_fire_at AS st_next, st.last_fired_at AS st_last, st.session_id AS st_session,
          st.error AS st_error, st.schedule_id AS st_id
        FROM schedules s LEFT JOIN schedule_state st ON st.schedule_id = s.id
        WHERE s.deleted = 0 ORDER BY s.starts_at, s.id
        """).map { try Self.schedule($0, owner: machineID) }
    }
  }

  public func schedule(_ id: String) async throws -> ScheduleEntry? {
    try await schedules().first { $0.id == id }
  }

  /// Creates or replaces an entry this machine owns. `by` is the session
  /// that wrote it, or nil for the person.
  @discardableResult
  public func saveSchedule(id: String?, _ draft: ScheduleDraft, by sessionID: String? = nil) async throws -> ScheduleEntry {
    let machineID = machineID
    guard draft.machineID == machineID else {
      throw LibraryError(.notOwner(machineID: draft.machineID), "Another machine runs this entry.")
    }
    let id = id ?? UUID().uuidString.lowercased()
    let fields = try Self.values(draft)
    try await write { writer in
      var values = fields
      if let row = try writer.row("schedules", id), !row.bool("deleted") {
        guard row.text("machine_id") == machineID else {
          throw LibraryError(.notOwner(machineID: row.text("machine_id") ?? ""), "Another machine runs this entry.")
        }
        values["edited_by"] = sessionID.map(SQLValue.text) ?? .null
        values["edited_at"] = .integer(Writer.now())
      } else {
        values["created_by"] = sessionID.map(SQLValue.text) ?? .null
        values["created_at"] = .integer(Writer.now())
      }
      try writer.put("schedules", id: id, values)
    }
    guard let entry = try await schedule(id) else { throw LibraryError(.notFound, "No entry \(id).") }
    return entry
  }

  /// Leaves one occurrence of a series out.
  public func excludeOccurrence(_ id: String, _ index: Int) async throws {
    guard var draft = try await ownSchedule(id)?.draft else { return }
    guard !draft.excluded.contains(index) else { return }
    draft.excluded = (draft.excluded + [index]).sorted()
    let excluded = try Self.json(draft.excluded)
    _ = try await write { writer in
      try writer.put("schedules", id: id, ["excluded": excluded])
    }
  }

  /// Records the session a task's runs go to.
  public func setScheduleSession(_ id: String, _ sessionID: String) async throws {
    try await write { writer in
      guard let row = try writer.row("schedules", id), !row.bool("deleted"), row.text("session_id") != sessionID else { return }
      try writer.put("schedules", id: id, ["session_id": .text(sessionID)])
    }
  }

  /// Deletes an entry this machine owns, with its state.
  public func deleteSchedule(_ id: String) async throws {
    _ = try await ownSchedule(id)
    try await write { writer in
      try writer.delete("schedules", id: id)
      try writer.db.run("DELETE FROM schedule_state WHERE schedule_id = ?", [.text(id)])
    }
  }

  private func ownSchedule(_ id: String) async throws -> ScheduleEntry? {
    guard let entry = try await schedule(id) else { return nil }
    guard entry.machineID == machineID else {
      throw LibraryError(.notOwner(machineID: entry.machineID), "Another machine runs this entry.")
    }
    return entry
  }

  // MARK: What has fired (this machine only)

  /// An entry of this machine with the stamp of the row it was read from.
  public struct OwnSchedule: Sendable {
    public var entry: ScheduleEntry
    public var stamp: String
    /// The stamp `state.nextFireAt` was worked out from; nil before the first time.
    public var stateStamp: String?
    /// When it last fired, however late.
    public var firedAt: Date?
  }

  /// The entries this machine runs, and forgets the state of any that are gone.
  public func ownSchedules() async throws -> [OwnSchedule] {
    let machineID = machineID
    try await write { writer in
      try writer.db.run("""
        DELETE FROM schedule_state WHERE schedule_id NOT IN (SELECT id FROM schedules WHERE deleted = 0 AND machine_id = ?)
        """, [.text(machineID)])
    }
    return try await read { db in
      try db.query("""
        SELECT s.*, st.next_fire_at AS st_next, st.last_fired_at AS st_last, st.session_id AS st_session,
          st.error AS st_error, st.schedule_id AS st_id, st.stamp AS st_stamp, st.fired_at AS st_fired
        FROM schedules s LEFT JOIN schedule_state st ON st.schedule_id = s.id
        WHERE s.deleted = 0 AND s.machine_id = ?
        """, [.text(machineID)]).map {
        OwnSchedule(entry: try Self.schedule($0, owner: machineID), stamp: $0.text("stamp") ?? "", stateStamp: $0.text("st_stamp"),
                    firedAt: $0.integer("st_fired").map { Date(timeIntervalSince1970: Double($0) / 1000) })
      }
    }
  }

  /// Sets when an entry next fires, worked out from the row with `stamp`.
  public func setNextFire(_ id: String, at next: Date?, stamp: String) async throws {
    try await write { writer in
      try writer.db.run("""
        INSERT INTO schedule_state (schedule_id, stamp, next_fire_at) VALUES (?, ?, ?)
        ON CONFLICT(schedule_id) DO UPDATE SET stamp = excluded.stamp, next_fire_at = excluded.next_fire_at
        """, [.text(id), .text(stamp), next.map { .integer(Self.millis($0)) } ?? .null])
    }
  }

  /// Takes the occurrence due at `due` for firing: in one write, records it
  /// as fired and moves `next_fire_at` on to `next`. Returns false when it is
  /// no longer due (already taken), so an occurrence is fired at most once,
  /// whatever stops the server afterwards.
  public func takeFire(_ id: String, due: Date, next: Date?, at now: Date) async throws -> Bool {
    try await write { writer in
      try writer.db.run("""
        UPDATE schedule_state SET next_fire_at = ?, last_fired_at = ?, fired_at = ?, error = NULL
        WHERE schedule_id = ? AND next_fire_at = ?
        """, [next.map { .integer(Self.millis($0)) } ?? .null, .integer(Self.millis(due)), .integer(Self.millis(now)),
              .text(id), .integer(Self.millis(due))])
      return writer.db.changes > 0
    }
  }

  /// Puts a taken occurrence back to be tried again at `retry`, when it
  /// could not be delivered (the session was in a turn).
  public func retryFire(_ id: String, at retry: Date) async throws {
    try await write { writer in
      try writer.db.run("UPDATE schedule_state SET next_fire_at = ? WHERE schedule_id = ?",
                        [.integer(Self.millis(retry)), .text(id)])
    }
  }

  /// Records where a run went, or why it failed.
  public func recordRun(_ id: String, sessionID: String?, error: String?) async throws {
    try await write { writer in
      try writer.db.run("UPDATE schedule_state SET session_id = COALESCE(?, session_id), error = ? WHERE schedule_id = ?",
                        [sessionID.map(SQLValue.text) ?? .null, error.map(SQLValue.text) ?? .null, .text(id)])
    }
  }

  // MARK: Mapping

  private static func values(_ draft: ScheduleDraft) throws -> [String: SQLValue] {
    func text(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    return [
      "machine_id": .text(draft.machineID), "kind": .text(draft.kind.rawValue), "title": .text(draft.title),
      "details": .text(draft.details), "prompt": .text(draft.prompt), "session_id": text(draft.sessionID),
      "new_session": .integer(draft.newSessionEachRun ? 1 : 0), "folder_id": text(draft.folderID),
      "runtime": text(draft.runtime?.rawValue), "directory": text(draft.directory), "model": text(draft.model),
      "thinking": text(draft.thinking), "permission": text(draft.permission),
      "starts_at": .integer(millis(draft.startsAt)), "ends_at": draft.endsAt.map { .integer(millis($0)) } ?? .null,
      "all_day": .integer(draft.allDay ? 1 : 0), "time_zone": .text(draft.timeZone),
      "recurrence": try draft.recurrence.map { try json($0) } ?? .null, "excluded": try json(draft.excluded),
      "on_calendar": .integer(draft.showsOnCalendar ? 1 : 0), "enabled": .integer(draft.enabled ? 1 : 0),
    ]
  }

  private static func json<T: Encodable>(_ value: T) throws -> SQLValue {
    .text(String(decoding: try Wire.encoder.encode(value), as: UTF8.self))
  }

  private static func schedule(_ row: Row, owner: String) throws -> ScheduleEntry {
    func date(_ name: String) -> Date? { row.integer(name).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    let machineID = row.text("machine_id") ?? ""
    let draft = ScheduleDraft(
      machineID: machineID, kind: ScheduleKind(rawValue: row.text("kind") ?? "") ?? .event, title: row.text("title") ?? "",
      details: row.text("details") ?? "", prompt: row.text("prompt") ?? "", sessionID: row.text("session_id"),
      newSessionEachRun: row.bool("new_session"), runtime: row.text("runtime").map(RuntimeKind.init(rawValue:)),
      folderID: row.text("folder_id"), directory: row.text("directory"), model: row.text("model"),
      thinking: row.text("thinking"), permission: row.text("permission"), startsAt: date("starts_at") ?? .distantPast,
      endsAt: date("ends_at"), allDay: row.bool("all_day"),
      timeZone: (row.text("time_zone") ?? "").isEmpty ? TimeZone.current.identifier : row.text("time_zone")!,
      recurrence: try row.text("recurrence").map { try Wire.decoder.decode(Recurrence.self, from: Data($0.utf8)) },
      excluded: (try? Wire.decoder.decode([Int].self, from: Data((row.text("excluded") ?? "[]").utf8))) ?? [],
      showsOnCalendar: row.bool("on_calendar"), enabled: row.bool("enabled"))
    let state: ScheduleState? = machineID == owner && row.text("st_id") != nil
      ? ScheduleState(nextFireAt: date("st_next"), lastFiredAt: date("st_last"), lastSessionID: row.text("st_session"),
                      lastError: row.text("st_error"))
      : (machineID == owner ? ScheduleState() : nil)
    return ScheduleEntry(id: row.text("id") ?? "", draft: draft, createdBy: row.text("created_by"),
                         createdAt: row.date("created_at"), editedBy: row.text("edited_by"), editedAt: date("edited_at"),
                         state: state)
  }
}
