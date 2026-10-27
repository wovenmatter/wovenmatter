import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Companion MCP authority and receipts", .serialized)
@MainActor
struct CompanionToolBridgeTests {

  @Test func scheduledMCPCallerUsesSavedScopeAndWaitsForNativeBinding() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let executor = UUID().uuidString.lowercased()
    let historicalCaller = try await fixture.importSession(kind: .linux, executionDeviceID: executor)
    let workspace = try #require(await fixture.database.companionConversationExecutionWorkspace(conversationID: historicalCaller))
    let workspaceID = try #require(UUID(uuidString: workspace.id))
    let identity = try await fixture.database.companionLibraryIdentity()
    let grant = try await fixture.database.issueCompanionWorkspaceMCP(workspaceID: workspace.id,
      endpoint: URL(string: "https://central.tail.ts.net/wovenmatter")!, deviceID: identity.hostDeviceID)
    let principal = try await fixture.database.authenticateCompanionWorkspaceMCP(bearer: grant.bearerToken)
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
    let task = WorkspaceCalendarTask(prompt: "Read the notes", configuration: .init(runtimeKind: .codex,
      workspaceID: workspaceID, title: "Read notes", nativeWorkingDirectory: "/home/.woven-matter", tools: .init(enabled: [.notes])))
    let eventID = try await fixture.database.saveCalendarEvent(draft: .init(title: "Read notes", startsAt: start,
      timeZoneID: "UTC", task: task), creating: true, now: start)
    try await fixture.database.setRemoteCalendarExecutionOwnership(workspaceID: workspaceID, state: .pending)
    try await fixture.database.setRemoteCalendarExecutionOwnership(workspaceID: workspaceID, state: .remote)
    let event = try #require(await fixture.database.calendarItems().first(where: { $0.id == eventID }))
    let savedTask = try #require(event.calendar.task)
    let run = WorkspaceCalendarRun(id: UUID().uuidString.lowercased(), eventID: eventID, occurrenceIndex: 0,
      scheduledAt: start, sessionID: UUID().uuidString.lowercased(), task: savedTask, status: "sending", title: event.title)
    let scope = try await fixture.database.prepareCompanionScheduledMCP(.init(run: run,
      eventRevision: event.calendar.revision, nativeSessionID: nil), principal: principal)
    #expect(Set(scope) == savedTask.configuration.tools.enabled)
    #expect(try await fixture.database.companionExecutionOwner(conversationID: run.sessionID) == nil)
    let capturedRoot = try await fixture.database.availableSessionExecutionRoot(id: run.sessionID)
    #expect(capturedRoot.workspaceID == "remote:" + workspace.id)
    #expect(capturedRoot.rootPath == savedTask.configuration.nativeWorkingDirectory)
    var call = fixture.request(["notes", "create", "--title", "Prepared"]); call.conversationID = run.sessionID
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(call, deviceID: executor)
    }
    _ = try await fixture.database.prepareCompanionScheduledMCP(.init(run: run,
      eventRevision: event.calendar.revision, nativeSessionID: "native-scheduled-session"), principal: principal)
    try await fixture.database.authorizeCompanionWorkspaceMCPCaller(conversationID: run.sessionID, principal: principal)
    try await fixture.database.authorizeCompanionTool(call, deviceID: executor)
    var forged = run; forged.task.configuration.tools = .init(enabled: [.notes, .executor])
    await #expect(throws: (any Error).self) {
      _ = try await fixture.database.prepareCompanionScheduledMCP(.init(run: forged,
        eventRevision: event.calendar.revision, nativeSessionID: "native-scheduled-session"), principal: principal)
    }
  }

  @Test func libraryMCPRotationAndRevocationRejectOldCredentialsAndPrincipals() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let caller = try await fixture.importSession(kind: .linux, executionDeviceID: UUID().uuidString.lowercased())
    let workspace = try #require(await fixture.database.companionConversationExecutionWorkspace(conversationID: caller))
    let identity = try await fixture.database.companionLibraryIdentity()
    let endpoint = URL(string: "https://central.tail.ts.net/wovenmatter")!
    let original = try await fixture.database.issueCompanionWorkspaceMCP(workspaceID: workspace.id,
      endpoint: endpoint, deviceID: identity.hostDeviceID)
    let principal = try await fixture.database.authenticateCompanionWorkspaceMCP(bearer: original.bearerToken)
    let replacement = try await fixture.database.issueCompanionWorkspaceMCP(workspaceID: workspace.id,
      endpoint: endpoint, deviceID: identity.hostDeviceID)
    #expect(try await fixture.database.companionWorkspaceMCPMatches(workspaceID: workspace.id,
      grantID: replacement.grantID, endpoint: endpoint))
    await #expect(throws: (any Error).self) {
      _ = try await fixture.database.authenticateCompanionWorkspaceMCP(bearer: original.bearerToken)
    }
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionWorkspaceMCPCaller(conversationID: caller, principal: principal)
    }
    try await fixture.database.revokeCompanionWorkspaceMCP(workspaceID: workspace.id, deviceID: identity.hostDeviceID)
    await #expect(throws: (any Error).self) {
      _ = try await fixture.database.authenticateCompanionWorkspaceMCP(bearer: replacement.bearerToken)
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
