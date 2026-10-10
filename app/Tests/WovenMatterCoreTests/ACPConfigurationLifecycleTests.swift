import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPConfigurationLifecycleTests {
  @Test func leasedSnapshotsAndSelectionsSurviveReopenWithoutStaleObserverWrites() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversationID = try await database.createLocalACPSession(
      runtimeKind: .codex, title: "Native selector updates", ownerDeviceID: UUID()
    )
    let native = LocalACPSessionConfiguration(
      model: "native-model",
      thinking: "high",
      modelOptions: ["default-model", "native-model", "selected-model"],
      thinkingOptions: ["low", "high"]
    )
    let firstState = SelectorDriverState(
      expectedExistingSessionID: nil,
      modelOptions: native.modelOptions,
      observedUpdate: native
    )
    let secondState = SelectorDriverState(
      expectedExistingSessionID: nil,
      modelOptions: native.modelOptions
    )
    let drivers = SelectorDriverSequence([firstState, secondState])
    let changes = ConfigurationLifecycleState()
    let lease = ConfigurationTestProcessLease()
    let coordinator = LocalACPSessionCoordinator(
      database: database,
      processLease: lease,
      onChange: { change in
        changes.record(change)
        // Persistence is awaited explicitly after each configuration operation
        // below; notifications remain synchronous and carry immutable values.
      },
      clientFactory: { _, _ in drivers.next() }
    )
    let launch = LocalACPRuntimeLaunchConfiguration(
      runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-native-selector-fixture"),
      arguments: []
    )
    let workspace = LocalACPWorkspaceLaunchConfiguration(
      rootURL: directory,
      repositoriesURL: directory
    )

    let observed = try await coordinator.configuration(
      conversationID: conversationID,
      launch: launch,
      workspace: workspace
    )
    #expect(observed.model == "native-model")
    #expect(observed.thinking == "high")
    #expect(try await database.localACPSession(conversationID: conversationID).acpSessionID == nil)
    #expect(try await database.localACPSession(conversationID: conversationID).model == "native-model")
    #expect(try await database.localACPSession(conversationID: conversationID).thinking == "high")
    #expect(firstState.starts == 1)
    #expect(firstState.configurationReads == 1)
    #expect(firstState.shutdowns == 1)
    #expect(lease.snapshot == .init(acquisitions: 1, releases: 1, holds: 0))
    #expect(changes.changes.contains(DashboardConversationChange(
      conversationID: conversationID, runID: "", phase: .configuration(native))))

    let selected = try await coordinator.updateConfiguration(
      conversationID: conversationID,
      model: "selected-model",
      thinking: "high",
      launch: launch,
      workspace: workspace
    )
    #expect(selected.model == "selected-model")
    #expect(selected.thinking == "high")
    #expect(secondState.setRequests == [
      "model=selected-model;thinking=nil", "model=nil;thinking=high",
    ])
    #expect(secondState.shutdowns == 1)

    let changeCountBeforeStaleUpdate = changes.changes.count
    await firstState.emit(native.selecting(model: "default-model", thinking: "high"))

    let persisted = try await database.localACPSession(conversationID: conversationID)
    #expect(persisted.model == "selected-model")
    #expect(persisted.thinking == "high")
    #expect(changes.changes.count == changeCountBeforeStaleUpdate)
    #expect(drivers.requests == 2)
    await coordinator.shutdown()
    #expect(firstState.shutdowns == 1 && secondState.shutdowns == 1)
    #expect(lease.snapshot == .init(acquisitions: 2, releases: 2, holds: 0))

    let reopenedDatabase = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let reopenedState = SelectorDriverState(expectedExistingSessionID: nil)
    let reopened = LocalACPSessionCoordinator(database: reopenedDatabase,
      processLease: ConfigurationTestProcessLease(), clientFactory: { _, _ in reopenedState.driver() })
    let restored = try await reopened.configuration(conversationID: conversationID, launch: launch, workspace: workspace)
    #expect(restored.model == "selected-model" && restored.thinking == "high")
    #expect(restored.modelOptions == ["default-model", "selected-model"])
    #expect(restored.thinkingOptions == ["low", "high"])
    #expect(reopenedState.setRequests == ["model=selected-model;thinking=nil", "model=nil;thinking=high"])
    #expect(reopenedState.starts == 1 && reopenedState.configurationReads == 1 && reopenedState.shutdowns == 1)
    await reopened.shutdown()
  }

  @Test func executionAdoptionDetachesOnlyItsIdleClientAndRejectsLegacyReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let firstID = try await database.createLocalACPSession(runtimeKind: .codex, title: "Transfer", ownerDeviceID: UUID())
    let secondID = try await database.createLocalACPSession(runtimeKind: .codex, title: "Unrelated", ownerDeviceID: UUID())
    let first = SelectorDriverState(expectedExistingSessionID: nil)
    let second = SelectorDriverState(expectedExistingSessionID: nil)
    let drivers = SelectorDriverSequence([first, second])
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in drivers.next() })
    let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-adoption-fixture"), arguments: [])
    let workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory, repositoriesURL: directory)
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
      thinkingOptions: ["low", "high"]
    )
    self.observedUpdate = observedUpdate
    current = initial
  }

  var starts: Int { lock.withLock { startCount } }
  var configurationReads: Int { lock.withLock { configurationReadCount } }
  var shutdowns: Int { lock.withLock { shutdownCount } }
  var setRequests: [String] { lock.withLock { requests } }

  func driver() -> LocalACPSessionDriver {
    lock.withLock { startCount += 1 }
    return LocalACPSessionDriver(
      initializeSession: { [self] _, existing, _, _ in
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

private final class ConfigurationLifecycleState: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedChanges: [DashboardConversationChange] = []
  var changes: [DashboardConversationChange] { lock.withLock { recordedChanges } }
  func record(_ change: DashboardConversationChange) {
    lock.withLock { recordedChanges.append(change) }
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
