import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Companion central CLI authority and receipts", .serialized)
@MainActor
struct CompanionToolBridgeTests {
  @Test func publishedHTMLReferencesRetainReplayReceiptsAfterRestart() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let request = fixture.request(["html", "call", "--json", "{\"action\":\"render\",\"html\":\"<p>Page</p>\",\"title\":\"Page\",\"height\":120}"])
    let dispatcher = CompanionToolDispatcher(database: fixture.database)
    var executions = 0
    let expected: GatewayJSONValue = .object(["htmlRender": .object(["id": .string(request.request.requestID), "title": .string("Page"), "height": .number(120)])])
    let first = try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, _ in
      executions += 1; return .init(result: expected)
    }
    let restarted = CompanionToolDispatcher(database: try await WorkspaceDatabase(url: fixture.url))
    let replay = try await restarted.execute(request, deviceID: fixture.deviceID) { _, _ in
      executions += 1; return .init(success: false)
    }
    #expect(executions == 1 && first.success && replay.success && replay.result == expected)
  }


  @Test(.timeLimit(.minutes(1))) func concurrentRetryAndCallerCancellationKeepOneAcceptedExecution() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let dispatcher = CompanionToolDispatcher(database: fixture.database)
    let request = fixture.request(["notes", "create", "--title", "Retained work"])
    var executions = 0
    let started = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
    let initial = Task {
      defer { started.continuation.finish() }
      return try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, caller in
        executions += 1
        #expect(caller == fixture.conversationID)
        await withCheckedContinuation { started.continuation.yield($0) }
        #expect(!Task.isCancelled)
        return .init(result: .string("completed"), requestID: request.request.requestID)
      }
    }
    // Wait for acceptance itself rather than racing a loaded runner's clock.
    var acceptance = started.stream.makeAsyncIterator()
    let release = try #require(await acceptance.next())
    initial.cancel()
    let retry = Task {
      try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, _ in
        executions += 1; return .init(success: false)
      }
    }
    // Both calls join the same retained work regardless of which waiter resumes first.
    release.resume()
    #expect(try await initial.value.result == .string("completed"))
    #expect(try await retry.value.result == .string("completed"))
    #expect(executions == 1)
  }


  @Test func desktopResponsesAreNotStoredInTransportReceiptsOrReexecuted() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let request = fixture.request(["browser", "call", "--json", "{\"action\":\"tabs\"}"])
    let dispatcher = CompanionToolDispatcher(database: fixture.database)
    var executions = 0
    let result = try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, _ in
      executions += 1; return .init(result: .string("synthetic page capture"))
    }
    #expect(result.result == .string("synthetic page capture"))
    let restarted = CompanionToolDispatcher(database: try await WorkspaceDatabase(url: fixture.url))
    let retry = try await restarted.execute(request, deviceID: fixture.deviceID) { _, _ in
      executions += 1; return .init()
    }
    #expect(executions == 1 && retry.code == "automation_outcome_recorded" && retry.result == nil)
  }

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

  @Test func acceptedWorkWithoutRecordedOutcomeIsNotReexecuted() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let request = fixture.request(["notes", "create", "--title", "Unknown outcome"])
    #expect(try await fixture.database.reserveCompanionTool(request, deviceID: fixture.deviceID).isNew)
    let restarted = CompanionToolDispatcher(database: try await WorkspaceDatabase(url: fixture.url))
    var executed = false
    let response = try await restarted.execute(request, deviceID: fixture.deviceID) { _, _ in
      executed = true; return .init()
    }
    #expect(!executed && response.code == "outcome_unknown")
  }

  @Test func importedMacToolCallerRejectsAnotherDevice() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let caller = try await fixture.importSession(kind: .mac, executionDeviceID: fixture.deviceID)
    var request = fixture.request(["notes", "list"])
    request.conversationID = caller
    let dispatcher = CompanionToolDispatcher(database: fixture.database)
    var executions = 0
    let allowed = try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, authorizedCaller in
      executions += 1
      #expect(authorizedCaller == caller)
      return .init(result: .string("owner result"))
    }
    #expect(allowed.success && executions == 1)
    // The caller and policy remain valid; only the authenticated device differs.
    do {
      _ = try await dispatcher.execute(request, deviceID: UUID().uuidString.lowercased()) { _, _ in
        executions += 1
        return .init()
      }
      Issue.record("Another device acquired the imported Mac caller's tool authority")
    } catch let error as CompanionAPIError {
      #expect(error.code == "wrong_owner")
    }
    #expect(executions == 1)
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
