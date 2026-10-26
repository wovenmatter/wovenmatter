import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPConfigurationLifecycleTests {

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

private final class SelectorDriverState: @unchecked Sendable {
  private let lock = NSLock()
  private let expectedExistingSessionID: String?
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
    observedUpdate: LocalACPSessionConfiguration? = nil
  ) {
    self.expectedExistingSessionID = expectedExistingSessionID
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
          sessionID: "fixture-session",
          loadedExistingSession: existing != nil,
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
