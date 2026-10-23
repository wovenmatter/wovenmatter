import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage refresh ownership")
struct UsageRefreshOwnershipTests {

  @Test("Limits include each saved account without changing the preferred account")
  func limitsIncludeAllAccounts() async throws {
    let fixture = try UsageOwnershipDirectory()
    let choices = [
      UsageConnectionChoice(provider: .codex, connectionID: "openai-codex", accountID: "primary", label: "Personal", preferred: true),
      UsageConnectionChoice(provider: .codex, connectionID: "openai-codex", accountID: "backup", label: "Work", preferred: false),
    ]
    let service = LocalUsageService(homeDirectory: fixture.url, fileManager: .default,
      credentialStore: UsageNoCredentials(), usageDatabaseURL: fixture.databaseURL,
      usesSharedConnections: true, sharedConnectionRevision: { 0 },
      sharedConnectionChoices: { _ in choices }, limitCollector: { request in
        request.selectedConnections.values.map { choice in
          UsageLimitAccount(provider: choice.provider, accountScopeID: choice.id, accountLabel: choice.label,
            status: .available, source: "fixture", detail: "", observedAt: request.now)
        }
      })
    let result = try await service.limitsSnapshot(refresh: true, enabledProviders: [.codex])
    #expect(result.accounts.map(\.accountLabel) == ["Personal", "Work"])
    #expect(Set(result.accounts.map(\.id)).count == 2)
    let cached = try await service.limitsSnapshot(refresh: false, enabledProviders: [.codex])
    #expect(cached.accounts == result.accounts)
  }

  @Test("Denied account enumeration is not reported as signed out")
  func deniedAccountEnumeration() async throws {
    struct Denied: Error {}
    let fixture = try UsageOwnershipDirectory()
    let service = LocalUsageService(homeDirectory: fixture.url, fileManager: .default,
      credentialStore: UsageNoCredentials(), usageDatabaseURL: fixture.databaseURL,
      usesSharedConnections: true, sharedConnectionRevision: { 0 },
      sharedConnectionChoices: { _ in throw Denied() })
    await #expect(throws: Denied.self) {
      try await service.limitsSnapshot(refresh: true, enabledProviders: [.codex])
    }
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
    // Shared accounts are session-cached only, so invalidate while their network
    // refresh is pending; there is deliberately no database write to queue.
    if sharedAccountChange {
      revision.advance()
      await gate.release(1, value: [account("obsolete", now: Date())])
      await #expect(throws: CancellationError.self) { try await pending.value }
      #expect(try await store.usageLimitAccounts(providers: [.cursor]).isEmpty)
      return
    }
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
