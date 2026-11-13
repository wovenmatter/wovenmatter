#if os(macOS)
import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPConfigurationLifecycleTests {

  @Test(arguments: [AgentRuntimeKind.codex, .claudeCode], ["error", "cancel", "stop", "shutdown", "unsent"])
  func dispatchedFirstPromptKeepsItsNativeIdentityAcrossFailure(runtime: AgentRuntimeKind, outcome: String) async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
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
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: persistence.directory), fence = AgentDispatchFence()
    let run = try await coordinator.accept(conversationID: id, input: .init(text: "First prompt"), launch: launch, workspace: workspace, dispatchFence: fence)
    if outcome == "stop" || outcome == "shutdown" {
      await interruption.waitUntilEntered()
      if outcome == "stop" { try await coordinator.stop(conversationID: id) }
      else { await coordinator.shutdown() }
    }
    _ = try await pollUntil(attempts: 500, interval: .milliseconds(10)) { lease.holds == 0 }
    #expect(lease.holds == 0)
    let expectedID: String? = outcome == "unsent" ? nil : "native-first"
    #expect(fence.hasDispatched == (outcome != "unsent"))
    #expect(try await database.localACPSession(conversationID: id).nativeSessionID == expectedID)
    let content = try await database.read { try $0.libraryIDsUnlocked("SELECT content FROM messages WHERE id=?", bindings: [run.assistantMessageID]).first }
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
    #expect(try await database.localACPSession(conversationID: id).nativeSessionID == expectedID)
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
      #expect(try await database.localACPSession(conversationID: id).nativeSessionID == expectedID)
      await forked.shutdown()
    }
  }

  @Test func claudeDraftsSurviveLeasedConfigurationAndPermissionBeforeFirstPrompt() async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
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
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: persistence.directory)
    _ = try await coordinator.configuration(conversationID: id, launch: launch, workspace: workspace)
    #expect(probe.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).nativeSessionID == nil)
    let configured = try await coordinator.updateConfiguration(conversationID: id, permission: "auto", launch: launch, workspace: workspace)
    #expect(configured.permission == "auto")
    #expect(permission.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).nativeSessionID == nil)
    _ = try await coordinator.accept(conversationID: id, input: .init(text: "First prompt"), launch: launch, workspace: workspace)
    _ = try await pollUntil(attempts: 500, interval: .milliseconds(10)) { lease.holds == 0 }
    #expect(lease.holds == 0)
    #expect(prompt.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).nativeSessionID == "durable")
    let changed = try await coordinator.updateConfiguration(conversationID: id, permission: "ask", launch: launch, workspace: workspace)
    #expect(changed.permission == "ask")
    #expect(resumed.shutdowns == 1)
    #expect(try await database.localACPSession(conversationID: id).nativeSessionID == "durable")
    await coordinator.shutdown()
  }

  @Test(arguments: [false, true])
  func obsoleteClaudeDraftCanBeReplacedOnlyWithoutPriorHistory(hasPriorRun: Bool) async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Older Claude", ownerDeviceID: UUID())
    try await database.updateLocalACPSessionID(conversationID: id, sessionID: "older-id")
    try await database.updateLocalACPSessionConfiguration(conversationID: id, model: nil, thinking: nil, permission: "ask")
    if hasPriorRun {
      let run = try await database.beginLocalACPRun(conversationID: id, input: .init(text: "Existing prompt"))
      try await database.completeLocalACPRun(runID: run.runID)
    }
    let driver = SelectorDriverState(expectedExistingSessionID: "older-id", sessionID: "replacement", missingExistingSession: true)
    let coordinator = LocalACPSessionCoordinator(database: database, processLease: ConfigurationTestProcessLease(),
      clientFactory: { _, _ in driver.driver() })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .claudeCode,
      executableURL: URL(filePath: "/nonexistent-claude-draft-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: persistence.directory)
    if hasPriorRun {
      await #expect(throws: (any Error).self) {
        try await coordinator.updateConfiguration(conversationID: id, permission: "auto", launch: launch, workspace: workspace)
      }
      #expect(try await database.localACPSession(conversationID: id).nativeSessionID == "older-id")
      #expect(try await database.localACPSession(conversationID: id).permission == "ask")
    } else {
      let configured = try await coordinator.updateConfiguration(conversationID: id, permission: "auto", launch: launch, workspace: workspace)
      #expect(configured.permission == "auto")
      #expect(try await database.localACPSession(conversationID: id).nativeSessionID == nil)
    }
    #expect(driver.shutdowns == 1)
    await coordinator.shutdown()
  }

  @Test(arguments: ["message", "event", "import", "retained"])
  func claudeDraftRepairRejectsStandaloneHistoryEvidence(evidence: String) async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Retained Claude", ownerDeviceID: UUID())
    try await database.updateLocalACPSessionID(conversationID: id, sessionID: "native")
    let sql: String = switch evidence {
    case "message": "INSERT INTO messages(id,conversation_id) VALUES ('fixture',?)"
    case "event": "INSERT INTO run_activities(id,conversation_id) VALUES ('fixture',?)"
    case "import": "INSERT INTO session_imports(conversation_id,imported_at) VALUES (?,'fixture')"
    default: "INSERT INTO retained_execution_history(conversation_id) VALUES (?)"
    }
    try await database.write { try $0.toolsExecuteUnlocked(sql, [id]) }
    let cleared = try await database.write { try $0.discardUnpromptedClaudeDraftSessionID(conversationID: id, expectedSessionID: "native") }
    #expect(!cleared)
    #expect(try await database.localACPSession(conversationID: id).nativeSessionID == "native")
  }

  @Test func executionAdoptionDetachesOnlyItsIdleClientAndRejectsLegacyReopen() async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
    let firstID = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Transfer", ownerDeviceID: UUID())
    let secondID = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Unrelated", ownerDeviceID: UUID())
    let first = SelectorDriverState(expectedExistingSessionID: nil)
    let second = SelectorDriverState(expectedExistingSessionID: nil)
    let drivers = SelectorDriverSequence([first, second])
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in drivers.next() })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-adoption-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: persistence.directory)
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
    let running = try await database.beginLocalACPRun(conversationID: secondID, input: .init(text: "Other process is busy"))
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
  private var current: LocalACPSessionConfiguration
  private var shutdownCount = 0
  private var observer: (@Sendable (LocalACPSessionConfiguration) async -> Void)?

  init(
    expectedExistingSessionID: String?,
    sessionID: String = "fixture-session",
    missingExistingSession: Bool = false
  ) {
    self.expectedExistingSessionID = expectedExistingSessionID
    self.sessionID = sessionID
    self.missingExistingSession = missingExistingSession
    initial = LocalACPSessionConfiguration(
      model: "default-model",
      thinking: "low",
      modelOptions: ["default-model", "selected-model"],
      thinkingOptions: ["low", "high"],
      permission: "ask", permissionOptions: ["ask", "auto"]
    )
    current = initial
  }

  var shutdowns: Int { lock.withLock { shutdownCount } }

  func driver() -> LocalACPSessionDriver {
    LocalACPSessionDriver(
      initializeSession: { [self] _, existing, _, _ in
        #expect(existing == expectedExistingSessionID)
        return LocalACPInitializedSession(
          sessionID: sessionID,
          loadedExistingSession: existing != nil && !missingExistingSession,
          configuration: lock.withLock { current }
        )
      },
      prompt: { _, _, _, _ in .endTurn },
      configuration: { [self] in lock.withLock { current } },
      observeConfiguration: { [self] handler in
        let snapshot = lock.withLock {
          observer = handler
          return current
        }
        await handler(snapshot)
      },
      setConfiguration: { [self] model, thinking in
        lock.withLock {
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
  private let lock = NSLock()
  private var holdCount = 0

  var holds: Int { lock.withLock { holdCount } }

  func acquire() throws -> LocalACPProcessLeaseAcquisition {
    lock.withLock {
      holdCount += 1
      return holdCount == 1 ? .acquired : .retained
    }
  }

  func release() {
    lock.withLock { holdCount = max(0, holdCount - 1) }
  }
}
#endif
