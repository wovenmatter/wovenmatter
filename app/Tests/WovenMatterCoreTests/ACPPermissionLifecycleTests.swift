import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPPermissionLifecycleTests {
  @Test func storedPermissionBelongsToTheSessionAndSurvivesDatabaseReopen() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild)
    defer { fixture.cleanUp() }
    try fixture.database.updateLocalACPSessionConfiguration(
      conversationID: fixture.id, model: nil, thinking: nil, permission: "auto"
    )
    let result = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
    )
    #expect(result.permission == "auto")
    #expect(fixture.factory.drivers.map(\.launchPermission) == ["auto"])
    let reopened = try WorkspaceDatabase(url: fixture.databaseURL)
    #expect(try reopened.localACPSession(conversationID: fixture.id).permission == "auto")
    #expect(try reopened.localACPSession(conversationID: fixture.id).acpSessionID == "native-0")
    await fixture.coordinator.shutdown()
  }

  @Test func grokPermissionRestartKeepsNativeIdentityAndOtherSessionsAlive() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild)
    defer { fixture.cleanUp() }
    _ = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
    )
    let other = try fixture.database.createLocalACPSession(
      runtimeKind: .grokBuild, title: "Unchanged", ownerDeviceID: UUID()
    )
    _ = try await fixture.coordinator.configuration(
      conversationID: other, launch: fixture.launch, workspace: fixture.workspace
    )
    let changed = try await fixture.coordinator.updateConfiguration(
      conversationID: fixture.id, permission: "dontAsk", launch: fixture.launch, workspace: fixture.workspace
    )
    let drivers = fixture.factory.drivers
    #expect(drivers.count == 3)
    #expect(drivers[0].shutdownCount == 1)
    #expect(drivers[1].shutdownCount == 0)
    #expect(drivers[2].existingSessionID == "native-0")
    #expect(drivers[2].launchPermission == "dontAsk")
    #expect(changed.permission == "dontAsk")
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).acpSessionID == "native-0")
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).permission == "dontAsk")
    #expect(try fixture.database.localACPSession(conversationID: other).permission == "default")
    await fixture.coordinator.shutdown()
  }

  @Test func launchPreservesRemoteCommandMetadataWhenApplyingSessionPermission() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild)
    defer { fixture.cleanUp() }
    let wrapped = LocalACPRuntimeWrappedCommand(
      argumentIndex: 2, command: ["env", "FIXTURE=1", "grok", "agent", "acp"], harnessArgumentsStartIndex: 3
    )
    let launch = LocalACPRuntimeLaunchConfiguration(
      runtimeKind: .grokBuild, executableURL: fixture.launch.executableURL,
      arguments: ["host", "--", "quoted-command"], environment: ["OUTER": "kept"],
      environmentKeysToRemove: ["REMOVE"], environmentKeyPrefixesToRemove: ["TOKEN_"],
      processWorkingDirectoryURL: fixture.directory,
      wrappedCommand: wrapped
    )
    _ = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: launch, workspace: fixture.workspace
    )
    let observed = try #require(fixture.factory.drivers.first?.launch)
    #expect(observed.wrappedCommand?.command == wrapped.command)
    #expect(observed.wrappedCommand?.argumentIndex == wrapped.argumentIndex)
    #expect(observed.wrappedCommand?.harnessArgumentsStartIndex == wrapped.harnessArgumentsStartIndex)
    #expect(observed.arguments == launch.arguments)
    #expect(observed.environment == launch.environment)
    #expect(observed.environmentKeysToRemove == launch.environmentKeysToRemove)
    #expect(observed.environmentKeyPrefixesToRemove == launch.environmentKeyPrefixesToRemove)
    #expect(observed.processWorkingDirectoryURL == launch.processWorkingDirectoryURL)
    await fixture.coordinator.shutdown()
  }

  @Test func failedRestartRetainsPreviousPolicyAndCanReconnectAgain() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild, failingLaunchPermission: "dontAsk")
    defer { fixture.cleanUp() }
    _ = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
    )
    await #expect(throws: PermissionFixtureError.self) {
      try await fixture.coordinator.updateConfiguration(
        conversationID: fixture.id, permission: "dontAsk", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).permission == "default")
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).acpSessionID == "native-0")
    let recovered = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
    )
    #expect(recovered.permission == "default")
    #expect(fixture.factory.drivers.map(\.launchPermission) == [nil, "dontAsk", "default"])
    #expect(fixture.factory.drivers[1].shutdownCount == 1)
    #expect(fixture.factory.drivers[2].existingSessionID == "native-0")
    await fixture.coordinator.shutdown()
  }

  @Test func permissionRestartCannotForkTheNativeSession() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild, forkedLaunchPermission: "dontAsk")
    defer { fixture.cleanUp() }
    _ = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
    )
    await #expect(throws: (any Error).self) {
      try await fixture.coordinator.updateConfiguration(
        conversationID: fixture.id, permission: "dontAsk", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).acpSessionID == "native-0")
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).permission == "default")
    #expect(fixture.factory.drivers[1].shutdownCount == 1)
    await fixture.coordinator.shutdown()
  }

  @Test func unconfirmedNativePermissionAndObserverDoNotReplaceSavedPolicy() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .codex, unconfirmedPermission: "dontAsk")
    defer { fixture.cleanUp() }
    _ = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
    )
    let changed = try await fixture.coordinator.updateConfiguration(
      conversationID: fixture.id, permission: "auto", launch: fixture.launch, workspace: fixture.workspace
    )
    #expect(changed.permission == "auto")
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).permission == "auto")
    await #expect(throws: LocalACPClientError.self) {
      try await fixture.coordinator.updateConfiguration(
        conversationID: fixture.id, permission: "dontAsk", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    // The fake emits a different native policy before returning a clamped result.
    // Neither that observer nor the rejected setter may persist the requested value.
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).permission == "auto")
    #expect(fixture.factory.drivers.count == 1)
    #expect(fixture.factory.drivers[0].shutdownCount == 1)
    await fixture.coordinator.shutdown()
  }

  @Test func permissionChangeOnAClosedSessionCannotForkItsSavedNativeIdentity() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild, forkedLaunchPermission: "dontAsk")
    defer { fixture.cleanUp() }
    try fixture.database.updateLocalACPSessionID(conversationID: fixture.id, sessionID: "existing-native")
    try fixture.database.updateLocalACPSessionConfiguration(
      conversationID: fixture.id, model: nil, thinking: nil, permission: "default"
    )
    await #expect(throws: (any Error).self) {
      try await fixture.coordinator.updateConfiguration(
        conversationID: fixture.id, permission: "dontAsk", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    #expect(fixture.factory.drivers.count == 1)
    #expect(fixture.factory.drivers[0].existingSessionID == "existing-native")
    #expect(fixture.factory.drivers[0].shutdownCount == 1)
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).acpSessionID == "existing-native")
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).permission == "default")
    await fixture.coordinator.shutdown()
  }

  @Test(.timeLimit(.minutes(1)))
  func permissionsCannotChangeDuringAnActivePrompt() async throws {
    let gate = PermissionLifecycleGate()
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild, promptGate: gate)
    defer { fixture.cleanUp() }
    _ = try await fixture.coordinator.accept(
      conversationID: fixture.id, content: "Fixture prompt", launch: fixture.launch, workspace: fixture.workspace
    )
    await gate.waitUntilEntered()
    await #expect(throws: LocalACPSessionDatabaseError.runAlreadyActive) {
      try await fixture.coordinator.updateConfiguration(
        conversationID: fixture.id, permission: "auto", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    #expect(fixture.factory.drivers.count == 1)
    #expect(fixture.factory.drivers[0].permissionRequests.isEmpty)
    await gate.release()
    await fixture.coordinator.shutdown()
  }

  @Test(.timeLimit(.minutes(1)))
  func restartRejectsNewWorkForThatConversationUntilConfirmation() async throws {
    let gate = PermissionLifecycleGate()
    let fixture = try PermissionLifecycleFixture(runtime: .grokBuild, gatedLaunchPermission: "auto", launchGate: gate)
    defer { fixture.cleanUp() }
    _ = try await fixture.coordinator.configuration(
      conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
    )
    let mutation = Task {
      try await fixture.coordinator.updateConfiguration(
        conversationID: fixture.id, permission: "auto", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    await gate.waitUntilEntered()
    await #expect(throws: (any Error).self) {
      try await fixture.coordinator.accept(
        conversationID: fixture.id, content: "Must not run", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    await #expect(throws: (any Error).self) {
      try await fixture.coordinator.updateConfiguration(
        conversationID: fixture.id, permission: "dontAsk", launch: fixture.launch, workspace: fixture.workspace
      )
    }
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).permission == "default")
    let other = try fixture.database.createLocalACPSession(
      runtimeKind: .grokBuild, title: "Independent", ownerDeviceID: UUID()
    )
    _ = try await fixture.coordinator.configuration(
      conversationID: other, launch: fixture.launch, workspace: fixture.workspace
    )
    await gate.release()
    #expect(try await mutation.value.permission == "auto")
    #expect(fixture.factory.drivers.allSatisfy { $0.promptCount == 0 })
    await fixture.coordinator.shutdown()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [SessionSelectionField.model, .thinking, .permission])
  func obsoleteSavedChoiceCanBeReplacedBeforeNextPrompt(field: SessionSelectionField) async throws {
    let gate = PermissionLifecycleGate()
    let fixture = try PermissionLifecycleFixture(runtime: .codex, promptGate: gate)
    defer { fixture.cleanUp() }
    try fixture.database.updateLocalACPSessionConfiguration(
      conversationID: fixture.id,
      model: field == .model ? "obsolete" : "default-model",
      thinking: field == .thinking ? "obsolete" : "low",
      permission: field == .permission ? "obsolete" : "default"
    )
    await #expect(throws: LocalACPClientError.self) {
      try await fixture.coordinator.configuration(
        conversationID: fixture.id, launch: fixture.launch, workspace: fixture.workspace
      )
    }
    #expect(!fixture.factory.catalogs.isEmpty)
    let unchanged = try fixture.database.localACPSession(conversationID: fixture.id)
    #expect(field != .model || unchanged.model == "obsolete")
    #expect(field != .thinking || unchanged.thinking == "obsolete")
    #expect(field != .permission || unchanged.permission == "obsolete")
    let changed = try await fixture.coordinator.updateConfiguration(
      conversationID: fixture.id,
      model: field == .model ? "selected-model" : nil,
      thinking: field == .thinking ? "high" : nil,
      permission: field == .permission ? "auto" : nil,
      launch: fixture.launch, workspace: fixture.workspace
    )
    #expect(field != .model || changed.model == "selected-model")
    #expect(field != .thinking || changed.thinking == "high")
    #expect(field != .permission || changed.permission == "auto")
    _ = try await fixture.coordinator.accept(
      conversationID: fixture.id, content: "Recovered fixture", launch: fixture.launch, workspace: fixture.workspace
    )
    await gate.waitUntilEntered()
    #expect(fixture.factory.drivers.last?.promptCount == 1)
    await gate.release()
    await fixture.coordinator.shutdown()
  }

  @Test func choosingModelWithoutThinkingClearsObsoleteEffort() async throws {
    let fixture = try PermissionLifecycleFixture(runtime: .codex)
    defer { fixture.cleanUp() }
    try fixture.database.updateLocalACPSessionConfiguration(
      conversationID: fixture.id, model: "default-model", thinking: "obsolete", permission: "default"
    )
    let changed = try await fixture.coordinator.updateConfiguration(
      conversationID: fixture.id, model: "no-effort", launch: fixture.launch, workspace: fixture.workspace
    )
    #expect(changed.model == "no-effort")
    #expect(changed.thinking == nil)
    #expect(changed.thinkingOptions.isEmpty)
    #expect(try fixture.database.localACPSession(conversationID: fixture.id).thinking == nil)
    await fixture.coordinator.shutdown()
  }
}

private enum PermissionFixtureError: Error { case launchFailed }

private struct PermissionLifecycleFixture: Sendable {
  let directory: URL
  let databaseURL: URL
  let database: WorkspaceDatabase
  let id: String
  let launch: LocalACPRuntimeLaunchConfiguration
  let workspace: LocalACPWorkspaceLaunchConfiguration
  let factory: PermissionLifecycleFactory
  let coordinator: LocalACPSessionCoordinator

  init(
    runtime: AgentRuntimeKind,
    failingLaunchPermission: String? = nil,
    forkedLaunchPermission: String? = nil,
    unconfirmedPermission: String? = nil,
    promptGate: PermissionLifecycleGate? = nil,
    gatedLaunchPermission: String? = nil,
    launchGate: PermissionLifecycleGate? = nil
  ) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    databaseURL = directory.appending(path: "workspace.sqlite")
    database = try WorkspaceDatabase(url: databaseURL)
    id = try database.createLocalACPSession(runtimeKind: runtime, title: "Permission fixture", ownerDeviceID: UUID())
    launch = LocalACPRuntimeLaunchConfiguration(
      runtimeKind: runtime, executableURL: URL(filePath: "/nonexistent-permission-fixture"), arguments: [],
      requestedPermission: "bypassPermissions"
    )
    workspace = LocalACPWorkspaceLaunchConfiguration(rootURL: directory, repositoriesURL: directory)
    let factory = PermissionLifecycleFactory(
      failingLaunchPermission: failingLaunchPermission, forkedLaunchPermission: forkedLaunchPermission,
      unconfirmedPermission: unconfirmedPermission, promptGate: promptGate,
      gatedLaunchPermission: gatedLaunchPermission, launchGate: launchGate
    )
    self.factory = factory
    coordinator = LocalACPSessionCoordinator(
      database: database,
      onChange: { factory.record($0) },
      clientFactory: { launch, _ in factory.makeDriver(launch) }
    )
  }

  func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private final class PermissionLifecycleFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var created: [PermissionLifecycleDriver] = []
  private var emittedCatalogs: [LocalACPSessionConfiguration] = []
  let failingLaunchPermission: String?
  let forkedLaunchPermission: String?
  let unconfirmedPermission: String?
  let promptGate: PermissionLifecycleGate?
  let gatedLaunchPermission: String?
  let launchGate: PermissionLifecycleGate?

  init(
    failingLaunchPermission: String?, forkedLaunchPermission: String?, unconfirmedPermission: String?,
    promptGate: PermissionLifecycleGate?, gatedLaunchPermission: String?, launchGate: PermissionLifecycleGate?
  ) {
    self.failingLaunchPermission = failingLaunchPermission
    self.forkedLaunchPermission = forkedLaunchPermission
    self.unconfirmedPermission = unconfirmedPermission
    self.promptGate = promptGate
    self.gatedLaunchPermission = gatedLaunchPermission
    self.launchGate = launchGate
  }

  var drivers: [PermissionLifecycleDriver] { lock.withLock { created } }
  var catalogs: [LocalACPSessionConfiguration] { lock.withLock { emittedCatalogs } }

  func record(_ change: DashboardConversationChange) {
    if case .configuration(let configuration) = change.phase {
      lock.withLock { emittedCatalogs.append(configuration) }
    }
  }

  func makeDriver(_ launch: LocalACPRuntimeLaunchConfiguration) -> LocalACPSessionDriver {
    let driver = lock.withLock {
      let driver = PermissionLifecycleDriver(index: created.count, launch: launch)
      created.append(driver)
      return driver
    }
    return LocalACPSessionDriver(
      initializeSession: { [self] _, existing, _, _ in
        driver.recordExisting(existing)
        if let policy = launch.requestedPermission {
          if policy == gatedLaunchPermission { await launchGate?.hold() }
          if policy == failingLaunchPermission { throw PermissionFixtureError.launchFailed }
        }
        let forks = launch.requestedPermission != nil && launch.requestedPermission == forkedLaunchPermission
        return LocalACPInitializedSession(
          sessionID: forks ? "unexpected-fork" : existing ?? "native-\(driver.index)",
          loadedExistingSession: existing != nil,
          configuration: driver.configuration
        )
      },
      prompt: { [self] _, _, _, _ in
        driver.recordPrompt()
        await promptGate?.hold()
        return .endTurn
      },
      configuration: { driver.configuration },
      observeConfiguration: { handler in driver.observe(handler) },
      setConfiguration: { model, thinking in driver.select(model: model, thinking: thinking) },
      setPermission: { [self] permission in
        driver.recordPermission(permission)
        guard driver.configuration.permissionOptions.contains(permission) else {
          throw LocalACPClientError.invalidConfigurationValue(field: "permission", value: permission)
        }
        if driver.configuration.permission == permission { return driver.configuration }
        if launch.runtimeKind == .grokBuild { throw LocalACPClientError.permissionChangeRequiresRestart }
        let result = driver.select(permission: permission == unconfirmedPermission ? "default" : permission)
        await driver.emit(result)
        return result
      },
      cancel: {},
      shutdown: { driver.recordShutdown() }
    )
  }
}

private final class PermissionLifecycleDriver: @unchecked Sendable {
  let index: Int
  let launch: LocalACPRuntimeLaunchConfiguration
  let launchPermission: String?
  private let lock = NSLock()
  private var current: LocalACPSessionConfiguration
  private var existingID: String?
  private var shutdowns = 0
  private var prompts = 0
  private var permissions: [String] = []
  private var observer: (@Sendable (LocalACPSessionConfiguration) async -> Void)?

  init(index: Int, launch: LocalACPRuntimeLaunchConfiguration) {
    self.index = index
    self.launch = launch
    launchPermission = launch.requestedPermission
    current = LocalACPSessionConfiguration(
      model: "default-model", thinking: "low", modelOptions: ["default-model", "selected-model", "no-effort"],
      thinkingOptions: ["low", "high"],
      permission: launch.runtimeKind == .grokBuild ? launch.requestedPermission ?? "default" : "default",
      permissionOptions: ["default", "auto", "dontAsk"]
    )
  }

  var configuration: LocalACPSessionConfiguration { lock.withLock { current } }
  var existingSessionID: String? { lock.withLock { existingID } }
  var shutdownCount: Int { lock.withLock { shutdowns } }
  var promptCount: Int { lock.withLock { prompts } }
  var permissionRequests: [String] { lock.withLock { permissions } }
  func recordExisting(_ id: String?) { lock.withLock { existingID = id } }
  func recordShutdown() { lock.withLock { shutdowns += 1 } }
  func recordPrompt() { lock.withLock { prompts += 1 } }
  func recordPermission(_ value: String) { lock.withLock { permissions.append(value) } }
  func observe(_ handler: @escaping @Sendable (LocalACPSessionConfiguration) async -> Void) {
    lock.withLock { observer = handler }
  }
  func emit(_ configuration: LocalACPSessionConfiguration) async {
    let observer = lock.withLock { observer }
    await observer?(configuration)
  }
  func select(model: String? = nil, thinking: String? = nil, permission: String? = nil) -> LocalACPSessionConfiguration {
    lock.withLock {
      if model == "no-effort" {
        current = LocalACPSessionConfiguration(
          model: model, thinking: nil, modelOptions: current.modelOptions, thinkingOptions: [],
          permission: permission ?? current.permission, permissionOptions: current.permissionOptions
        )
      } else {
        current = current.selecting(model: model, thinking: thinking, permission: permission)
      }
      return current
    }
  }
}

private actor PermissionLifecycleGate {
  private var entered = false
  private var released = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func hold() async {
    entered = true
    let waiters = enteredWaiters
    enteredWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
  }

  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}
