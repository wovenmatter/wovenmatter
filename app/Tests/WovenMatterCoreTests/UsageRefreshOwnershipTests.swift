import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage refresh ownership")
struct UsageRefreshOwnershipTests {
  @Test("Non-cooperating superseded loads cannot return or replace cache", arguments: [false, true])
  func supersededLoads(forceSameKey: Bool) async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let gate = UsageCompletionGate<Int>()
    let old = Task { try await coordinator.value(for: "old", policy: .refresh) { await gate.load() } }
    await gate.waitForStarts(1)
    let key = forceSameKey ? "old" : "new"
    let current = Task {
      try await coordinator.value(for: key, policy: forceSameKey ? .force : .refresh) { await gate.load() }
    }
    await gate.waitForStarts(2)
    await gate.release(2, value: 22)
    #expect(try await current.value == 22)
    await gate.release(1, value: 11)
    await #expect(throws: CancellationError.self) { try await old.value }
    #expect(try await coordinator.value(for: key, policy: .reuse) { -1 } == 22)
    #expect(await coordinator.isRefreshing == false)
  }

  @Test("All coalesced consumers can receive one successful generation")
  func coalescedConsumers() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let gate = UsageCompletionGate<Int>()
    let first = Task { try await coordinator.value(for: "shared", policy: .reuse) { await gate.load() } }
    await gate.waitForStarts(1)
    let registrations = UsageConsumerRegistrations(target: 20)
    let consumers = (0..<20).map { _ in
      Task { try await registeredConsumer(coordinator, registrations: registrations) }
    }
    await registrations.wait()
    await gate.release(1, value: 42)
    #expect(try await first.value == 42)
    for consumer in consumers { #expect(try await consumer.value == 42) }
    #expect(await gate.startCount == 1)
  }

  // Both registration and value entry execute on the coordinator actor without a hop.
  // The synchronous signal therefore proves all consumers joined before releasing the load.
  private func registeredConsumer(
    _ coordinator: isolated UsageRefreshCoordinator<String, Int>,
    registrations: UsageConsumerRegistrations
  ) async throws -> Int {
    registrations.arrive()
    return try await coordinator.value(for: "shared", policy: .refresh) { -1 }
  }

  @Test("Returning another cached key supersedes pending work")
  func cachedSelection() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    #expect(try await coordinator.value(for: "saved", policy: .reuse) { 7 } == 7)
    let gate = UsageCompletionGate<Int>()
    let pending = Task { try await coordinator.value(for: "other", policy: .refresh) { await gate.load() } }
    await gate.waitForStarts(1)
    #expect(try await coordinator.value(for: "saved", policy: .reuse) { -1 } == 7)
    await gate.release(1, value: 99)
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await coordinator.value(for: "saved", policy: .reuse) { -1 } == 7)
  }

  @Test("Explicit cancellation rejects a loader that ignores cancellation")
  func explicitCancellation() async {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let gate = UsageCompletionGate<Int>()
    let pending = Task { try await coordinator.value(for: "key", policy: .refresh) { await gate.load() } }
    await gate.waitForStarts(1)
    await coordinator.cancelCurrent()
    await gate.release(1, value: 8)
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await coordinator.isRefreshing == false)
  }

  @Test("Cancelling a consumer does not cancel another consumer's shared value")
  func consumerCancellation() async throws {
    let coordinator = UsageRefreshCoordinator<String, Int>()
    let gate = UsageCompletionGate<Int>()
    let cancelled = Task { try await coordinator.value(for: "shared", policy: .reuse) { await gate.load() } }
    await gate.waitForStarts(1)
    let valid = Task { try await coordinator.value(for: "shared", policy: .reuse) { -1 } }
    cancelled.cancel()
    await gate.release(1, value: 42)
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await valid.value == 42)
  }

  @Test("Late provider limits cannot overwrite latest memory or persistent snapshot")
  func serviceLimitsOwnership() async throws {
    let fixture = try UsageOwnershipDirectory()
    let gate = UsageCompletionGate<[UsageLimitAccount]>()
    let service = LocalUsageService(
      homeDirectory: fixture.url, fileManager: .default, credentialStore: UsageNoCredentials(),
      usageDatabaseURL: fixture.databaseURL, limitCollector: { _ in await gate.load() }
    )
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let old = Task { try await service.limitsSnapshot(refresh: true, enabledProviders: [.cursor], allowCredentialAccess: false, now: now) }
    await gate.waitForStarts(1)
    let current = Task { try await service.limitsSnapshot(refresh: true, enabledProviders: [.cursor], allowCredentialAccess: false, now: now.addingTimeInterval(1)) }
    await gate.waitForStarts(2)
    let newest = account("new", now: now.addingTimeInterval(1))
    await gate.release(2, value: [newest])
    #expect(try await current.value.accounts == [newest])
    await gate.release(1, value: [account("old", now: now)])
    await #expect(throws: CancellationError.self) { try await old.value }
    let cached = try await service.limitsSnapshot(refresh: false, enabledProviders: [.cursor], allowCredentialAccess: false, now: now.addingTimeInterval(2))
    #expect(cached.accounts == [newest])
    let store = try UsageStore(databaseURL: fixture.databaseURL)
    #expect(try store.usageLimitAccounts(providers: [.cursor]) == [newest])
  }

  @Test("Cancelled or credential-invalidated requests cannot persist limits", arguments: [false, true])
  func invalidatedLimits(credentialChanged: Bool) async throws {
    let fixture = try UsageOwnershipDirectory()
    let gate = UsageCompletionGate<[UsageLimitAccount]>()
    let service = LocalUsageService(
      homeDirectory: fixture.url, fileManager: .default, credentialStore: UsageNoCredentials(),
      usageDatabaseURL: fixture.databaseURL, limitCollector: { _ in await gate.load() }
    )
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let pending = Task { try await service.limitsSnapshot(refresh: true, enabledProviders: [.cursor], allowCredentialAccess: false, now: now) }
    await gate.waitForStarts(1)
    if credentialChanged { try await service.saveOpenRouterAPIKey("synthetic") }
    else { pending.cancel() }
    await gate.release(1, value: [account("obsolete", now: now)])
    await #expect(throws: CancellationError.self) { try await pending.value }
    let store = try UsageStore(databaseURL: fixture.databaseURL)
    #expect(try store.usageLimitAccounts(providers: [.cursor]).isEmpty)
  }

  @Test("Shared connections never reuse a persisted previous account or harness quota")
  func sharedLimitsDoNotInheritAnotherAccount() async throws {
    let fixture = try UsageOwnershipDirectory()
    let now = Date()
    let prior = UsageLimitAccount(provider: .grok, accountScopeID: "wovenmatter.shared.xai",
      accountLabel: "previous-account", status: .available, source: "fixture", detail: "", observedAt: now)
    let store = try UsageStore(databaseURL: fixture.databaseURL)
    try store.saveUsageLimitAccounts([prior], storedAt: now)
    let service = LocalUsageService(
      homeDirectory: fixture.url, fileManager: .default, credentialStore: UsageNoCredentials(),
      usageDatabaseURL: fixture.databaseURL, usesSharedConnections: true,
      sharedConnectionRevision: { 0 }, limitCollector: { _ in
        [UsageLimitAccount(provider: .grok, accountScopeID: "wovenmatter.shared.xai",
          accountLabel: "current-account", status: .unavailable, source: "fixture", detail: "", observedAt: now)]
      })
    let result = try await service.limitsSnapshot(refresh: true, enabledProviders: [.grok], allowCredentialAccess: false)
    #expect(result.accounts.first?.accountLabel == "current-account")
    #expect(result.accounts.first?.status == .unavailable)
    #expect(result.codexWorkspaces.isEmpty)
  }

  @Test("shared account changes invalidate a suspended refresh without touching real accounts")
  func changedSharedConnectionRejectsOldLimits() async throws {
    final class Revision: @unchecked Sendable {
      let lock = NSLock()
      private var value: UInt64 = 0
      func read() -> UInt64 { lock.withLock { value } }
      func advance() { lock.withLock { value += 1 } }
    }
    let fixture = try UsageOwnershipDirectory()
    let revision = Revision()
    let gate = UsageCompletionGate<[UsageLimitAccount]>()
    let service = LocalUsageService(homeDirectory: fixture.url, fileManager: .default,
      credentialStore: UsageNoCredentials(), usageDatabaseURL: fixture.databaseURL,
      usesSharedConnections: true, sharedConnectionRevision: { revision.read() },
      limitCollector: { _ in await gate.load() })
    let pending = Task { try await service.limitsSnapshot(refresh: true,
      enabledProviders: [.cursor], allowCredentialAccess: false) }
    await gate.waitForStarts(1)
    revision.advance()
    await gate.release(1, value: [account("old-account", now: Date())])
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try UsageStore(databaseURL: fixture.databaseURL).usageLimitAccounts(providers: [.cursor]).isEmpty)
  }

  @Test("Queued limits cannot persist after credential or shared-account invalidation", arguments: [false, true])
  func queuedLimitsOwnership(sharedAccountChange: Bool) async throws {
    final class Revision: @unchecked Sendable {
      private let lock = NSLock()
      private var value: UInt64 = 0
      func read() -> UInt64 { lock.withLock { value } }
      func advance() { lock.withLock { value += 1 } }
    }
    let fixture = try UsageOwnershipDirectory()
    let revision = Revision()
    let gate = UsageCompletionGate<[UsageLimitAccount]>()
    let service = LocalUsageService(homeDirectory: fixture.url, fileManager: .default,
      credentialStore: UsageNoCredentials(), usageDatabaseURL: fixture.databaseURL,
      usesSharedConnections: sharedAccountChange, sharedConnectionRevision: { revision.read() },
      limitCollector: { _ in await gate.load() })
    _ = try await service.limitsSnapshot(refresh: false, enabledProviders: [.cursor], allowCredentialAccess: false)
    let pending = Task { try await service.limitsSnapshot(refresh: true,
      enabledProviders: [.cursor], allowCredentialAccess: false) }
    await gate.waitForStarts(1)
    let store = try await AsyncUsageStore(databaseURL: fixture.databaseURL)
    let workers = DatabaseWorkers.shared(url: fixture.databaseURL)
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task { try await store.write { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 10) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    await gate.release(1, value: [account("obsolete", now: Date())])
    try await waitForUsageJob { workers.writer.metrics.pending == 2 }
    if sharedAccountChange { revision.advance() }
    else { try await service.saveOpenRouterAPIKey("synthetic") }
    release.signal()
    try await blocked.value
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await store.usageLimitAccounts(providers: [.cursor]).isEmpty)
  }

  @Test("Transcript preparation does not occupy the workspace writer and invalidation cancels it")
  func preparationHasSeparateLane() async throws {
    let fixture = try UsageOwnershipDirectory()
    let store = try await AsyncUsageStore(databaseURL: fixture.databaseURL)
    let preparation = DatabaseWorker(label: "usage.preparation.fixture", capacity: 4)
    let ownership = UsageRefreshOwnership()
    let importer = UsageTranscriptImporter(homeDirectory: fixture.url, outcomes: [:],
      ownership: ownership, preparationWorker: preparation)
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task { try await preparation.perform { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 10) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    let now = Date()
    let importing = Task { try await importer.run(store: store,
      cutoff: now.addingTimeInterval(-86_400), enabledProviders: [.codex], now: now) }
    try await waitForUsageJob { preparation.metrics.pending == 2 }
    try await store.setMetadataDate(now, for: "writer-remains-available")
    #expect(try await store.metadataDate("writer-remains-available") == now)
    ownership.invalidate()
    release.signal()
    try await blocked.value
    await #expect(throws: CancellationError.self) { try await importing.value }
    #expect(try await store.metadataDate("usage.local-indexed-after") == nil)
  }

  @Test("Live observations allocate their sequence from the current writer cursor")
  func recorderUsesCurrentCursor() async throws {
    let fixture = try UsageOwnershipDirectory()
    let recorder = try await UsageRunRecorder(databaseURL: fixture.databaseURL)
    let store = try await AsyncUsageStore(databaseURL: fixture.databaseURL)
    let now = Date()
    let advancedCursor = Int64.max - 1_000
    let source = UsageIngestionSource(id: "wovenmatter:local", displayName: "Fixture",
      kind: .wovenMatter, location: "Fixture", installationID: "fixture")
    let event = UsageIngestionEvent(id: "seed", sequence: advancedCursor, timestamp: now,
      provider: .codex, accountLabel: "Fixture", model: "fixture", harness: "Codex",
      application: "Fixture", sessionID: "seed", tokens: .init(inputTokens: 1))
    try await store.ingest(page: .init(source: source, events: [event],
      nextCursor: String(advancedCursor), hasMore: false, generatedAt: now),
      endpoint: "wovenmatter://local", importedAt: now)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask {
          try await recorder.record(.init(runID: "run-\(index)", timestamp: now,
            runtimeKind: .codex, sessionID: "session-\(index)", model: "fixture",
            reasoningLevel: nil, agent: nil, workspace: nil,
            tokens: .init(inputTokens: 3), costUSD: nil))
        }
      }
      try await group.waitForAll()
    }
    #expect(try await store.runtimeSyncState(endpoint: "wovenmatter://local")?.cursor == String(advancedCursor + 20))
    #expect(try await store.samples(in: DateInterval(start: now.addingTimeInterval(-1), duration: 2)).count == 21)
  }

  private func waitForUsageJob(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !ready() {
      guard ContinuousClock.now < deadline else { throw DatabaseWorkerError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private func account(_ label: String, now: Date) -> UsageLimitAccount {
    UsageLimitAccount(provider: .cursor, accountLabel: label, status: .available,
      source: "fixture", detail: "synthetic", observedAt: now)
  }
}

private actor UsageCompletionGate<Value: Sendable> {
  private(set) var startCount = 0
  private var loads: [Int: CheckedContinuation<Value, Never>] = [:]
  private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

  func load() async -> Value {
    startCount += 1
    let invocation = startCount
    return await withCheckedContinuation { continuation in
      loads[invocation] = continuation
      let ready = observers.filter { $0.0 <= startCount }
      observers.removeAll { $0.0 <= startCount }
      ready.forEach { $0.1.resume() }
    }
  }

  func waitForStarts(_ count: Int) async {
    if startCount >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }

  func release(_ invocation: Int, value: Value) {
    loads.removeValue(forKey: invocation)!.resume(returning: value)
  }
}

private struct UsageNoCredentials: UsageCredentialStoring {
  func hasOpenRouterAPIKey() throws -> Bool { false }
  func authorizeOpenRouterAPIKey() throws -> String? { try loadOpenRouterAPIKey() }

  func loadOpenRouterAPIKey() throws -> String? { nil }
  func saveOpenRouterAPIKey(_ key: String) throws {}
  func deleteOpenRouterAPIKey() throws {}
}

private final class UsageOwnershipDirectory: @unchecked Sendable {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  var databaseURL: URL { url.appending(path: "usage.sqlite") }
  init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(at: url) }
}

private final class UsageConsumerRegistrations: @unchecked Sendable {
  private let lock = NSLock()
  private let target: Int
  private var count = 0
  private var observer: CheckedContinuation<Void, Never>?
  init(target: Int) { self.target = target }
  func arrive() {
    let ready = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      count += 1
      guard count == target else { return nil }
      defer { observer = nil }
      return observer
    }
    ready?.resume()
  }
  func wait() async {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock {
        if count == target { return true }
        observer = continuation
        return false
      }
      if ready { continuation.resume() }
    }
  }
}
