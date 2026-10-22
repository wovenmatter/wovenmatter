import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage refresh ownership")
struct UsageRefreshOwnershipTests {

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
