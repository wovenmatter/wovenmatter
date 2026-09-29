import Foundation
import LocalAuthentication
import Security
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage credential prompt suppression")
struct UsageCredentialStoreTests {
  @Test("presence reads attributes only and secret reads never allow authentication")
  func noninteractiveReads() throws {
    let fixture = KeychainFixture()
    let store = fixture.store()

    #expect(try store.hasOpenRouterAPIKey())
    #expect(try store.loadOpenRouterAPIKey() == "fixture-key")

    let reads = fixture.reads
    #expect(reads.count == 2)
    #expect(reads[0].attributes && !reads[0].secret)
    #expect(reads[1].secret && !reads[1].attributes)
    #expect(reads.allSatisfy { !$0.interactionAllowed && $0.contextDisallowsInteraction })
    #expect(fixture.policyChanges == [false, true, false, true])
    #expect(fixture.interactionAllowed)
  }

  @Test("denied and missing credentials restore the original interaction policy",
        arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecItemNotFound])
  func failedReadsRestorePolicy(status: OSStatus) throws {
    let fixture = KeychainFixture(readStatus: status)
    let store = fixture.store()
    if status == errSecItemNotFound {
      #expect(try !store.hasOpenRouterAPIKey())
      #expect(try store.loadOpenRouterAPIKey() == nil)
    } else {
      #expect(throws: UsageCredentialStoreError.self) { try store.hasOpenRouterAPIKey() }
      #expect(throws: UsageCredentialStoreError.self) { try store.loadOpenRouterAPIKey() }
    }
    #expect(fixture.policyChanges == [false, true, false, true])
    #expect(fixture.interactionAllowed)
  }

  @Test("a preexisting noninteractive policy is never enabled")
  func preservesDisabledInteraction() throws {
    let fixture = KeychainFixture(initiallyAllowed: false)
    #expect(try fixture.store().hasOpenRouterAPIKey())
    #expect(!fixture.interactionAllowed)
    #expect(fixture.policyChanges == [false, false])
  }

  @Test("failure to read or suppress the interaction policy fails before accessing the Keychain")
  func suppressionFailureDoesNotRead() {
    for fixture in [
      KeychainFixture(policyStatus: errSecNotAvailable),
      KeychainFixture(suppressionStatus: errSecNotAvailable),
    ] {
      #expect(throws: UsageCredentialStoreError.self) { try fixture.store().loadOpenRouterAPIKey() }
      #expect(fixture.reads.isEmpty)
      #expect(fixture.interactionAllowed)
    }
  }

  @Test("concurrent store instances serialize read suppression and explicit changes")
  func concurrentOperationsPreservePolicy() {
    let fixture = KeychainFixture()
    DispatchQueue.concurrentPerform(iterations: 60) { index in
      // Separate instances model limits, analytics, and credential changes.
      let store = fixture.store()
      switch index % 3 {
      case 0: #expect(throws: Never.self) { try store.hasOpenRouterAPIKey() }
      case 1: #expect(throws: Never.self) { try store.saveOpenRouterAPIKey("fixture-replacement") }
      default: #expect(throws: Never.self) { try store.deleteOpenRouterAPIKey() }
      }
    }
    #expect(fixture.reads.count == 20)
    #expect(fixture.reads.allSatisfy { !$0.interactionAllowed })
    #expect(fixture.writePolicies.count == 40)
    #expect(fixture.writePolicies.allSatisfy { $0 })
    #expect(fixture.interactionAllowed)
  }

  @Test("failed background credential reads preserve last-good quota values")
  func deniedLimitRefreshKeepsLastGood() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "usage.sqlite")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let prior = UsageLimitAccount(
      provider: .openRouter,
      accountLabel: "Saved account",
      status: .available,
      balance: ProviderMoney(amountMicros: 20_000_000, currency: "USD"),
      source: "Fixture",
      detail: "Last successful refresh",
      observedAt: now.addingTimeInterval(-120)
    )
    try UsageStore(databaseURL: databaseURL).saveUsageLimitAccounts([prior], storedAt: prior.observedAt)
    let fixture = KeychainFixture(secretStatus: errSecInteractionNotAllowed)
    let service = LocalUsageService(
      homeDirectory: directory,
      fileManager: .default,
      credentialStore: fixture.store(),
      usageDatabaseURL: databaseURL,
      limitCollector: { request in
        #expect(request.openRouterAPIKey == nil)
        return [UsageLimitAccount(
          provider: .openRouter,
          accountLabel: "OpenRouter",
          status: .needsCredential,
          source: "Fixture",
          detail: "No key supplied",
          observedAt: request.now
        )]
      }
    )
    for reason in [UsageRefreshReason.startup, .manual, .credentialChanged] {
      let snapshot = try await service.limitsSnapshot(
        refresh: true,
        refreshReason: reason,
        enabledProviders: [.openRouter],
        keychainInteraction: .oneShotExplicit,
        now: now
      )
      let account = try #require(snapshot.accounts.first)
      #expect(account.balance == prior.balance)
      #expect(account.observedAt == prior.observedAt)
      #expect(account.isStale)
      #expect(account.refreshError?.contains("Keychain") == true)
      #expect(snapshot.hasOpenRouterCredential)
    }
    #expect(fixture.reads.filter(\.secret).count == 3)
    #expect(fixture.reads.allSatisfy { !$0.interactionAllowed && $0.contextDisallowsInteraction })
  }

  @Test("analytics reports inaccessible credentials without asking for a replacement key")
  func deniedAnalyticsRefreshIsHonest() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for fixture in [
      KeychainFixture(secretStatus: errSecInteractionNotAllowed),
      KeychainFixture(readStatus: errSecInteractionNotAllowed),
    ] {
      let service = LocalUsageService(
        homeDirectory: directory,
        fileManager: .default,
        credentialStore: fixture.store(),
        usageDatabaseURL: directory.appending(path: "\(UUID().uuidString).sqlite")
      )
      let snapshot = try await service.analyticsSnapshot(
        range: .last30Days,
        refreshReason: .startup,
        enabledProviders: [.openRouter],
        now: Date(timeIntervalSince1970: 1_800_000_000)
      )
      let source = try #require(snapshot.sources.first { $0.provider == .openRouter })
      #expect(source.detail.contains("Keychain"))
      #expect(!source.detail.contains("Add an OpenRouter"))
      #expect(source.status != .available)
      #expect(fixture.reads.filter(\.secret).count == 1)
      #expect(fixture.reads.allSatisfy { !$0.interactionAllowed && $0.contextDisallowsInteraction })
    }
  }

  @Test("explicit retry performs a single interactive read without changing system policy")
  func explicitRetryReadsOnce() throws {
    let fixture = KeychainFixture()
    #expect(try fixture.store().authorizeOpenRouterAPIKey() == "fixture-key")
    #expect(fixture.reads.count == 1)
    #expect(fixture.reads[0].secret)
    #expect(fixture.reads[0].interactionAllowed)
    #expect(!fixture.reads[0].contextDisallowsInteraction)
    #expect(fixture.policyChanges.isEmpty)
  }

  @Test("one-time authorization is reused by analytics and limits; save and delete replace session access")
  func authorizedSessionDoesNotReadAgain() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = SessionCredentialFixture()
    let collector = CredentialUseRecorder()
    let revision = ConnectionRevisionFixture()
    let service = LocalUsageService(
      homeDirectory: directory,
      fileManager: .default,
      credentialStore: credentials,
      usageDatabaseURL: directory.appending(path: "usage.sqlite"),
      sharedConnectionRevision: { revision.value },
      limitCollector: { request in
        collector.recordLimit(request.openRouterAPIKey)
        return []
      },
      openRouterActivityFetcher: { key in
        collector.recordActivity(key)
        return OpenRouterActivityResult(samplesByUTCDate: [:], detail: "Fixture activity")
      }
    )
    func refresh() async throws {
      _ = try await service.snapshot(
        range: .last30Days,
        refreshLimits: true,
        refreshReason: .manual,
        enabledProviders: [.openRouter]
      )
    }

    try await service.authorizeOpenRouterCredentialAccess()
    revision.advance() // An unrelated shared account change must not invalidate this isolated store.
    try await refresh()
    try await refresh()
    #expect(credentials.authorizationCount == 1)
    #expect(credentials.readCount == 0)
    #expect(collector.limitKeys == ["original", "original"])
    #expect(collector.activityKeys == ["original", "original"])

    credentials.denyAuthorization()
    await #expect(throws: UsageCredentialStoreError.self) {
      try await service.authorizeOpenRouterCredentialAccess()
    }
    try await refresh()
    #expect(collector.limitKeys.last == "original")
    #expect(collector.activityKeys.last == "original")
    #expect(credentials.readCount == 0)

    try await service.saveOpenRouterAPIKey(" replacement ")
    revision.advance()
    try await refresh()
    #expect(collector.limitKeys.last == "replacement")
    #expect(collector.activityKeys.last == "replacement")
    #expect(credentials.readCount == 0)

    try await service.deleteOpenRouterAPIKey()
    try await refresh()
    #expect(collector.limitKeys.last == "missing")
    #expect(collector.activityKeys.count == 4)
    #expect(credentials.readCount == 2)
  }

  @Test("a superseded limits save cannot replace the current session cache")
  func supersededDatabaseSaveDoesNotPublishStaleLimits() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "usage.sqlite")
    let service = LocalUsageService(homeDirectory: directory, fileManager: .default,
      credentialStore: SessionCredentialFixture(), usageDatabaseURL: databaseURL,
      limitCollector: { request in
        [UsageLimitAccount(provider: .openRouter, accountLabel: "At \(request.now.timeIntervalSince1970)",
          status: .available, source: "Fixture", detail: "Fixture", observedAt: request.now)]
      })
    let initial = try await service.limitsSnapshot(refresh: true,
      enabledProviders: [.openRouter], allowCredentialAccess: false, now: Date(timeIntervalSince1970: 100))
    let workers = DatabaseWorkers.shared(url: databaseURL)
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task { try await workers.writer.perform { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    let outdated = Task { try await service.limitsSnapshot(refresh: true,
      enabledProviders: [.openRouter], allowCredentialAccess: false, now: Date(timeIntervalSince1970: 200)) }
    let deadline = ContinuousClock.now + .seconds(60)
    while workers.writer.metrics.pending < 2 {
      guard ContinuousClock.now < deadline else { throw DatabaseWorkerError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
    let current = try await service.limitsSnapshot(refresh: false,
      enabledProviders: [.openRouter], allowCredentialAccess: false)
    #expect(current.accounts.first?.accountLabel == initial.accounts.first?.accountLabel)
    release.signal()
    try await blocked.value
    await #expect(throws: CancellationError.self) { try await outdated.value }
    let cached = try await service.limitsSnapshot(refresh: false,
      enabledProviders: [.openRouter], allowCredentialAccess: false)
    #expect(cached.accounts.first?.accountLabel == initial.accounts.first?.accountLabel)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-keychain-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private final class KeychainFixture: @unchecked Sendable {
  struct Read: Sendable {
    let attributes: Bool
    let secret: Bool
    let interactionAllowed: Bool
    let contextDisallowsInteraction: Bool
  }

  private let lock = NSLock()
  private var allowed: Bool
  private var recordedReads: [Read] = []
  private var recordedPolicyChanges: [Bool] = []
  private var recordedWritePolicies: [Bool] = []
  private let readStatus: OSStatus
  private let secretStatus: OSStatus
  private let policyStatus: OSStatus
  private let suppressionStatus: OSStatus

  init(
    initiallyAllowed: Bool = true,
    readStatus: OSStatus = errSecSuccess,
    secretStatus: OSStatus = errSecSuccess,
    policyStatus: OSStatus = errSecSuccess,
    suppressionStatus: OSStatus = errSecSuccess
  ) {
    allowed = initiallyAllowed
    self.readStatus = readStatus
    self.secretStatus = secretStatus
    self.policyStatus = policyStatus
    self.suppressionStatus = suppressionStatus
  }

  var reads: [Read] { lock.withLock { recordedReads } }
  var policyChanges: [Bool] { lock.withLock { recordedPolicyChanges } }
  var writePolicies: [Bool] { lock.withLock { recordedWritePolicies } }
  var interactionAllowed: Bool { lock.withLock { allowed } }

  func store() -> UsageCredentialStore {
    UsageCredentialStore(service: "test.usage", operations: KeychainOperations(
      copyMatching: { [self] query in
        lock.withLock {
          let secret = query[kSecReturnData as String] as? Bool == true
          recordedReads.append(Read(
            attributes: query[kSecReturnAttributes as String] as? Bool == true,
            secret: secret,
            interactionAllowed: allowed,
            contextDisallowsInteraction:
              (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
          ))
          if readStatus != errSecSuccess { return (readStatus, nil) }
          if secret && secretStatus != errSecSuccess { return (secretStatus, nil) }
          return (errSecSuccess, secret ? Data("fixture-key".utf8) as CFData : [:] as CFDictionary)
        }
      },
      getInteractionAllowed: { [self] in lock.withLock { (policyStatus, allowed) } },
      setInteractionAllowed: { [self] value in
        lock.withLock {
          recordedPolicyChanges.append(value)
          if !value && suppressionStatus != errSecSuccess { return suppressionStatus }
          allowed = value
          return errSecSuccess
        }
      },
      update: { [self] _, _ in recordWrite() },
      add: { [self] _ in recordWrite() },
      delete: { [self] _ in recordWrite() }
    ))
  }

  private func recordWrite() -> OSStatus {
    lock.withLock {
      recordedWritePolicies.append(allowed)
      return errSecSuccess
    }
  }
}

private final class SessionCredentialFixture: UsageCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var key: String? = "original"
  private var shouldDenyAuthorization = false
  private var authorizations = 0
  private var reads = 0

  var authorizationCount: Int { lock.withLock { authorizations } }
  var readCount: Int { lock.withLock { reads } }
  func denyAuthorization() { lock.withLock { shouldDenyAuthorization = true } }
  func hasOpenRouterAPIKey() throws -> Bool { lock.withLock { key != nil } }
  func loadOpenRouterAPIKey() throws -> String? {
    lock.withLock { reads += 1; return key }
  }
  func authorizeOpenRouterAPIKey() throws -> String? {
    try lock.withLock {
      authorizations += 1
      if shouldDenyAuthorization { throw UsageCredentialStoreError.keychain(errSecAuthFailed) }
      return key
    }
  }
  func saveOpenRouterAPIKey(_ value: String) throws { lock.withLock { key = value } }
  func deleteOpenRouterAPIKey() throws { lock.withLock { key = nil } }
}

private final class CredentialUseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var limits: [String] = []
  private var activity: [String] = []
  var limitKeys: [String] { lock.withLock { limits } }
  var activityKeys: [String] { lock.withLock { activity } }
  func recordLimit(_ value: String?) { lock.withLock { limits.append(value ?? "missing") } }
  func recordActivity(_ value: String) { lock.withLock { activity.append(value) } }
}

private final class ConnectionRevisionFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var revision: UInt64 = 0
  var value: UInt64 { lock.withLock { revision } }
  func advance() { lock.withLock { revision += 1 } }
}
