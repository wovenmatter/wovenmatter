import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPConfigurationLifecycleTests {

  @Test(arguments: [AgentRuntimeKind.codex, .claudeCode], ["error", "cancel", "stop", "shutdown", "unsent"])
  func dispatchedFirstPromptKeepsItsNativeIdentityAcrossFailure(runtime: AgentRuntimeKind, outcome: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let id = try await database.createFixtureLocalACPSession(runtimeKind: runtime, title: "Interrupted first prompt", ownerDeviceID: UUID())
    let config = LocalACPSessionConfiguration(permission: "ask", permissionOptions: ["ask", "auto"])
    let interruption = DraftPromptInterruption(), lease = ConfigurationTestProcessLease()
    let coordinator = LocalACPSessionCoordinator(database: database, processLease: lease, clientFactory: { _, _ in
      LocalACPSessionDriver(initializeSession: { _, existing, _, _ in
        #expect(existing == nil)
        return .init(sessionID: "native-first", loadedExistingSession: false, configuration: config)
      }, prompt: { _, _, _, _ in Issue.record("Expected fenced prompt"); return .endTurn },
      configuration: { config }, setConfiguration: { _, _ in config },
      cancel: { await interruption.interrupt() }, shutdown: { await interruption.interrupt() },
      fencedPrompt: { _, event, _, _, fence in
        if outcome == "unsent" { fence.cancel(); throw CancellationError() }
        try fence.claimDispatch()
        try await event?(.assistantChunk("Partial first response"))
        if outcome == "stop" || outcome == "shutdown" { try await interruption.wait() }
        if outcome == "error" { throw LocalACPClientError.processExited }
        throw CancellationError()
      })
    })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: runtime, executableURL: URL(filePath: "/nonexistent-interruption-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory), fence = AgentDispatchFence()
    let run = try await coordinator.accept(conversationID: id, content: "First prompt", launch: launch, workspace: workspace, dispatchFence: fence)
    if outcome == "stop" || outcome == "shutdown" {
      await interruption.waitUntilEntered()
      if outcome == "stop" { try await coordinator.stop(conversationID: id) }
      else { await coordinator.shutdown() }
    }
    for _ in 0..<500 {
      if lease.snapshot.holds == 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(lease.snapshot.holds == 0)
    let expectedID: String? = outcome == "unsent" ? nil : "native-first"
    #expect(fence.hasDispatched == (outcome != "unsent"))
    #expect(try await database.localACPSession(conversationID: id).acpSessionID == expectedID)
    let content = try await database.read { try $0.companionIDsUnlocked("SELECT content FROM dashboard_messages WHERE id=?", bindings: [run.assistantMessageID]).first }
    // An unsent cancellation terminalizes the placeholder with the app's
    // stopped-before-response message, never provider output.
    #expect(content == (outcome == "unsent" ? "Stopped before the agent produced a response." : "Partial first response"))
    await coordinator.shutdown()
    let resumed = LocalACPSessionCoordinator(database: database, processLease: ConfigurationTestProcessLease(), clientFactory: { _, _ in
      LocalACPSessionDriver(initializeSession: { _, existing, _, _ in
        #expect(existing == expectedID)
        return .init(sessionID: existing ?? "new-draft", loadedExistingSession: existing != nil, configuration: config)
      }, prompt: { _, _, _, _ in .endTurn }, configuration: { config }, setConfiguration: { _, _ in config }, cancel: {}, shutdown: {})
    })
    _ = try await resumed.configuration(conversationID: id, launch: launch, workspace: workspace)
    #expect(try await database.localACPSession(conversationID: id).acpSessionID == expectedID)
    await resumed.shutdown()
    if expectedID != nil {
      let forked = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
        LocalACPSessionDriver(initializeSession: { _, existing, _, _ in
          #expect(existing == expectedID)
          return .init(sessionID: "unexpected-fork", loadedExistingSession: false, configuration: config)
        }, prompt: { _, _, _, _ in .endTurn }, configuration: { config }, setConfiguration: { _, _ in config }, cancel: {}, shutdown: {})
      })
      do {
        _ = try await forked.updateConfiguration(conversationID: id, permission: "auto", launch: launch, workspace: workspace)
        Issue.record("Interrupted native session identity was allowed to fork")
      } catch {
        #expect(error.localizedDescription == "The harness could not reconnect the existing session to change permissions.")
      }
      #expect(try await database.localACPSession(conversationID: id).acpSessionID == expectedID)
      await forked.shutdown()
    }
  }

  @Test func claudeDraftsSurviveLeasedConfigurationAndPermissionBeforeFirstPrompt() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Claude draft", ownerDeviceID: UUID())
    let probe = SelectorDriverState(expectedExistingSessionID: nil, sessionID: "probe")
    let permission = SelectorDriverState(expectedExistingSessionID: nil, sessionID: "permission-probe")
    let prompt = SelectorDriverState(expectedExistingSessionID: nil, sessionID: "durable")
    let resumed = SelectorDriverState(expectedExistingSessionID: "durable", sessionID: "durable")
    let drivers = SelectorDriverSequence([probe, permission, prompt, resumed])
    let lease = ConfigurationTestProcessLease()
    let coordinator = LocalACPSessionCoordinator(database: database, processLease: lease, clientFactory: { _, _ in drivers.next() })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .claudeCode,
      executableURL: URL(filePath: "/nonexistent-claude-draft-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory)
    _ = try await coordinator.configuration(conversationID: id, launch: launch, workspace: workspace)
    #expect(probe.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).acpSessionID == nil)
    let configured = try await coordinator.updateConfiguration(conversationID: id, permission: "auto", launch: launch, workspace: workspace)
    #expect(configured.permission == "auto")
    #expect(permission.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).acpSessionID == nil)
    _ = try await coordinator.accept(conversationID: id, content: "First prompt", launch: launch, workspace: workspace)
    for _ in 0..<500 {
      if lease.snapshot.holds == 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(lease.snapshot.holds == 0)
    #expect(prompt.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).acpSessionID == "durable")
    let changed = try await coordinator.updateConfiguration(conversationID: id, permission: "ask", launch: launch, workspace: workspace)
    #expect(changed.permission == "ask")
    #expect(resumed.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).acpSessionID == "durable")
    await coordinator.shutdown()
  }

  @Test(arguments: [false, true])
  func obsoleteClaudeDraftCanBeReplacedOnlyWithoutPriorHistory(hasPriorRun: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Older Claude", ownerDeviceID: UUID())
    try await database.updateLocalACPSessionID(conversationID: id, sessionID: "older-id")
    try await database.updateLocalACPSessionConfiguration(conversationID: id, model: nil, thinking: nil, permission: "ask")
    if hasPriorRun {
      let run = try await database.beginLocalACPRun(conversationID: id, content: "Existing prompt")
      try await database.completeLocalACPRun(runID: run.runID)
    }
    let driver = SelectorDriverState(expectedExistingSessionID: "older-id", sessionID: "replacement", missingExistingSession: true)
    let coordinator = LocalACPSessionCoordinator(database: database, processLease: ConfigurationTestProcessLease(),
      clientFactory: { _, _ in driver.driver() })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .claudeCode,
      executableURL: URL(filePath: "/nonexistent-claude-draft-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory)
    if hasPriorRun {
      await #expect(throws: (any Error).self) {
        try await coordinator.updateConfiguration(conversationID: id, permission: "auto", launch: launch, workspace: workspace)
      }
      #expect(try await database.localACPSession(conversationID: id).acpSessionID == "older-id")
      #expect(try await database.localACPSession(conversationID: id).permission == "ask")
    } else {
      let configured = try await coordinator.updateConfiguration(conversationID: id, permission: "auto", launch: launch, workspace: workspace)
      #expect(configured.permission == "auto")
      #expect(try await database.localACPSession(conversationID: id).acpSessionID == nil)
    }
    #expect(driver.shutdowns == 1)
    await coordinator.shutdown()
  }

  @Test(arguments: ["message", "event", "trace", "import", "retained"])
  func claudeDraftRepairRejectsStandaloneHistoryEvidence(evidence: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Retained Claude", ownerDeviceID: UUID())
    try await database.updateLocalACPSessionID(conversationID: id, sessionID: "native")
    let sql: String = switch evidence {
    case "message": "INSERT INTO dashboard_messages(id,conversation_id) VALUES ('fixture',?)"
    case "event": "INSERT INTO dashboard_run_events(id,conversation_id) VALUES ('fixture',?)"
    case "trace": "INSERT INTO dashboard_run_trace_events(id,conversation_id) VALUES ('fixture',?)"
    case "import": "INSERT INTO desktop_session_imports(conversation_id,imported_at) VALUES (?,'fixture')"
    default: "INSERT INTO retained_execution_history(conversation_id) VALUES (?)"
    }
    try await database.write { try $0.companionExecuteUnlocked(sql, values: [id]) }
    let cleared = try await database.write { try $0.discardUnpromptedClaudeDraftSessionID(conversationID: id, expectedSessionID: "native") }
    #expect(!cleared)
    #expect(try await database.localACPSession(conversationID: id).acpSessionID == "native")
  }

  @Test func executionAdoptionDetachesOnlyItsIdleClientAndRejectsLegacyReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let firstID = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Transfer", ownerDeviceID: UUID())
    let secondID = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Unrelated", ownerDeviceID: UUID())
    let first = SelectorDriverState(expectedExistingSessionID: nil)
    let second = SelectorDriverState(expectedExistingSessionID: nil)
    let drivers = SelectorDriverSequence([first, second])
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in drivers.next() })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-adoption-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory)
    _ = try await coordinator.configuration(conversationID: firstID, launch: launch, workspace: workspace)
    _ = try await coordinator.configuration(conversationID: secondID, launch: launch, workspace: workspace)
    let original = try await database.localACPSession(conversationID: firstID)
    try await coordinator.detachForExecutionAdoption(conversationID: firstID)
    #expect(first.shutdowns == 1 && second.shutdowns == 0)
    await #expect(throws: (any Error).self) {
      try await coordinator.configuration(conversationID: firstID, launch: launch, workspace: workspace)
    }
    _ = try await coordinator.configuration(conversationID: secondID, launch: launch, workspace: workspace)
    #expect(drivers.requests == 2)
    await first.emit(.init(model: "selected-model", modelOptions: ["default-model", "selected-model"]))
    #expect(try await database.localACPSession(conversationID: firstID).model == original.model)
    let running = try await database.beginLocalACPRun(conversationID: secondID, content: "Other process is busy")
    await #expect(throws: (any Error).self) { try await coordinator.detachForExecutionAdoption(conversationID: secondID) }
    #expect(second.shutdowns == 0)
    try await database.completeLocalACPRun(runID: running.runID)
    _ = try await coordinator.configuration(conversationID: secondID, launch: launch, workspace: workspace)
    await coordinator.shutdown()
    #expect(first.shutdowns == 1 && second.shutdowns == 1)
  }

}

private actor DraftPromptInterruption {
  private let entered = AsyncStream<Void>.makeStream()
  private var continuation: CheckedContinuation<Void, any Error>?
  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      entered.continuation.yield(())
    }
  }
  func waitUntilEntered() async { for await _ in entered.stream { break } }
  func interrupt() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}

private final class SelectorDriverState: @unchecked Sendable {
  private let lock = NSLock()
  private let expectedExistingSessionID: String?
  private let sessionID: String
  private let missingExistingSession: Bool
  private let initial: LocalACPSessionConfiguration
  private let observedUpdate: LocalACPSessionConfiguration?
  private var current: LocalACPSessionConfiguration
  private var startCount = 0
  private var configurationReadCount = 0
  private var shutdownCount = 0
  private var requests: [String] = []
  private var initializedDirectories: [String] = []
  private var observer: (@Sendable (LocalACPSessionConfiguration) async -> Void)?

  init(
    expectedExistingSessionID: String?,
    modelOptions: [String] = ["default-model", "selected-model"],
    observedUpdate: LocalACPSessionConfiguration? = nil,
    sessionID: String = "fixture-session",
    missingExistingSession: Bool = false
  ) {
    self.expectedExistingSessionID = expectedExistingSessionID
    self.sessionID = sessionID
    self.missingExistingSession = missingExistingSession
    initial = LocalACPSessionConfiguration(
      model: "default-model",
      thinking: "low",
      modelOptions: modelOptions,
      thinkingOptions: ["low", "high"],
      permission: "ask", permissionOptions: ["ask", "auto"]
    )
    self.observedUpdate = observedUpdate
    current = initial
  }

  var starts: Int { lock.withLock { startCount } }
  var configurationReads: Int { lock.withLock { configurationReadCount } }
  var shutdowns: Int { lock.withLock { shutdownCount } }
  var setRequests: [String] { lock.withLock { requests } }
  var directories: [String] { lock.withLock { initializedDirectories } }

  func driver() -> LocalACPSessionDriver {
    lock.withLock { startCount += 1 }
    return LocalACPSessionDriver(
      initializeSession: { [self] directory, existing, _, _ in
        lock.withLock { initializedDirectories.append(directory.path) }
        #expect(existing == expectedExistingSessionID)
        return LocalACPInitializedSession(
          sessionID: sessionID,
          loadedExistingSession: existing != nil && !missingExistingSession,
          configuration: lock.withLock { current }
        )
      },
      prompt: { _, _, _, _ in .endTurn },
      configuration: { [self] in
        lock.withLock {
          configurationReadCount += 1
          return current
        }
      },
      observeConfiguration: { [self] handler in
        let snapshots = lock.withLock {
          observer = handler
          var snapshots = [current]
          if let observedUpdate {
            current = observedUpdate
            snapshots.append(observedUpdate)
          }
          return snapshots
        }
        for snapshot in snapshots { await handler(snapshot) }
      },
      setConfiguration: { [self] model, thinking in
        lock.withLock {
          requests.append("model=\(model ?? "nil");thinking=\(thinking ?? "nil")")
          current = current.selecting(model: model, thinking: thinking)
          return current
        }
      },
      setPermission: { [self] permission in
        lock.withLock {
          current = current.selecting(permission: permission)
          return current
        }
      },
      cancel: {},
      shutdown: { [self] in lock.withLock { shutdownCount += 1 } }
    )
  }

  func emit(_ configuration: LocalACPSessionConfiguration) async {
    let handler = lock.withLock {
      current = configuration
      return observer
    }
    await handler?(configuration)
  }
}

private final class SelectorDriverSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var states: [SelectorDriverState]
  private var requestCount = 0

  init(_ states: [SelectorDriverState]) { self.states = states }

  var requests: Int { lock.withLock { requestCount } }

  func next() -> LocalACPSessionDriver {
    let state = lock.withLock {
      let state = states.removeFirst()
      requestCount += 1
      return state
    }
    return state.driver()
  }
}

final class ConfigurationTestProcessLease: LocalACPProcessLeasing, @unchecked Sendable {
  struct Snapshot: Equatable {
    let acquisitions: Int
    let releases: Int
    let holds: Int
  }

  private let lock = NSLock()
  private var acquisitions = 0
  private var releases = 0
  private var holds = 0

  var snapshot: Snapshot {
    lock.withLock { Snapshot(acquisitions: acquisitions, releases: releases, holds: holds) }
  }

  func acquire() throws -> LocalACPProcessLeaseAcquisition {
    lock.withLock {
      acquisitions += 1
      holds += 1
      return holds == 1 ? .acquired : .retained
    }
  }

  func release() {
    lock.withLock {
      releases += 1
      holds = max(0, holds - 1)
    }
  }
}
