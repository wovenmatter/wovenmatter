import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// The conversion of the library the 0.4.6 release leaves on a device
/// (`convertEarlierLibraryUnlocked`). The fixture is that library's
/// structure exactly; each test fills it with rows of the kinds such a
/// library holds, opens it with this build, and checks what one conversion
/// did. Whatever it held, the library must end with exactly the schema of a
/// new one, and opening it again must change and copy nothing.
@Suite struct LibrarySchemaUpgradeTests {
  private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../Fixtures/library-0.4.6.sql").standardizedFileURL

  private enum ID {
    static let host = "a0000000-0000-4000-8000-000000000001", library = "b0000000-0000-4000-8000-000000000001"
    static let formerHost = "a0000000-0000-4000-8000-00000000000f", formerLibrary = "b0000000-0000-4000-8000-00000000000f"
    static let phone = "d0000000-0000-4000-8000-000000000001", tablet = "d0000000-0000-4000-8000-000000000002"
    static let retiredPhone = "d0000000-0000-4000-8000-000000000003"
    static let macWorkspace = "e0000000-0000-4000-8000-000000000001", linuxWorkspace = "e0000000-0000-4000-8000-000000000002"
    static let currentWorkspace = "e0000000-0000-4000-8000-000000000003"
    static let phoneChat = "c0000000-0000-4000-8000-000000000001", goneChat = "c0000000-0000-4000-8000-000000000002"
    static let claimedChat = "c0000000-0000-4000-8000-000000000003", macChat = "c0000000-0000-4000-8000-000000000004"
    static let linuxChat = "c0000000-0000-4000-8000-000000000005", localChat = "c0000000-0000-4000-8000-000000000006"
    static let otherChat = "c0000000-0000-4000-8000-000000000007", currentChat = "c0000000-0000-4000-8000-000000000008"
    static let tabletChat = "c0000000-0000-4000-8000-000000000009"
    static let run = "f0000000-0000-4000-8000-000000000001", goneRun = "f0000000-0000-4000-8000-000000000002"
    static let macRun = "f0000000-0000-4000-8000-000000000003"
    static let event = "9e000000-0000-4000-8000-000000000001", note = "70000000-0000-4000-8000-000000000001"
    static let artifact = "5a000000-0000-4000-8000-000000000001", macArtifact = "5a000000-0000-4000-8000-000000000002"
    static func journal(_ number: Int) -> String { String(format: "1e000000-0000-4000-8000-%012d", number) }
  }

  /// The bytes of the records a phone published, by record ID.
  private static let records: [(id: String, format: String, parts: [Data])] = [
    ("rec-usage", "pi-durable.entry.v1", [Data(#"{"id":1,"conversationId":1,"model":[]}"#.utf8)]),
    ("rec-activity", "wovenmatter.activity.v1", [Data(#"{"id":"a1","kind":"too"#.utf8), Data(#"l","title":"Read file"}"#.utf8)]),
    ("rec-chained", "wovenmatter.activity.v2", [Data(#"{"activity":{"id":"a1","contentIsDelta":false}}"#.utf8)]),
  ]

  private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func blob(_ data: Data) -> String { "X'" + data.map { String(format: "%02X", $0) }.joined() + "'" }
  private static func json<T: Encodable>(_ value: T, sorted: Bool = false) throws -> Data {
    let encoder = JSONEncoder(); if sorted { encoder.outputFormatting = [.sortedKeys] }
    return try encoder.encode(value)
  }
  private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
  private static func workspace(_ id: String, owner: String, kind: ExecutionWorkspace.Kind, library: String, deleted: Bool = false) throws -> Data {
    try json(ExecutionWorkspace(id: id, libraryID: library, ownerDeviceID: owner, kind: kind, name: kind.rawValue,
                                capabilities: ["stream.v1"], revision: 2, deleted: deleted))
  }

  /// The entries the phone's journal holds, as the phone wrote them then
  /// (`current: false`) or as it offers them again once it has updated.
  private static func phoneJournal(current: Bool) throws -> [ExecutionJournalEntry] {
    func format(_ name: String) -> String { current ? WorkspaceDatabaseConnection.currentRecordFormat(name) : name }
    var entries: [ExecutionJournalEntry] = [
      .init(eventID: ID.journal(1), workspaceID: ID.phone, originSequence: 1, conversationID: ID.phoneChat, kind: .conversation,
            conversation: .init(id: ID.phoneChat, title: "Phone chat", runtimeKind: "pi", updatedAt: "2026-11-01T10:00:00.000Z")),
      .init(eventID: ID.journal(2), workspaceID: ID.phone, originSequence: 2, conversationID: ID.phoneChat, runID: ID.run, kind: .transcript,
            transcript: try phoneTranscript()),
    ]
    for record in records.prefix(2) {
      let whole = record.parts.reduce(Data(), +)
      for (index, part) in record.parts.enumerated() {
        entries.append(.init(eventID: ID.journal(entries.count + 1), workspaceID: ID.phone, originSequence: Int64(entries.count + 1),
          conversationID: ID.phoneChat, runID: ID.run, kind: .nativeRecord,
          nativeRecord: .init(recordID: record.id, format: format(record.format), partIndex: index, partCount: record.parts.count,
                              byteCount: Int64(whole.count), sha256: sha(whole), data: part)))
      }
    }
    return entries
  }

  /// The phone chat's transcript, as the document the leftover table held.
  private static func phoneTranscript() throws -> LibraryTranscript {
    let activity = String(decoding: try json(AgentRunActivity(id: "a1", kind: .tool, title: "Read file", detail: "notes.md", status: "completed"),
                                             sorted: true), as: UTF8.self)
    return LibraryTranscript(conversationID: ID.phoneChat, messages: [
      .init(id: "m1", conversationID: ID.phoneChat, role: "user", content: "Open my notes", status: "completed",
            createdAt: "2026-11-01T10:00:00.000Z", sequence: 1),
      .init(id: "m2", conversationID: ID.phoneChat, runID: ID.run, role: "assistant", content: "Here they are.", status: "completed",
            createdAt: "2026-11-01T10:00:05.000Z", sequence: 2),
    ], activities: [
      .init(id: "a1", runID: ID.run, title: "Read file", detail: "notes.md", status: "completed", projectionJSON: activity,
            detailsRecordID: "rec-activity", sequence: 1, createdAt: "2026-11-01T10:00:02.000Z", completedAt: "2026-11-01T10:00:03.000Z"),
    ], runs: [.init(id: ID.run, status: "completed", startedAt: "2026-11-01T10:00:01.000Z", completedAt: "2026-11-01T10:00:05.000Z")],
    removedMessageIDs: ["m-tool"])
  }

  private static func journalRow(_ table: String, _ entry: ExecutionJournalEntry) throws -> String {
    let payload = try json(entry), fingerprint = Data(SHA256.hash(data: try json(entry, sorted: true)))
    return """
      INSERT INTO \(table)(event_id,workspace_id,origin_sequence,fingerprint,payload)
      VALUES('\(entry.eventID)','\(entry.workspaceID)',\(entry.originSequence),\(blob(fingerprint)),\
      \(table.hasPrefix("companion_") ? blob(payload) : quoted(String(decoding: payload, as: UTF8.self))));\n
      """
  }

  /// A library with the 0.4.6 release's structure and the rows it leaves:
  /// this library's own chats and agent-tool work, what a phone, a tablet,
  /// a Mac and a Linux host had published into the leftover tables under
  /// the library's earlier identity, and a record the current tables hold
  /// under an earlier format name.
  private func earlierLibrary() throws -> PersistenceFixture {
    let library = try PersistenceFixture()
    let sql = try PersistenceSQL(url: library.databaseURL)
    try sql.execute(try String(contentsOf: Self.fixture, encoding: .utf8))
    var rows = """
      INSERT INTO library_identity VALUES(1,'\(ID.host)','\(ID.library)');
      INSERT INTO peer_sync_clock(singleton,device_id) VALUES(1,'\(ID.host)');
      INSERT INTO workspace_revision VALUES(1,0);
      INSERT INTO activity_revision VALUES(1,0);
      INSERT INTO library_settings VALUES('activated_at','2026-11-01T00:00:00.000Z'),('revision','0');
      INSERT INTO tool_settings VALUES(1,'{"enabledByDefault":[]}');
      INSERT INTO mcp_callers(id) VALUES('woven:outside');
      INSERT INTO notes(id,title,content,created_at,updated_at) VALUES('\(ID.note)','Plan','Draft','1','1');
      INSERT INTO calendar_items(id,kind,title,starts_at,created_at,updated_at,calendar_json)
        VALUES('\(ID.event)','task','Weekly review','2026-11-20T09:00:00Z','1','1','{}');

      """
    // 0.4.6 had already recorded every shared table's rows once.
    for table in PairedLibraryTables.names where table != "execution_workspace_names" { rows += "INSERT INTO peer_sync_seeded VALUES('\(table)');\n" }
    for (id, title) in [(ID.phoneChat, "Phone chat"), (ID.claimedChat, "Claimed chat"), (ID.macChat, "Mac chat"), (ID.linuxChat, "Linux chat"),
                        (ID.localChat, "Local chat"), (ID.otherChat, "Other chat"), (ID.currentChat, "Current chat"),
                        (ID.tabletChat, "Tablet chat")] {
      rows += "INSERT INTO conversations(id,title,created_at,updated_at) VALUES('\(id)','\(title)','1','1');\n"
    }
    rows += """
      -- 0.4.6 claimed none of these chats for this Mac, and registered none as a caller.
      DELETE FROM conversation_owners;
      DELETE FROM mcp_callers WHERE id<>'woven:outside';
      INSERT INTO harness_sessions(conversation_id,runtime_kind,native_session_id,permission,created_at,updated_at)
        VALUES('\(ID.localChat)','codex','native-1','ask','1','1'),('\(ID.claimedChat)','codex','native-2',NULL,'1','1');
      INSERT INTO runs(id,conversation_id,status,created_at,updated_at) VALUES('\(ID.run)','\(ID.phoneChat)','completed','1','1');
      INSERT INTO messages(id,conversation_id,role,content,created_at,updated_at) VALUES
        ('m1','\(ID.phoneChat)','user','Open my notes','1','1'),('m2','\(ID.phoneChat)','assistant','Here they are.','2','2'),
        ('m-tool','\(ID.phoneChat)','tool','read notes.md','1','1'),('m-local','\(ID.localChat)','user','Hello','1','1');
      UPDATE messages SET run_id='\(ID.run)' WHERE id='m2';
      INSERT INTO run_activities(id,run_id,conversation_id,event_type,content,created_at)
        VALUES('a1','\(ID.run)','\(ID.phoneChat)','activity','{"id":"a1","kind":"tool"}','1');
      -- Agent-tool work whose source is a conversation.
      INSERT INTO tool_mutations VALUES('\(ID.localChat)','request-1','note.update','digest','{}');
      INSERT INTO automation_requests VALUES('\(ID.localChat)','request-2','digest');
      INSERT INTO automation_cancellations VALUES('\(ID.localChat)','request-3');
      INSERT INTO session_grants VALUES('\(ID.localChat)','\(ID.otherChat)','approved');
      INSERT INTO session_relationships(session_id,created_by,coordinator_id,purpose)
        VALUES('\(ID.otherChat)','\(ID.localChat)','\(ID.localChat)','Research');
      INSERT INTO coordination_access_requests(id,source_id,target_id,purpose,notifications,state)
        VALUES('access-1','\(ID.localChat)','\(ID.otherChat)','Research',1,'pending');
      INSERT INTO session_creations(id,source_id,target_id,arguments_json,purpose,managed)
        VALUES('creation-1','\(ID.localChat)','\(ID.otherChat)','{}','Research',1);
      INSERT INTO session_timers(id,session_id,instruction,next_fire_at) VALUES('timer-1','\(ID.localChat)','Check the build',100);

      -- The leftover tables: the library's earlier identity and its change feed.
      INSERT INTO companion_library_identity VALUES(1,'\(ID.formerHost)');
      INSERT INTO companion_workspace VALUES(1,'\(ID.formerLibrary)');
      INSERT INTO companion_versions VALUES('conversation','\(ID.phoneChat)',4242,0);
      INSERT INTO companion_changes(kind,resource_id,revision) VALUES('conversation','\(ID.phoneChat)',4242);
      INSERT INTO companion_execution_workspaces VALUES
        ('\(ID.phone)','\(ID.phone)',2,0,\(Self.blob(try Self.workspace(ID.phone, owner: ID.phone, kind: .ios, library: ID.formerLibrary)))),
        ('\(ID.tablet)','\(ID.tablet)',2,0,\(Self.blob(try Self.workspace(ID.tablet, owner: ID.tablet, kind: .ios, library: ID.formerLibrary)))),
        ('\(ID.retiredPhone)','\(ID.retiredPhone)',3,1,\(Self.blob(try Self.workspace(ID.retiredPhone, owner: ID.retiredPhone, kind: .ios, library: ID.formerLibrary, deleted: true)))),
        ('\(ID.macWorkspace)','\(ID.formerHost)',2,0,\(Self.blob(try Self.workspace(ID.macWorkspace, owner: ID.formerHost, kind: .mac, library: ID.formerLibrary)))),
        ('\(ID.linuxWorkspace)','\(ID.formerHost)',2,0,\(Self.blob(try Self.workspace(ID.linuxWorkspace, owner: ID.formerHost, kind: .linux, library: ID.formerLibrary))));

      """
    for (chat, workspace, transcript) in [(ID.phoneChat, ID.phone, try Self.phoneTranscript() as LibraryTranscript?), (ID.goneChat, ID.phone, nil),
                                          (ID.claimedChat, ID.phone, nil), (ID.tabletChat, ID.tablet, nil),
                                          (ID.macChat, ID.macWorkspace, nil), (ID.linuxChat, ID.linuxWorkspace, nil)] {
      let conversation = try Self.json(LibraryConversation(id: chat, title: "Chat", runtimeKind: "pi", updatedAt: "2026-11-01T10:00:00.000Z",
                                                           libraryID: ID.formerLibrary, workspaceID: workspace))
      rows += """
        INSERT INTO companion_execution_conversations VALUES('\(chat)','\(workspace)',0,\(Self.blob(conversation)),\
        \(try transcript.map { Self.blob(try Self.json($0)) } ?? "NULL"));\n
        """
    }
    rows += """
      INSERT INTO companion_execution_runs VALUES('\(ID.run)','\(ID.phone)','\(ID.phoneChat)'),
        ('\(ID.goneRun)','\(ID.phone)','\(ID.goneChat)'),('\(ID.macRun)','\(ID.macWorkspace)','\(ID.macChat)');

      """
    for (workspace, chat, records) in [(ID.phone, ID.phoneChat, Self.records), (ID.phone, ID.goneChat, Array(Self.records.prefix(1))),
                                       (ID.macWorkspace, ID.macChat, Array(Self.records.prefix(1)))] {
      for record in records {
        let whole = record.parts.reduce(Data(), +), id = chat == ID.phoneChat ? record.id : record.id + "-" + chat.suffix(1)
        rows += """
          INSERT INTO companion_native_history VALUES('\(workspace)','\(id)','\(chat)','\(chat == ID.phoneChat ? ID.run : "")','\(record.format)',\
          \(record.parts.count),\(whole.count),'\(Self.sha(whole))',1);\n
          """
        for (index, part) in record.parts.enumerated() {
          rows += "INSERT INTO companion_native_history_parts VALUES('\(workspace)','\(id)',\(index),\(Self.blob(part)));\n"
        }
      }
    }
    for entry in try Self.phoneJournal(current: false) { rows += try Self.journalRow("companion_execution_journal", entry) }
    // The tablet's journal: two entries this build reads, one it cannot, and one after it.
    for sequence in 1...4 {
      let entry = ExecutionJournalEntry(eventID: ID.journal(20 + sequence), workspaceID: ID.tablet, originSequence: Int64(sequence),
        conversationID: ID.tabletChat, kind: .conversation,
        conversation: .init(id: ID.tabletChat, title: "Tablet chat \(sequence)", updatedAt: "2026-11-01T10:00:00.000Z"))
      rows += sequence == 3
        ? "INSERT INTO companion_execution_journal(event_id,workspace_id,origin_sequence,fingerprint,payload) VALUES('\(entry.eventID)','\(ID.tablet)',3,X'00',\(Self.blob(Data(#"{"kind":"later"}"#.utf8))));\n"
        : try Self.journalRow("companion_execution_journal", entry)
    }
    rows += try Self.journalRow("companion_execution_journal", ExecutionJournalEntry(eventID: ID.journal(30), workspaceID: ID.macWorkspace,
      originSequence: 1, conversationID: ID.macChat, kind: .conversation,
      conversation: .init(id: ID.macChat, title: "Mac chat", updatedAt: "2026-11-01T10:00:00.000Z")))
    let chunks = [Data("Saved ".utf8), Data("file".utf8)], saved = chunks.reduce(Data(), +)
    func manifest(_ id: String, _ workspace: String) throws -> String {
      Self.blob(try Self.json(LibraryArtifactManifest(id: id, workspaceID: workspace, title: "Report", mediaType: "text/plain",
                                                      byteCount: Int64(saved.count), sha256: Self.sha(saved), revision: 1)))
    }
    rows += """
      INSERT INTO companion_saved_artifacts VALUES('\(ID.artifact)',1,\(try manifest(ID.artifact, ID.phone))),
        ('\(ID.macArtifact)',1,\(try manifest(ID.macArtifact, ID.macWorkspace)));
      INSERT INTO companion_artifact_chunks VALUES('\(ID.artifact)',1,0,\(Self.blob(chunks[0]))),('\(ID.artifact)',1,6,\(Self.blob(chunks[1]))),
        ('\(ID.macArtifact)',1,0,\(Self.blob(saved)));
      INSERT INTO companion_artifact_uploads VALUES('\(ID.artifact)',2,\(try manifest(ID.artifact, ID.phone)),3);
      INSERT INTO companion_execution_receipts VALUES('\(ID.phone)','command-1','\(ID.phone)',X'7B7D'),
        ('\(ID.macWorkspace)','command-2','\(ID.formerHost)',X'7B7D');
      INSERT INTO companion_message_provenance VALUES('m1','\(ID.otherChat)','Other chat','codex','message'),
        ('m-missing','\(ID.otherChat)',NULL,NULL,'message');
      INSERT INTO companion_mutation_receipts VALUES('\(ID.phone)','operation-1',X'01',X'7B7D'),('\(ID.formerHost)','operation-2',X'01',X'7B7D');
      INSERT INTO companion_command_receipts VALUES('\(ID.phone)','command-1',X'01',X'7B7D'),('\(ID.formerHost)','command-2',X'01',X'7B7D');
      INSERT INTO companion_tool_receipts VALUES('\(ID.phone)','request-1','\(ID.phoneChat)',X'01',X'7B7D'),
        ('\(ID.phone)','request-2','\(ID.goneChat)',X'01',X'7B7D');
      INSERT INTO companion_calendar_receipts VALUES('\(ID.phone)','mutation-1','{}','{}'),('\(ID.formerHost)','mutation-2','{}','{}');
      INSERT INTO companion_draft_receipts VALUES('draft-1','\(ID.note)','Plan','Draft','1'),('draft-2','missing-note','Lost','Draft','1');
      INSERT INTO companion_calendar_owners VALUES('\(ID.event)','\(ID.phone)','["notes"]'),('missing-event','\(ID.phone)',NULL);
      INSERT INTO companion_calendar_run_owners VALUES('\(ID.event)','\(ID.phone)'),('\(ID.event)','\(ID.formerHost)');
      INSERT INTO companion_calendar_runs VALUES('published-1','\(ID.event)','\(ID.phone)','{}'),('published-2','\(ID.event)','\(ID.formerHost)','{}');
      -- What is dropped with its table.
      INSERT INTO companion_execution_adoptions VALUES('\(ID.linuxChat)','\(ID.linuxWorkspace)',X'7B7D');
      INSERT INTO companion_retained_settlements VALUES('settled-1','\(ID.linuxWorkspace)',X'01');
      INSERT INTO companion_scheduled_mcp_callers VALUES('\(ID.run)','\(ID.phoneChat)','\(ID.phone)','\(ID.event)','2026-11-01T10:00:00Z',NULL);
      INSERT INTO companion_workspace_mcp_grants VALUES('\(ID.linuxWorkspace)',X'01',X'7B7D');
      INSERT INTO companion_workspace_publishers VALUES('\(ID.linuxWorkspace)',X'01',X'7B7D');
      INSERT INTO companion_calendar_execution_context VALUES(1,'\(ID.formerLibrary)','\(ID.phone)');
      INSERT INTO companion_calendar_execution_conflicts VALUES('\(ID.event)');

      -- A workspace 0.4.6 registered, with a record and its journal entry
      -- under an earlier format name, and a version of another entry that waits.
      INSERT INTO execution_workspaces VALUES('\(ID.currentWorkspace)','\(ID.currentWorkspace)',1,0,
        \(Self.quoted(String(decoding: try Self.workspace(ID.currentWorkspace, owner: ID.currentWorkspace, kind: .ios, library: ID.library), as: UTF8.self))));
      INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES('\(ID.currentChat)','\(ID.currentWorkspace)',
        \(Self.quoted(String(decoding: try Self.json(LibraryConversation(id: ID.currentChat, title: "Current chat", updatedAt: "1",
          libraryID: ID.library, workspaceID: ID.currentWorkspace)), as: UTF8.self))));
      INSERT INTO execution_native_history VALUES('\(ID.currentWorkspace)','rec-update','\(ID.currentChat)',NULL,'woven-native-update-v1',1,2,
        '\(Self.sha(Data("{}".utf8)))',1);

      """
    let current = Self.currentEntry(sequence: 1, format: "woven-native-update-v1"), waiting = Self.currentEntry(sequence: 2, format: "woven-native-update-v1")
    rows += try Self.journalRow("execution_journal", current)
    let record = PairedLibraryRecord(table: "execution_journal", key: "[\"\(waiting.eventID)\"]", row: [
      "event_id": .init(type: "text", value: waiting.eventID), "workspace_id": .init(type: "text", value: ID.currentWorkspace),
      "origin_sequence": .init(type: "integer", value: "2"),
      "fingerprint": .init(type: "blob", value: Data(SHA256.hash(data: try Self.json(waiting, sorted: true))).map { String(format: "%02X", $0) }.joined()),
      "payload": .init(type: "text", value: String(decoding: try Self.json(waiting), as: UTF8.self)),
    ], deleted: false, clock: 9, origin: ID.tablet, vector: [ID.tablet: 9])
    rows += """
      INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,pending_peer,payload)
      VALUES('execution_journal','\(record.key)','\(ID.tablet)',9,'\(ID.tablet)',\(Self.quoted(String(decoding: try Self.json(record), as: UTF8.self))));
      """
    try sql.execute(rows)
    try FileManager.default.createDirectory(at: library.directory.appending(path: "library-chunks"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: library.directory.appending(path: "library-chunks/" + Self.sha(Data("{}".utf8))))
    try sql.execute("INSERT INTO execution_native_history_parts VALUES('\(ID.currentWorkspace)','rec-update',0,'\(Self.sha(Data("{}".utf8)))',2)")
    return library
  }

  private static func currentEntry(sequence: Int64, format: String) -> ExecutionJournalEntry {
    let data = Data("{}".utf8)
    return .init(eventID: ID.journal(40 + Int(sequence)), workspaceID: ID.currentWorkspace, originSequence: sequence, conversationID: ID.currentChat,
                 kind: .nativeRecord, nativeRecord: .init(recordID: sequence == 1 ? "rec-update" : "rec-later", format: format, partIndex: 0,
                                                          partCount: 1, byteCount: Int64(data.count), sha256: sha(data), data: data))
  }

  /// Opens a library the way the app does: the usage index first.
  private func open(_ library: PersistenceFixture) async throws -> WorkspaceDatabase {
    _ = try UsageStore(databaseURL: library.databaseURL)
    return try await WorkspaceDatabase(url: library.databaseURL)
  }

  @Test func theEarlierLibraryEndsWithANewLibrarysSchemaAndOpensAgainUnchanged() async throws {
    let earlier = try earlierLibrary(), fresh = try PersistenceFixture(); defer { earlier.remove(); fresh.remove() }
    final class Seen: @unchecked Sendable {
      let lock = NSLock(); var values: [LibraryUpgradeProgress?] = []
      func add(_ value: LibraryUpgradeProgress?) { lock.withLock { values.append(value) } }
      var all: [LibraryUpgradeProgress?] { lock.withLock { values } }
    }
    let seen = Seen(), freshSeen = Seen()
    LibraryUpgradeMonitor.observe(earlier.databaseURL) { seen.add($0) }
    LibraryUpgradeMonitor.observe(fresh.databaseURL) { freshSeen.add($0) }
    defer { LibraryUpgradeMonitor.observe(earlier.databaseURL, nil); LibraryUpgradeMonitor.observe(fresh.databaseURL, nil) }
    let copies = WorkspaceDatabaseConnection.libraryBackupDirectory(for: earlier.databaseURL)
    func made() -> [URL] {
      ((try? FileManager.default.contentsOfDirectory(at: copies, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("before-library-conversion-") && $0.pathExtension == "sqlite" }
    }

    let expected: [String: String], actual: [String: String]
    do {
      let library = try await open(earlier), current = try await open(fresh)
      expected = try await schema(current); actual = try await schema(library)
      #expect(try await library.pairedLibrarySchema() == current.pairedLibrarySchema())
      for database in [library, current] {
        #expect(try await database.read { connection in
          try WorkspaceDatabaseConnection.libraryConversions.allSatisfy { try !$0.applies(connection) }
        })
        #expect(try await rows(database, "PRAGMA integrity_check").first?["integrity_check"]?.stringValue == "ok")
        #expect(try await rows(database, "PRAGMA foreign_key_check").isEmpty)
      }
      // The built-in agent's own tables are as they were.
      #expect(try await rows(library, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'wm\\_pi\\_%' ESCAPE '\\'").count == 10)
      #expect(try await rows(current, "SELECT name FROM sqlite_master WHERE name LIKE 'wm\\_pi\\_%' ESCAPE '\\'").isEmpty)
    }
    // One schema: every table, index and trigger a new library has and no other.
    #expect(actual.keys.sorted() == expected.keys.sorted())
    for key in expected.keys.sorted() where actual[key] != expected[key] {
      Issue.record("\(key) differs:\nconverted: \(actual[key] ?? "missing")\nnew: \(expected[key]!)")
    }
    #expect(actual.keys.allSatisfy { !$0.contains("companion_") })

    // It was copied first, as it was, and its progress was published until it was open.
    #expect(made().count == 1)
    let copy = try #require(made().first)
    #expect(try scalar(copy, "SELECT count(*) FROM sqlite_master WHERE name LIKE 'companion\\_%' ESCAPE '\\'") == 30)
    #expect(try scalar(copy, "SELECT count(*) FROM companion_execution_journal") == 10)
    #expect(try scalar(copy, "SELECT count(*) FROM pragma_quick_check WHERE quick_check='ok'") == 1)
    let reported = seen.all
    #expect(reported.last == .some(nil))
    var stages: [LibraryUpgradeProgress.Stage] = []
    for value in reported.compactMap({ $0 }) where stages.last != value.stage { stages.append(value.stage) }
    #expect(stages == [.backingUp, .converting])
    #expect(zip(reported.compactMap { $0 }, reported.compactMap { $0 }.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
    // The number an earlier release left in the file is neither read nor changed.
    #expect(try scalar(earlier.databaseURL, "PRAGMA user_version") == 3)
    #expect(try scalar(fresh.databaseURL, "PRAGMA user_version") == 0)

    // Opening the converted library again, and a new one at all, converts and copies nothing.
    let reopened: [String: String]
    do { reopened = try await schema(try await open(earlier)) }
    #expect(reopened == actual)
    #expect(made() == [copy])
    #expect(seen.all.count == reported.count)
    #expect(freshSeen.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: WorkspaceDatabaseConnection.libraryBackupDirectory(for: fresh.databaseURL).path))

    // The copy is kept for a while and then removed.
    let old = Date().addingTimeInterval(-WorkspaceDatabaseConnection.libraryBackupRetention - 60)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: copy.path)
    do { _ = try await open(earlier) }
    #expect(made().isEmpty)
  }

  @Test func whatAPhonePublishedIsAdoptedAndTheLeftoverTablesAreDropped() async throws {
    let earlier = try earlierLibrary(); defer { earlier.remove() }
    let library = try await open(earlier)
    #expect(try await rows(library, "SELECT name FROM sqlite_master WHERE name LIKE 'companion\\_%' ESCAPE '\\'").isEmpty)
    #expect(try await library.libraryIdentity().libraryID == ID.library)
    #expect(try await library.libraryIdentity().hostDeviceID == ID.host)

    // The phone's and the tablet's workspaces, under this library's ID; no Mac's, no Linux host's, none that was removed.
    let workspaces = try await library.libraryExecutionWorkspaces()
    #expect(Set(workspaces.map(\.id)) == [ID.phone, ID.tablet, ID.currentWorkspace])
    #expect(workspaces.allSatisfy { $0.libraryID == ID.library && !$0.deleted && $0.kind == .ios })
    // The chats that run on them, where the library has the chat and nothing else runs it.
    #expect(try await library.libraryExecutionOwners() == [ID.phoneChat: ID.phone, ID.tabletChat: ID.tablet, ID.currentChat: ID.currentWorkspace])
    #expect(try await string(library, "SELECT json_extract(conversation,'$.libraryID') AS v FROM execution_conversations WHERE id=?", ID.phoneChat) == ID.library)
    #expect(try await rows(library, "SELECT id FROM execution_runs").compactMap { $0["id"]?.stringValue } == [ID.run])

    // The chat's transcript is its rows, as the phone's document had it.
    let document = try Self.phoneTranscript()
    let transcript = try #require(try await library.libraryFederatedTranscript(conversationID: ID.phoneChat))
    // (The first message also has the provenance the leftover table held for it.)
    var first = document.messages[0]
    first.agentSourceID = ID.otherChat; first.isAgentAuthored = true; first.senderSessionTitle = "Other chat"
    first.senderHarness = "codex"; first.senderKind = "message"
    #expect(transcript.messages == [first, document.messages[1]])
    #expect(transcript.activities == document.activities)
    #expect(transcript.runs == document.runs)
    #expect(try await rows(library, "SELECT id FROM messages WHERE id='m-tool'").isEmpty)
    // Each recorded version of a changed row says what the row now holds.
    for (id, position) in [("m1", "1"), ("m2", "2")] {
      #expect(try await string(library, "SELECT json_extract(payload,'$.row.position.value') AS v FROM peer_sync_versions WHERE table_name='messages' AND record_key=?",
                               "[\"\(id)\"]") == position)
    }
    #expect(try await string(library, "SELECT json_extract(payload,'$.row.title.value') AS v FROM peer_sync_versions WHERE table_name='run_activities' AND record_key='[\"a1\"]'") == "Read file")
    #expect(try await string(library, "SELECT json_extract(payload,'$.deleted') AS v FROM peer_sync_versions WHERE table_name='messages' AND record_key='[\"m-tool\"]'") == "1")
    // An adopted row is not a new version for peers.
    let recorded = try await rows(library, """
      SELECT table_name||' '||record_key AS version FROM peer_sync_versions
      WHERE table_name IN ('execution_runs','saved_artifacts','artifact_chunks','message_provenance','calendar_task_executors')
        OR record_key LIKE '%\(ID.phone)%' OR record_key LIKE '%\(ID.tablet)%' OR (table_name='execution_conversations' AND record_key LIKE '%\(ID.phoneChat)%')
      """).compactMap { $0["version"]?.stringValue }
    #expect(recorded.isEmpty, "\(recorded)")

    // Its native history: each record under its format's current name, its bytes read back from the chunk store.
    for record in Self.records {
      let name = WorkspaceDatabaseConnection.currentRecordFormat(record.format)
      #expect(name != record.format)
      let stored = try await library.libraryNativeRecords(workspaceID: ID.phone, format: name)
      #expect(stored.map(\.recordID) == [record.id])
      #expect(stored.first?.data == record.parts.reduce(Data(), +))
    }
    #expect(try await rows(library, "SELECT record_id FROM execution_native_history WHERE workspace_id=?", ID.phone).count == 3)
    #expect(try await rows(library, "SELECT record_id FROM execution_native_history WHERE workspace_id=?", ID.macWorkspace).isEmpty)
    let details = try #require(try await library.libraryNativeHistoryPart(workspaceID: ID.phone, recordID: "rec-activity", partIndex: 1))
    #expect(details.format == "wovenmatter.activity" && details.data == Self.records[1].parts[1])

    // Its journal, so the phone's entries are recognised when it offers them
    // again and its next one follows the last; the tablet's as far as this
    // build reads it, so the tablet uploads the rest again; no Mac's.
    #expect(try await rows(library, "SELECT origin_sequence FROM execution_journal WHERE workspace_id=? ORDER BY origin_sequence", ID.phone)
      .compactMap { $0["origin_sequence"]?.intValue } == [1, 2, 3, 4, 5])
    #expect(try await library.libraryExecutionOriginCursor(workspaceID: ID.tablet) == 2)
    #expect(try await library.libraryExecutionOriginCursor(workspaceID: ID.macWorkspace) == 0)
    let offered = try Self.phoneJournal(current: true)
    #expect(try await library.executionJournal(after: 0).entries.filter { $0.workspaceID == ID.phone } == offered)
    let again = try await library.ingestExecutionJournal(.init(libraryID: ID.library, entries: offered), deviceID: ID.phone)
    #expect(again.acceptedEventIDs == offered.map(\.eventID))
    var next = try Self.phoneTranscript(); next.runs = nil; next.activities = []; next.removedMessageIDs = nil
    next.messages = [.init(id: "m3", conversationID: ID.phoneChat, role: "user", content: "Thanks", status: "completed",
                           createdAt: "2026-11-02T10:00:00.000Z", sequence: 3)]
    _ = try await library.ingestExecutionJournal(.init(libraryID: ID.library, entries: [
      .init(eventID: ID.journal(6), workspaceID: ID.phone, originSequence: 6, conversationID: ID.phoneChat, kind: .transcript, transcript: next),
    ]), deviceID: ID.phone)
    #expect(try await library.libraryExecutionOriginCursor(workspaceID: ID.phone) == 6)
    #expect(try await library.libraryFederatedTranscript(conversationID: ID.phoneChat)?.messages.map(\.id) == ["m1", "m2", "m3"])

    // The files it saved, and the receipts, provenance and schedules that name what the library still has.
    #expect(try await library.librarySavedArtifacts().map(\.id) == [ID.artifact])
    #expect(try await rows(library, "SELECT sha256,byte_count FROM artifact_chunks ORDER BY offset").map { $0["sha256"]?.stringValue }
      == [Self.sha(Data("Saved ".utf8)), Self.sha(Data("file".utf8))])
    #expect(FileManager.default.fileExists(atPath: earlier.directory.appending(path: "library-chunks/" + Self.sha(Data("file".utf8))).path))
    #expect(try await rows(library, "SELECT id FROM artifact_uploads").isEmpty)
    for (table, kept) in [("execution_receipts", 1), ("message_provenance", 1), ("device_mutation_receipts", 1), ("device_command_receipts", 1),
                          ("device_tool_receipts", 1), ("device_calendar_receipts", 1), ("device_draft_receipts", 1),
                          ("calendar_task_executors", 1), ("calendar_run_publishers", 1), ("calendar_published_runs", 1),
                          ("execution_adoptions", 0), ("execution_retained_settlements", 0), ("device_scheduled_mcp_callers", 0)] {
      #expect(try await rows(library, "SELECT * FROM \(table)").count == kept, "\(table)")
    }
    #expect(try await string(library, "SELECT typeof(response)||':'||response AS v FROM device_mutation_receipts") == "text:{}")
    #expect(try await string(library, "SELECT device_id AS v FROM calendar_task_executors WHERE event_id=?", ID.event) == ID.phone)
    // The change feed counts from the library's present identity.
    #expect(try await rows(library, "SELECT revision FROM device_sync_revisions WHERE revision=4242").isEmpty)
  }

  @Test func tablesDeclaredAsAnEarlierReleaseCreatedThemAreRebuiltWithTheirRows() async throws {
    let earlier = try earlierLibrary(); defer { earlier.remove() }
    // As 0.4.6 left them: a source references conversations, a timer has no
    // `outside_mcp`, and a session's permission follows its dates.
    #expect(try scalar(earlier.databaseURL, "SELECT count(*) FROM pragma_foreign_key_list('tool_mutations') WHERE \"table\"='conversations'") == 1)
    #expect(try scalar(earlier.databaseURL, "SELECT count(*) FROM pragma_table_info('session_timers') WHERE name='outside_mcp'") == 0)
    let library = try await open(earlier)
    for (table, column) in [("tool_mutations", "source_id"), ("automation_requests", "source_id"), ("automation_cancellations", "source_id"),
                            ("session_grants", "source_id"), ("session_relationships", "created_by"), ("session_relationships", "coordinator_id"),
                            ("coordination_access_requests", "source_id"), ("session_creations", "source_id")] {
      #expect(try await string(library, "SELECT \"table\" AS v FROM pragma_foreign_key_list('\(table)') WHERE \"from\"=?", column) == "mcp_callers", "\(table)")
      #expect(try await string(library, "SELECT \(column) AS v FROM \(table)") == ID.localChat, "\(table)")
    }
    #expect(try await rows(library, "SELECT * FROM pragma_foreign_key_list('session_timers')").isEmpty)
    #expect(try await rows(library, "SELECT outside_mcp,instruction FROM session_timers").first
      == ["outside_mcp": .number(0), "instruction": .string("Check the build")])
    // Every conversation is a caller, as it is in a new library.
    #expect(try await rows(library, "SELECT id FROM conversations WHERE id NOT IN (SELECT id FROM mcp_callers)").isEmpty)
    #expect(try await rows(library, "SELECT name FROM pragma_table_info('harness_sessions') ORDER BY cid").compactMap { $0["name"]?.stringValue }
      == ["conversation_id", "agent_id", "runtime_kind", "revision", "native_session_id", "model", "thinking", "permission",
          "remote_workspace_id", "created_at", "updated_at"])
    #expect(try await string(library, "SELECT permission||':'||native_session_id AS v FROM harness_sessions WHERE conversation_id=?", ID.localChat) == "ask:native-1")
    #expect(try await string(library, "SELECT title||':'||calendar_json AS v FROM calendar_items WHERE id=?", ID.event) == "Weekly review:{}")
    // The rebuilt tables work as a new library's do: a source may be a caller that is no conversation.
    try await library.write { try $0.toolsExecuteUnlocked("INSERT INTO tool_mutations VALUES('woven:outside','request-9','note.update','digest','{}')") }
  }

  @Test func recordsUnderEarlierFormatNamesTakeTheirCurrentNames() async throws {
    let earlier = try earlierLibrary(); defer { earlier.remove() }
    let library = try await open(earlier)
    let earlierNames = WorkspaceDatabaseConnection.earlierRecordFormats.map(\.earlier)
    #expect(try await rows(library, "SELECT DISTINCT format FROM execution_native_history ORDER BY format").compactMap { $0["format"]?.stringValue }
      == ["pi-durable.entry", "woven-native-update", "wovenmatter.activity", "wovenmatter.activity.chained"])
    #expect(try await library.libraryNativeRecords(workspaceID: ID.currentWorkspace, format: "woven-native-update").map(\.recordID) == ["rec-update"])
    // No journal entry and no recorded version, applied or waiting, names an earlier format.
    for table in ["execution_journal", "peer_sync_versions"] {
      let payloads = try await rows(library, "SELECT payload FROM \(table)").compactMap { $0["payload"]?.stringValue }
      #expect(!payloads.isEmpty && payloads.allSatisfy { payload in earlierNames.allSatisfy { !payload.contains("\"" + $0 + "\"") && !payload.contains("\\\"" + $0 + "\\\"") } }, "\(table)")
    }
    // The entry reads back under the current name, and offering it again is recognised by its fingerprint.
    let entry = Self.currentEntry(sequence: 1, format: "woven-native-update")
    #expect(try await library.executionJournal(after: 0).entries.filter { $0.workspaceID == ID.currentWorkspace } == [entry])
    let again = try await library.ingestExecutionJournal(.init(libraryID: ID.library, entries: [entry]), deviceID: ID.currentWorkspace)
    #expect(again.acceptedEventIDs == [entry.eventID])
    // Its applied version and the version that waits carry the entry as the row would hold it.
    let waiting = Self.currentEntry(sequence: 2, format: "woven-native-update")
    for (event, expected) in [(entry, entry), (waiting, waiting)] {
      let payload = try #require(try await string(library, "SELECT payload AS v FROM peer_sync_versions WHERE table_name='execution_journal' AND record_key=?",
                                                  "[\"\(event.eventID)\"]"))
      let record = try JSONDecoder().decode(PairedLibraryRecord.self, from: Data(payload.utf8))
      #expect(try JSONDecoder().decode(ExecutionJournalEntry.self, from: Data(try #require(record.row["payload"]?.value).utf8)) == expected)
      #expect(record.row["fingerprint"]?.value == Data(SHA256.hash(data: try Self.json(expected, sorted: true))).map { String(format: "%02X", $0) }.joined())
    }
    #expect(try await string(library, "SELECT json_extract(payload,'$.row.format.value') AS v FROM peer_sync_versions WHERE table_name='execution_native_history'") == "woven-native-update")
  }

  // MARK: Reading a library

  /// The integer in the first column of `sql`'s first row, read through a plain connection.
  private func scalar(_ url: URL, _ sql: String) throws -> Int {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let connection else { throw WorkspaceDatabaseError.open(url.path) }
    defer { sqlite3_close(connection) }
    sqlite3_busy_timeout(connection, 5_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw WorkspaceDatabaseError.prepare(sql) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceDatabaseError.step(String(cString: sqlite3_errmsg(connection))) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  /// Everything the library itself declares, by type and name. A table is
  /// its declaration without what SQLite's own `ALTER TABLE` leaves in one:
  /// quotes around a name it rewrote and the spacing where it added a
  /// column. Indexes and triggers, which this build creates, are their text.
  private func schema(_ database: WorkspaceDatabase) async throws -> [String: String] {
    try await database.read { connection in
      var result: [String: String] = [:]
      for object in try connection.historyRowsUnlocked("""
        SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL AND \(WorkspaceDatabaseConnection.libraryOwnTable("tbl_name"))
          AND name NOT LIKE 'history\\_search\\_%' ESCAPE '\\'
        """, values: []).compactMap(\.objectValue) {
        guard let type = object["type"]?.stringValue, let name = object["name"]?.stringValue, var sql = object["sql"]?.stringValue else { continue }
        sql = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if type == "table" {
          sql = sql.replacingOccurrences(of: #""([A-Za-z_][A-Za-z0-9_]*)""#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #" ?([(),]) ?"#, with: "$1", options: .regularExpression)
        }
        result[type + " " + name] = sql
      }
      return result
    }
  }

  private func rows(_ database: WorkspaceDatabase, _ sql: String, _ values: String...) async throws -> [[String: JSONValue]] {
    try await database.read { try $0.historyRowsUnlocked(sql, values: values).compactMap(\.objectValue) }
  }

  /// Column `v` of the first row of `sql`, as text.
  private func string(_ database: WorkspaceDatabase, _ sql: String, _ values: String...) async throws -> String? {
    let value = try await database.read { try $0.historyRowsUnlocked(sql, values: values).first?.objectValue?["v"] }
    if case .number(let number) = value { return String(Int(number)) }
    return value?.stringValue
  }
}
