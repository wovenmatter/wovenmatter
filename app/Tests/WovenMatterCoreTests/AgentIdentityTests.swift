#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// One agent row stands for a harness in a place. It is found by what it
/// is, so the rows a library already holds are used whatever their IDs are,
/// and no second row is made for one (`agentIDUnlocked`).
@Suite("One agent row per harness and place") struct AgentIdentityTests {
  private struct Row: Equatable { let id: String, kind: String, location: String, workspace: String?, deleted: Bool }

  private static func rows(_ database: WorkspaceDatabase) async throws -> [Row] {
    try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT id,runtime_kind,execution_location,runtime_device_id,deleted_at FROM agents ORDER BY id", values: [])
        .compactMap(\.objectValue).map {
          Row(id: $0["id"]?.stringValue ?? "", kind: $0["runtime_kind"]?.stringValue ?? "", location: $0["execution_location"]?.stringValue ?? "",
              workspace: $0["runtime_device_id"]?.stringValue, deleted: $0["deleted_at"]?.stringValue != nil)
        }
    }
  }
  private static func owners(_ database: WorkspaceDatabase) async throws -> [String: String] {
    try await database.read { connection in
      Dictionary(uniqueKeysWithValues: try connection.historyRowsUnlocked("SELECT id,device_id FROM agent_owners", values: [])
        .compactMap(\.objectValue).map { ($0["id"]?.stringValue ?? "", $0["device_id"]?.stringValue ?? "") })
    }
  }
  /// A stored agent row with no owner record, as the libraries in use hold them.
  private static func insert(_ database: WorkspaceDatabase, id: String = UUID().uuidString.lowercased(), owner: UUID, kind: AgentRuntimeKind,
                             workspace: String? = nil, created: String = "2026-01-01T00:00:00.000Z", deleted: String? = nil) async throws {
    try await database.write { connection in
      try connection.toolsExecuteUnlocked("""
        INSERT INTO agents(id,codename,display_name,icon,execution_location,owner_device_id,runtime_kind,runtime_device_id,status,revision,deleted_at,created_at,updated_at)
        VALUES(?,?,?,'terminal',?,?,?,?,'ready',1,?,?,?)
        """, [id, "stored-" + kind.rawValue, "Stored " + kind.rawValue, workspace == nil ? "local" : "remote", owner.uuidString.lowercased(),
              kind.rawValue, workspace, deleted, created, created])
      try connection.toolsExecuteUnlocked("DELETE FROM agent_owners WHERE id=?", [id])
    }
  }
  /// The ID an earlier build gave a harness's row: test data only.
  private static func earlierID(_ seed: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
  }
  private static var kinds: [AgentRuntimeKind] { LocalACPRuntimeCatalog.definitions.map(\.runtimeKind) }
  private static func agent(of chat: String, _ database: WorkspaceDatabase) async throws -> String? {
    try await database.read { try $0.historyRowsUnlocked("SELECT agent_id FROM conversations WHERE id=?", values: [chat]).first?.objectValue?["agent_id"]?.stringValue }
  }

  @Test(arguments: [true, false])
  func storedRowsAreUsedAndClaimedWhateverTheirIDsAre(earlier: Bool) async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let device = UUID(), host = try await database.libraryIdentity().hostDeviceID
    #expect(Self.kinds.count > 1)
    var own = Set<String>()
    for kind in Self.kinds {
      let id = earlier ? Self.earlierID("wovenmatter.local-cli-agent.v1:\(device.uuidString.lowercased()):\(kind.rawValue)") : UUID().uuidString.lowercased()
      try await Self.insert(database, id: id, owner: device, kind: kind)
      own.insert(id)
    }
    // Another Mac's rows for the same harnesses, received without owner records.
    let other = UUID()
    for kind in Self.kinds { try await Self.insert(database, owner: other, kind: kind) }
    let stored = try await Self.rows(database)
    #expect(try await Self.owners(database).isEmpty)

    try await database.reconcileLocalCLIAgentCatalog(ownerDeviceID: device)
    #expect(try await Self.rows(database) == stored)
    #expect(try await Self.owners(database) == Dictionary(uniqueKeysWithValues: own.map { ($0, host) }))
    // A new chat uses the stored row, and opening again changes nothing.
    let chat = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "After the update", ownerDeviceID: device)
    #expect(try await own.contains(#require(try await Self.agent(of: chat, database))))
    let head = try await database.peerSyncHead()
    let again = try await WorkspaceDatabase(url: database.fileURL)
    try await again.reconcileLocalCLIAgentCatalog(ownerDeviceID: device)
    #expect(try await Self.rows(again) == stored)
    #expect(try await again.peerSyncHead() == head)
  }

  @Test func aRowInUseComesBeforeARetiredOneAndTheEarliestBeforeALaterOne() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let device = UUID()
    let retired = "00000000-0000-4000-8000-000000000001", first = "ffffffff-0000-4000-8000-000000000002", later = "00000000-0000-4000-8000-000000000003"
    try await Self.insert(database, id: retired, owner: device, kind: .codex, created: "2025-01-01T00:00:00.000Z", deleted: "2025-06-01T00:00:00.000Z")
    try await Self.insert(database, id: first, owner: device, kind: .codex, created: "2025-02-01T00:00:00.000Z")
    try await Self.insert(database, id: later, owner: device, kind: .codex, created: "2025-03-01T00:00:00.000Z")
    // A harness whose only row was retired gets that row back, not a second one.
    let only = "00000000-0000-4000-8000-000000000004"
    try await Self.insert(database, id: only, owner: device, kind: .claudeCode, deleted: "2025-06-01T00:00:00.000Z")
    try await database.reconcileLocalCLIAgentCatalog(ownerDeviceID: device)
    let rows = try await Self.rows(database)
    #expect(rows.filter { $0.kind == AgentRuntimeKind.codex.rawValue }.map(\.id).sorted() == [retired, later, first].sorted())
    #expect(rows.first { $0.id == retired }?.deleted == true)
    #expect(rows.filter { $0.kind == AgentRuntimeKind.claudeCode.rawValue } == [.init(id: only, kind: "claude_code", location: "local", workspace: nil, deleted: false)])
    #expect(rows.count == Self.kinds.count + 2)
    let chat = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Chat", ownerDeviceID: device)
    #expect(try await Self.agent(of: chat, database) == first)
  }

  @Test func aRowAnotherLibraryHostOwnsIsThatHosts() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let device = UUID(), foreign = UUID().uuidString.lowercased(), elsewhere = UUID().uuidString.lowercased()
    try await Self.insert(database, id: foreign, owner: device, kind: .codex)
    try await database.write { try $0.toolsExecuteUnlocked("INSERT INTO agent_owners(id,device_id) VALUES(?,?)", [foreign, elsewhere]) }
    try await database.reconcileLocalCLIAgentCatalog(ownerDeviceID: device)
    let codex = try await Self.rows(database).filter { $0.kind == AgentRuntimeKind.codex.rawValue }
    #expect(codex.count == 2)
    #expect(try await Self.owners(database)[foreign] == elsewhere)
    let chat = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Chat", ownerDeviceID: device)
    let used = try #require(try await Self.agent(of: chat, database))
    #expect(used != foreign && codex.map(\.id).contains(used))
  }

  @Test(arguments: [true, false])
  func aLinuxWorkspacesAgentIsFoundByItsWorkspace(earlier: Bool) async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let device = UUID(), workspace = UUID(), second = UUID()
    let seed = "wovenmatter.remote-harness-agent.v1:\(device.uuidString.lowercased()):\(workspace.uuidString.lowercased()):codex"
    let stored = earlier ? Self.earlierID(seed) : UUID().uuidString.lowercased()
    // Stored in the other letter case: the workspace is still the same one.
    try await Self.insert(database, id: stored, owner: device, kind: .codex, workspace: earlier ? workspace.uuidString.lowercased() : workspace.uuidString)
    let found = try await database.ensureRemoteHarnessAgent(runtimeKind: .codex, remoteWorkspaceID: workspace, remoteWorkspaceName: "Box", ownerDeviceID: device)
    #expect(found.uuidString.lowercased() == stored)
    let chat = try await database.createFixtureRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: workspace, remoteWorkspaceName: "Box",
                                                                title: "On the box", ownerDeviceID: device)
    #expect(try await Self.agent(of: chat, database) == stored)
    #expect(try await Self.rows(database).count == 1)
    #expect(try await Self.owners(database)[stored] == database.libraryIdentity().hostDeviceID)
    // Another workspace, and this device's own harness, are other places.
    let other = try await database.ensureRemoteHarnessAgent(runtimeKind: .codex, remoteWorkspaceID: second, remoteWorkspaceName: "Other", ownerDeviceID: device)
    #expect(try await database.ensureRemoteHarnessAgent(runtimeKind: .codex, remoteWorkspaceID: second, remoteWorkspaceName: "Other", ownerDeviceID: device) == other)
    try await database.reconcileLocalCLIAgentCatalog(ownerDeviceID: device)
    #expect(try await Self.rows(database).count == 2 + Self.kinds.count)
    #expect(try await Self.rows(database).filter { $0.location == "remote" }.count == 2)
  }

  /// The library a Mac's service and a Linux host's daemon open: preparing
  /// it twice over stored rows adds none.
  @Test func aLibraryStorePreparesItsWorkspaceOverStoredRowsWithoutAddingAny() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let store = try await LibraryStore(supportDirectory: fixture.directory)
    let device = try await store.deviceID()
    for kind in Self.kinds {
      try await Self.insert(store.database, id: Self.earlierID("wovenmatter.local-cli-agent.v1:\(device.uuidString.lowercased()):\(kind.rawValue)"), owner: device, kind: kind)
    }
    let stored = try await Self.rows(store.database)
    try await store.prepareLocalWorkspace()
    #expect(try await Self.rows(store.database) == stored)
    let reopened = try await LibraryStore(supportDirectory: fixture.directory)
    try await reopened.prepareLocalWorkspace()
    #expect(try await Self.rows(reopened.database) == stored)
    #expect(try await Self.owners(reopened.database).count == stored.count)
  }
}
