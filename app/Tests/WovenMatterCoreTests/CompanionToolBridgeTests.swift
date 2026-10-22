import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Companion central CLI authority and receipts", .serialized)
@MainActor
struct CompanionToolBridgeTests {


  @Test func ongoingAutomationRechecksDeviceExecutionAccess() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let identity = try await fixture.database.companionLibraryIdentity()
    _ = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
      id: "20000000-0000-0000-0000-000000000001", libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
      kind: .mac, name: "Later registration", executionDeviceID: identity.hostDeviceID)), deviceID: identity.hostDeviceID)
    let host = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
      id: "10000000-0000-0000-0000-000000000001", libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
      kind: .mac, name: "Central Mac", executionDeviceID: identity.hostDeviceID)), deviceID: identity.hostDeviceID)
    try await fixture.database.requireCompanionAutomationAccess(callerID: fixture.conversationID)
    try await fixture.database.setCompanionWorkspaceAccess(deviceID: fixture.deviceID, workspaceID: host.id,
      enabled: false, authorizedBy: identity.hostDeviceID)
    await #expect(throws: (any Error).self) {
      try await fixture.database.requireCompanionAutomationAccess(callerID: fixture.conversationID)
    }
  }

  private struct Fixture {
    let root: URL
    let url: URL
    let database: WorkspaceDatabase
    let deviceID: String
    let conversationID: String

    init() async throws {
      root = FileManager.default.temporaryDirectory.appending(path: "companion-tools-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      url = root.appending(path: "workspace.sqlite")
      database = try await WorkspaceDatabase(url: url)
      deviceID = UUID().uuidString.lowercased()
      conversationID = UUID().uuidString.lowercased()
      try await Self.importSession(database: database, deviceID: deviceID, conversationID: conversationID,
        kind: .ios, executionDeviceID: deviceID)
    }
    func request(_ arguments: [String]) -> CompanionToolRequest {
      .init(conversationID: conversationID, request: .init(arguments: arguments), enabledGroups: WorkspaceToolGroup.allCases)
    }
    func importSession(kind: CompanionExecutionWorkspace.Kind, executionDeviceID: String?) async throws -> String {
      let id = UUID().uuidString.lowercased()
      try await Self.importSession(database: database, deviceID: deviceID, conversationID: id,
        kind: kind, executionDeviceID: executionDeviceID)
      return id
    }
    static func importSession(database: WorkspaceDatabase, deviceID: String, conversationID: String,
                              kind: CompanionExecutionWorkspace.Kind, executionDeviceID: String?) async throws {
      let identity = try await database.companionLibraryIdentity()
      // Linux registration belongs to the central host; its execution owner
      // publishes history using a scoped grant, never through the observing phone.
      let registrar = kind == .linux ? identity.hostDeviceID : deviceID
      let workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
        id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: registrar,
        kind: kind, name: "Device", executionDeviceID: executionDeviceID)), deviceID: registrar)
      let batch = CompanionJournalBatch(libraryID: identity.libraryID, entries: [
        .init(workspaceID: workspace.id, originSequence: 1, conversationID: conversationID, kind: .conversation,
          conversation: .init(id: conversationID, title: "Device agent", runtimeKind: "piDurable"))
      ])
      if kind == .linux {
        let grant = try await database.issueCompanionWorkspacePublisher(workspaceID: workspace.id,
          endpoint: URL(string: "https://central.tail.ts.net/wovenmatter")!, deviceID: identity.hostDeviceID)
        let path = "/v1/federation/publisher/journal"
        let request = CompanionHTTPRequest(method: "POST", target: path,
          headers: ["authorization": "Bearer " + grant.token, "x-woven-workspace": identity.libraryID],
          body: try JSONEncoder().encode(batch))
        #expect(try await CompanionWorkspacePublisherAPI.handle(request, path: path, database: database).status == 200)
      } else {
        _ = try await database.ingestCompanionJournal(batch, deviceID: executionDeviceID ?? deviceID)
      }
      #expect(try await database.companionExecutionOwner(conversationID: conversationID) == workspace.id)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
