import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPConfigurationLifecycleTests {
  @Test func leasedConfigurationProbePublishesSnapshotAndReleasesOneDriver() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversationID = try database.createLocalACPSession(
      runtimeKind: .codex, title: "Configuration fixture", ownerDeviceID: UUID()
    )
    let expected = LocalACPSessionConfiguration(
      model: "fixture-model",
      thinking: "high",
      modelOptions: ["fixture-model"],
      thinkingOptions: ["high"],
      slashCommands: [LocalACPSlashCommand(name: "review")]
    )
    let lease = ConfigurationTestProcessLease()
    let state = ConfigurationLifecycleState()
    let coordinator = LocalACPSessionCoordinator(
      database: database,
      processLease: lease,
      onChange: { change in state.record(change) },
      clientFactory: { _, _ in
        state.started()
        return LocalACPSessionDriver(
          initializeSession: { _, _, _, _ in
            LocalACPInitializedSession(
              sessionID: "fixture-session",
              loadedExistingSession: false,
              configuration: expected
            )
          },
          prompt: { _, _, _, _ in .endTurn },
          configuration: {
            state.readConfiguration()
            return expected
          },
          observeConfiguration: { handler in
            state.observedConfiguration()
            await handler(expected)
          },
          setConfiguration: { _, _ in expected },
          cancel: {},
          shutdown: { state.shutDown() }
        )
      }
    )
    let launch = LocalACPRuntimeLaunchConfiguration(
      runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-configuration-fixture"),
      arguments: []
    )
    let workspace = LocalACPWorkspaceLaunchConfiguration(
      rootURL: directory,
      repositoriesURL: directory
    )

    let result = try await coordinator.configuration(
      conversationID: conversationID,
      launch: launch,
      workspace: workspace
    )

    #expect(result == expected)
    #expect(state.starts == 1)
    #expect(state.observers == 1)
    #expect(state.configurationReads == 1)
    #expect(state.shutdowns == 1)
    #expect(state.changes == [DashboardConversationChange(
      conversationID: conversationID,
      runID: "",
      phase: .configuration(expected)
    )])
    #expect(lease.snapshot == .init(acquisitions: 1, releases: 1, holds: 0))

    await coordinator.shutdown()
    #expect(state.shutdowns == 1)
  }

  @Test func selectedModelAndThinkingAreRestoredAfterDatabaseReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appending(path: "workspace.sqlite")
    let database = try WorkspaceDatabase(url: databaseURL)
    let conversationID = try database.createLocalACPSession(
      runtimeKind: .codex, title: "Selector persistence", ownerDeviceID: UUID()
    )
    let launch = LocalACPRuntimeLaunchConfiguration(
      runtimeKind: .codex,
      executableURL: URL(filePath: "/nonexistent-selector-fixture"),
      arguments: []
    )
    let workspace = LocalACPWorkspaceLaunchConfiguration(
      rootURL: directory,
      repositoriesURL: directory
    )

    let firstState = SelectorDriverState(expectedExistingSessionID: nil)
    let first = LocalACPSessionCoordinator(
      database: database,
      processLease: ConfigurationTestProcessLease(),
      clientFactory: { _, _ in firstState.driver() }
    )
    let selected = try await first.updateConfiguration(
      conversationID: conversationID,
      model: "selected-model",
      thinking: "high",
      launch: launch,
      workspace: workspace
    )

    #expect(selected.model == "selected-model")
    #expect(selected.thinking == "high")
    #expect(firstState.setRequests == ["model=selected-model;thinking=high"])
    #expect(firstState.starts == 1)
    #expect(firstState.shutdowns == 1)
    await first.shutdown()

    let reopenedDatabase = try WorkspaceDatabase(url: databaseURL)
    let persisted = try reopenedDatabase.localACPSession(conversationID: conversationID)
    #expect(persisted.model == "selected-model")
    #expect(persisted.thinking == "high")

    let reopenedState = SelectorDriverState(expectedExistingSessionID: "fixture-session")
    let reopened = LocalACPSessionCoordinator(
      database: reopenedDatabase,
      processLease: ConfigurationTestProcessLease(),
      clientFactory: { _, _ in reopenedState.driver() }
    )
    let restored = try await reopened.configuration(
      conversationID: conversationID,
      launch: launch,
      workspace: workspace
    )

    #expect(restored.model == "selected-model")
    #expect(restored.thinking == "high")
    #expect(restored.modelOptions == ["default-model", "selected-model"])
    #expect(restored.thinkingOptions == ["low", "high"])
    #expect(reopenedState.setRequests == [
      "model=selected-model;thinking=nil",
      "model=nil;thinking=high",
    ])
    #expect(reopenedState.starts == 1)
    #expect(reopenedState.configurationReads == 1)
    #expect(reopenedState.shutdowns == 1)
    await reopened.shutdown()
  }

  @Test func nativeSnapshotsPersistAndEvictedObserversCannotOverwriteSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversationID = try database.createLocalACPSession(
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
      expectedExistingSessionID: "fixture-session",
      modelOptions: native.modelOptions
    )
    let drivers = SelectorDriverSequence([firstState, secondState])
    let changes = ConfigurationLifecycleState()
    let coordinator = LocalACPSessionCoordinator(
      database: database,
      processLease: ConfigurationTestProcessLease(),
      onChange: { change in
        changes.record(change)
        guard case .configuration(let configuration) = change.phase else { return }
        let descriptor = try? database.localACPSession(conversationID: conversationID)
        #expect(descriptor?.model == configuration.model)
        #expect(descriptor?.thinking == configuration.thinking)
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
    #expect(try database.localACPSession(conversationID: conversationID).model == "native-model")
    #expect(try database.localACPSession(conversationID: conversationID).thinking == "high")
    #expect(firstState.shutdowns == 1)

    let selected = try await coordinator.updateConfiguration(
      conversationID: conversationID,
      model: "selected-model",
      thinking: "low",
      launch: launch,
      workspace: workspace
    )
    #expect(selected.model == "selected-model")
    #expect(selected.thinking == "low")
    #expect(secondState.setRequests == [
      "model=native-model;thinking=nil",
      "model=nil;thinking=high",
      "model=selected-model;thinking=low",
    ])
    #expect(secondState.shutdowns == 1)

    let changeCountBeforeStaleUpdate = changes.changes.count
    await firstState.emit(native.selecting(model: "default-model", thinking: "high"))

    let persisted = try database.localACPSession(conversationID: conversationID)
    #expect(persisted.model == "selected-model")
    #expect(persisted.thinking == "low")
    #expect(changes.changes.count == changeCountBeforeStaleUpdate)
    #expect(drivers.requests == 2)
    await coordinator.shutdown()
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
  private var startCount = 0
  private var observerCount = 0
  private var configurationReadCount = 0
  private var shutdownCount = 0
  private var recordedChanges: [DashboardConversationChange] = []

  var starts: Int { lock.withLock { startCount } }
  var observers: Int { lock.withLock { observerCount } }
  var configurationReads: Int { lock.withLock { configurationReadCount } }
  var shutdowns: Int { lock.withLock { shutdownCount } }
  var changes: [DashboardConversationChange] { lock.withLock { recordedChanges } }

  func started() { lock.withLock { startCount += 1 } }
  func observedConfiguration() { lock.withLock { observerCount += 1 } }
  func readConfiguration() { lock.withLock { configurationReadCount += 1 } }
  func shutDown() { lock.withLock { shutdownCount += 1 } }
  func record(_ change: DashboardConversationChange) {
    lock.withLock { recordedChanges.append(change) }
  }
}

private final class ConfigurationTestProcessLease: LocalACPProcessLeasing, @unchecked Sendable {
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
