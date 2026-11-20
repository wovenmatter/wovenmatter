import Foundation
import WovenProtocol

/// How a table's rows travel between machines.
public enum SyncRule: Sendable, Equatable {
  /// Never leaves this machine.
  case local
  /// Written once by the owning machine, never edited.
  case appendOnly
  /// A received row replaces the local one when its stamp is newer.
  case newestWins
  /// Newest wins; when two writes were made apart, the loser is saved as a
  /// row of the `history` table.
  case newestWinsKeepLoser(history: String)
}

public enum ColumnType: String, Sendable {
  case text = "TEXT"
  case integer = "INTEGER"
  case real = "REAL"
  case blob = "BLOB"
}

public struct Column: Sendable {
  public let name: String
  public let type: ColumnType
  /// When set, the column is NOT NULL with this default, so it can always be
  /// added to an existing file.
  public let fallback: SQLValue?
  let primaryKey: Bool

  static func text(_ name: String, _ fallback: String? = nil) -> Column {
    Column(name: name, type: .text, fallback: fallback.map(SQLValue.text), primaryKey: false)
  }
  static func integer(_ name: String, _ fallback: Int64? = nil) -> Column {
    Column(name: name, type: .integer, fallback: fallback.map(SQLValue.integer), primaryKey: false)
  }
  static func real(_ name: String, _ fallback: Double? = nil) -> Column {
    Column(name: name, type: .real, fallback: fallback.map(SQLValue.real), primaryKey: false)
  }
  static func blob(_ name: String) -> Column {
    Column(name: name, type: .blob, fallback: nil, primaryKey: false)
  }
  static func key(_ name: String, _ type: ColumnType = .text) -> Column {
    Column(name: name, type: type, fallback: nil, primaryKey: true)
  }

  var definition: String {
    var sql = "\(name) \(type.rawValue)"
    if primaryKey { sql += " PRIMARY KEY NOT NULL" }
    if let fallback { sql += " NOT NULL DEFAULT \(fallback.literal)" }
    return sql
  }
}

/// A column that names a row of another table that this row belongs to.
/// When that row is deleted, this one goes too, and a late copy of this one
/// is not accepted. The writer does it in code, in the same transaction.
public struct Parent: Sendable {
  public let column: String
  public let table: String
}

public struct Table: Sendable {
  public let name: String
  public let rule: SyncRule
  /// The table's own columns. Synced tables also get the standard ones.
  public let columns: [Column]
  public let parents: [Parent]
  /// For a table whose `id` is a natural key rather than generated, the
  /// columns that make up that key. Such a row is never deleted: unsetting it
  /// clears its other columns with a new stamp, so it can be set again.
  let naturalKey: [String]?
  let indexes: [[String]]

  init(_ name: String, _ rule: SyncRule, _ columns: [Column], parents: [Parent] = [], naturalKey: [String]? = nil,
       indexes: [[String]] = []) {
    self.name = name
    self.rule = rule
    self.columns = columns
    self.parents = parents
    self.naturalKey = naturalKey
    self.indexes = indexes
  }

  public var synced: Bool { rule != .local }

  var keepsLoser: Bool {
    if case .newestWinsKeepLoser = rule { true } else { false }
  }

  /// `id`, `stamp`, `changed` and `deleted` on every synced row.
  static let standardColumns: Set<String> = ["id", "stamp", "changed", "deleted"]

  var allColumns: [Column] {
    guard synced else { return columns }
    return [.key("id"), .text("stamp", ""), .integer("changed", 0), .integer("deleted", 0)] + columns
  }

  var allIndexes: [[String]] {
    (synced ? [["changed"]] : []) + parents.map { [$0.column] } + indexes
  }

  var createSQL: String {
    "CREATE TABLE \(name) (\(allColumns.map(\.definition).joined(separator: ", ")))"
  }
}

extension SQLValue {
  /// The value as an SQL literal, for DEFAULT clauses.
  var literal: String {
    switch self {
    case .null: "NULL"
    case .integer(let value): String(value)
    case .real(let value): String(value)
    case .text(let value): "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    case .blob(let value): "X'\(value.map { String(format: "%02x", $0) }.joined())'"
    }
  }
}

/// The whole library, declared once. At open the file is compared with this
/// and whatever is missing is added. There is no schema counter.
public enum Schema {
  public static let tables: [Table] = [
    // Newest write wins.
    Table("machines", .newestWins, [
      .text("name", ""),
      // "mac" or "linux".
      .text("platform", "mac"),
      // Sealed secrets for this machine are sealed with this key.
      .text("public_key"),
      .integer("created_at", 0),
      // A Linux machine installed from a Mac: the SSH host and user given at
      // install, which every later SSH action on it reuses exactly.
      .text("ssh_host", ""),
      .text("ssh_user", ""),
    ]),
    Table("sessions", .newestWins, [
      .text("machine_id", ""),
      .text("runtime", ""),
      .text("title", ""),
      .text("folder_id"),
      // Where the runtime works on the owning machine.
      .text("directory", ""),
      // The last model, thinking level and permission mode chosen.
      .text("model"),
      .text("thinking"),
      .text("permission"),
      .integer("archived", 0),
      // When it was last moved to Trash.
      .integer("archived_at", 0),
      .integer("pinned", 0),
      // The newest item the person has seen, by its `created_at`.
      .integer("read_at", 0),
      .text("goal"),
      // The tool groups it may use, as a JSON array; null follows the defaults.
      .text("tools"),
      .integer("created_at", 0),
    ], parents: [Parent(column: "machine_id", table: "machines")]),
    Table("folders", .newestWins, [
      .text("machine_id", ""),
      .text("name", ""),
      .text("path", ""),
      .integer("pinned", 0),
      // Order in the sidebar among the machine's folders.
      .integer("position", 0),
      // The server made the directory, so deleting the folder may delete it.
      .integer("managed", 0),
      // Other directories on the machine its agents may use, as a JSON array.
      .text("other_directories", "[]"),
      .integer("created_at", 0),
    ], parents: [Parent(column: "machine_id", table: "machines")]),
    // `id` is the setting's key, so two machines setting one key write one row.
    Table("settings", .newestWins, [
      .text("value", "null"),
    ], naturalKey: []),
    // Scheduled tasks, calendar events, timers and wake-ups; each belongs to
    // the machine that runs it, and only that machine writes it. What has
    // fired is local state (`schedule_state`).
    Table("schedules", .newestWins, [
      .text("machine_id", ""),
      // "task", "event", "timer" or "wakeUp".
      .text("kind", ""),
      .text("title", ""),
      .text("details", ""),
      .text("prompt", ""),
      .text("session_id"),
      .integer("new_session", 0),
      .text("folder_id"),
      .text("runtime"),
      .text("directory"),
      .text("model"),
      .text("thinking"),
      .text("permission"),
      .integer("starts_at"),
      .integer("ends_at"),
      .integer("all_day", 0),
      .text("time_zone", ""),
      // `Recurrence` as JSON.
      .text("recurrence"),
      // Excluded occurrence indexes, as a JSON array.
      .text("excluded", "[]"),
      .integer("on_calendar", 1),
      .integer("enabled", 1),
      .text("created_by"),
      .text("edited_by"),
      .integer("edited_at"),
      .integer("created_at", 0),
    ], parents: [Parent(column: "machine_id", table: "machines")]),
    // One API key sealed for one machine. `id` is `name:machine_id`, so
    // sealing the same key twice for a machine writes one row.
    Table("sealed_secrets", .newestWins, [
      .text("name", ""),
      .text("machine_id", ""),
      .blob("sealed"),
    ], parents: [Parent(column: "machine_id", table: "machines")], naturalKey: ["name", "machine_id"]),
    // A database's description and its latest published copy, by digest.
    Table("databases", .newestWins, [
      .text("machine_id", ""),
      .text("name", ""),
      .text("description", ""),
      .text("copy_digest"),
      .integer("copy_size"),
      .integer("copied_at"),
      .integer("created_at", 0),
    ], parents: [Parent(column: "machine_id", table: "machines")]),
    // The bots, as their home machine's runtime reports them, so any machine
    // can list them and read their chats while the home machine is away.
    // `id` is the bot's own identifier; `machine_id` is the home machine.
    Table("bots", .newestWins, [
      .text("machine_id", ""),
      .text("name", ""),
      // "admin" or "bot".
      .text("kind", "bot"),
      .integer("manager", 0),
      .text("manager_id"),
      .integer("orchestrator", 0),
      // Deleted in the runtime but restorable there.
      .integer("trashed", 0),
      .integer("created_at", 0),
    ], parents: [Parent(column: "machine_id", table: "machines")]),
    // Which bot conversation or Forum room a session holds. `id` is the
    // session's identifier.
    Table("bot_chats", .newestWins, [
      .text("session_id", ""),
      // Empty for a Forum room.
      .text("bot_id", ""),
      // The runtime's conversation, or the Forum room.
      .integer("conversation_id", 0),
      // "main", "thread", "forum" (the Forum itself) or "forumThread".
      .text("kind", ""),
      .integer("parent_conversation_id"),
    ], parents: [Parent(column: "session_id", table: "sessions")]),

    // Newest write wins, loser kept: notes, pages and apps.
    Table("artifacts", .newestWinsKeepLoser(history: "artifact_versions"), [
      .text("kind", ""),
      .text("title", ""),
      .text("folder_id"),
      // The document, including an app's saved state.
      .text("body", ""),
      // One line under the title, taken from the document when it is written.
      .text("preview", ""),
      .integer("pinned", 0),
      // In the Trash; deleting it for good deletes the row.
      .integer("trashed", 0),
      .integer("created_at", 0),
      // What this version had seen: each machine's identifier and the latest
      // stamp of that machine's included in it, as a JSON object with sorted
      // keys. The writer keeps it; a write's own values for it are ignored.
      .text("seen", "{}"),
    ]),

    // Append-only.
    // `id` is `artifact_id:version_stamp`, so every machine that saves the
    // same loser saves the same row.
    Table("artifact_versions", .appendOnly, [
      .text("artifact_id", ""),
      .text("version_stamp", ""),
      .text("kind", ""),
      .text("title", ""),
      .text("body", ""),
      .text("preview", ""),
      .integer("pinned", 0),
      .integer("trashed", 0),
      // Why it was saved: "conflict", "checkpoint" or "restore".
      .text("reason", "conflict"),
      .integer("saved_at", 0),
    ], parents: [Parent(column: "artifact_id", table: "artifacts")]),
    Table("session_items", .appendOnly, [
      .text("session_id", ""),
      .integer("sequence", 0),
      .text("kind", ""),
      // The item's content as JSON (`ItemContent`).
      .text("body", ""),
      // Who said it, as JSON (`ItemAuthor`), in a chat with several speakers.
      .text("author"),
      .integer("created_at", 0),
    ], parents: [Parent(column: "session_id", table: "sessions")], indexes: [["session_id", "sequence"]]),
    // Usage of every harness on the machine that wrote it. A harness that
    // keeps its own history (Codex, Claude Code, Grok Build, OpenCode, the Pi
    // CLI) is counted only from that history, one row per session, model and
    // hour; Pi Durable writes one row per turn and bots one per model turn.
    Table("usage_records", .appendOnly, [
      .text("machine_id", ""),
      // The Woven Matter session, when the usage was one.
      .text("session_id"),
      // The harness's own session identifier, for usage read from its history.
      .text("native_session"),
      // Made inside Woven Matter.
      .integer("woven", 1),
      .text("runtime", ""),
      .text("model", ""),
      .integer("input_tokens", 0),
      .integer("output_tokens", 0),
      .integer("cache_read_tokens", 0),
      .integer("cache_write_tokens", 0),
      .real("cost", 0),
      .integer("requests", 1),
      // The newest response the row counts.
      .integer("recorded_at", 0),
    ], indexes: [["recorded_at"]]),
    Table("dictation_history", .appendOnly, [
      .text("machine_id", ""),
      .text("text", ""),
      .real("duration", 0),
      .text("audio_digest"),
      .integer("recorded_at", 0),
    ], indexes: [["recorded_at"]]),

    // Never syncs.
    // One row: this machine's identifier, its clock and its `changed` counter.
    // `removed` is set when another machine removed this one; at the next
    // start the library is erased and begins again.
    Table("this_machine", .local, [
      .key("id"),
      .text("clock", ""),
      .integer("changed", 0),
      .integer("removed", 0),
    ]),
    // How far this library has received each other machine's rows.
    Table("sync_cursors", .local, [
      .key("machine_id"),
      .integer("received", 0),
    ]),
    // The runtime's own handle for each session this machine owns.
    Table("native_sessions", .local, [
      .key("session_id"),
      .text("runtime", ""),
      .text("handle", ""),
      // The runtime said the native session no longer exists.
      .integer("gone", 0),
      // A turn is running. Still set at start, the server stopped mid-turn.
      .integer("turn_running", 0),
      .integer("updated_at", 0),
    ]),
    // How far the bots runtime's finished entries are saved here: "bot:<id>"
    // for a bot's conversations, "forum" for the Forum. Kept by the library,
    // not the bots' folder, so bots moved to another machine save their
    // history again there, in sessions that machine owns.
    Table("bot_checkpoints", .local, [
      .key("key"),
      .integer("entry", 0),
    ]),
    // How far this machine's harness histories have been read, by a digest
    // of the file's path (paths never enter the library): the bytes read, the
    // file's size, change time and identity when read, and the reader's
    // state at that point as JSON.
    Table("usage_sources", .local, [
      .key("id"),
      .integer("offset", 0),
      .integer("size", 0),
      .integer("modified", 0),
      .text("identity", ""),
      .text("state", ""),
    ]),
    // Usage read from the histories for an hour not yet over, summed per
    // harness session and model. A row moves to `usage_records` once its hour
    // has passed; the Usage page reads both.
    Table("usage_pending", .local, [
      .key("id"),
      .text("runtime", ""),
      .text("native_session", ""),
      .integer("woven", 0),
      .text("model", ""),
      .integer("hour", 0),
      .integer("input_tokens", 0),
      .integer("output_tokens", 0),
      .integer("cache_read_tokens", 0),
      .integer("cache_write_tokens", 0),
      .real("cost", 0),
      .integer("requests", 0),
      .integer("recorded_at", 0),
    ]),
    // Responses already counted, by the harness's own identifier, so a copy
    // in a forked or resumed session's file or a file read again counts
    // once. Forgotten after 60 days.
    Table("usage_seen", .local, [
      .key("id"),
      .integer("seen_at", 0),
    ], indexes: [["seen_at"]]),
    // What this machine's scheduler has fired of each entry it owns.
    // `stamp` is the entry's stamp `next_fire_at` was worked out from.
    Table("schedule_state", .local, [
      .key("schedule_id"),
      .text("stamp", ""),
      .integer("next_fire_at"),
      // The scheduled time of the occurrence last fired, and when it fired.
      .integer("last_fired_at"),
      .integer("fired_at"),
      .text("session_id"),
      .text("error"),
    ]),
    // The content store's index: files this machine holds, by digest.
    Table("files", .local, [
      .key("digest"),
      .integer("size", 0),
      .integer("added_at", 0),
    ]),
  ]

  static let byName: [String: Table] = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
  public static let synced: [Table] = tables.filter(\.synced)

  /// Brings the file up to the declaration: creates missing tables, adds
  /// missing columns and indexes. Never removes or rewrites anything.
  static func apply(to connection: Connection) throws {
    for table in tables {
      let existing = Set(try connection.query("SELECT name FROM pragma_table_info(?)", [.text(table.name)])
        .compactMap { $0.text("name") })
      if existing.isEmpty {
        try connection.execute(table.createSQL)
      } else {
        for column in table.allColumns where !existing.contains(column.name) {
          try connection.execute("ALTER TABLE \(table.name) ADD COLUMN \(column.definition)")
        }
      }
      for columns in table.allIndexes {
        let name = ([table.name] + columns).joined(separator: "_")
        try connection.execute("CREATE INDEX IF NOT EXISTS \(name) ON \(table.name) (\(columns.joined(separator: ", ")))")
      }
    }
  }
}
