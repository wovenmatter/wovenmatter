import Foundation
import LocalAuthentication
import Security
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage credential prompt suppression")
struct UsageCredentialStoreTests {

  @Test("analytics never reads credentials, even when account access is unavailable")
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
        now: Date(timeIntervalSince1970: 1_800_000_000)
      )
      #expect(!snapshot.sources.contains { $0.id == "openrouter" })
      #expect(fixture.reads.isEmpty)

    }
  }

  @Test("one-time authorization is reused by limits; device analytics never fetches account activity")
  func authorizedSessionDoesNotReadAgain() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = SessionCredentialFixture()
    let revision = ConnectionRevisionFixture()
    let service = LocalUsageService(
      homeDirectory: directory,
      fileManager: .default,
      credentialStore: credentials,
      usageDatabaseURL: directory.appending(path: "usage.sqlite"),
      sharedConnectionRevision: { revision.value },
      limitCollector: { _ in [] }
    )
    func refresh() async throws -> Bool {
      try await service.snapshot(
        range: .last30Days,
        refreshLimits: true,
        refreshReason: .manual,
        enabledProviders: [.openRouter]
      ).hasOpenRouterCredential
    }

    try await service.authorizeOpenRouterCredentialAccess()
    revision.advance() // An unrelated shared account change must not invalidate this isolated store.
    #expect(try await refresh())
    #expect(try await refresh())
    #expect(credentials.authorizationCount == 1)
    #expect(credentials.presenceChecks == 0)

    credentials.denyAuthorization()
    await #expect(throws: UsageCredentialStoreError.self) {
      try await service.authorizeOpenRouterCredentialAccess()
    }
    #expect(try await refresh())
    #expect(credentials.presenceChecks == 0)

    try await service.saveOpenRouterAPIKey(" replacement ")
    revision.advance()
    #expect(try await refresh())
    #expect(credentials.presenceChecks == 0)

    try await service.deleteOpenRouterAPIKey()
    #expect(try await refresh() == false)
    #expect(credentials.presenceChecks == 1) // Limits only; analytics never checks the key.
  }

  @Test("presence reads attributes only and never allow authentication")
  func noninteractiveReads() throws {
    let fixture = KeychainFixture()
    let store = fixture.store()

    #expect(try store.hasOpenRouterAPIKey())

    let reads = fixture.reads
    #expect(reads.count == 1)
    #expect(reads[0].attributes && !reads[0].secret)
    #expect(reads.allSatisfy { !$0.interactionAllowed && $0.contextDisallowsInteraction })
    #expect(fixture.policyChanges == [false, true])
    #expect(fixture.interactionAllowed)
  }

  @Test("failure to read or suppress the interaction policy fails before accessing the Keychain")
  func suppressionFailureDoesNotRead() {
    for fixture in [
      KeychainFixture(policyStatus: errSecNotAvailable),
      KeychainFixture(suppressionStatus: errSecNotAvailable),
    ] {
      #expect(throws: UsageCredentialStoreError.self) { try fixture.store().hasOpenRouterAPIKey() }
      #expect(fixture.reads.isEmpty)
      #expect(fixture.interactionAllowed)
    }
  }

  @Test("a superseded limits refresh cannot replace the current session cache")
  func supersededRefreshDoesNotPublishStaleLimits() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = LimitRefreshGate()
    let service = LocalUsageService(homeDirectory: directory, fileManager: .default,
      credentialStore: SessionCredentialFixture(), usageDatabaseURL: directory.appending(path: "usage.sqlite"),
      sharedConnectionRevision: { 0 },
      limitCollector: { request in
        if request.now.timeIntervalSince1970 == 200 { await gate.hold() }
        return [UsageLimitAccount(provider: .openRouter, accountLabel: "At \(request.now.timeIntervalSince1970)",
          status: .available, source: "Fixture", detail: "Fixture", observedAt: request.now)]
      })
    let initial = try await service.limitsSnapshot(refresh: true,
      enabledProviders: [.openRouter], allowCredentialAccess: false, now: Date(timeIntervalSince1970: 100))
    let outdated = Task { try await service.limitsSnapshot(refresh: true,
      enabledProviders: [.openRouter], allowCredentialAccess: false, now: Date(timeIntervalSince1970: 200)) }
    await gate.waitForArrival()
    let current = try await service.limitsSnapshot(refresh: false,
      enabledProviders: [.openRouter], allowCredentialAccess: false)
    #expect(current.accounts.first?.accountLabel == initial.accounts.first?.accountLabel)
    await gate.open()
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
      update: { _, _ in errSecSuccess },
      add: { _ in errSecSuccess },
      delete: { _ in errSecSuccess }
    ))
  }
}

private final class SessionCredentialFixture: UsageCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var key: String? = "original"
  private var shouldDenyAuthorization = false
  private var authorizations = 0
  private var presence = 0

  var authorizationCount: Int { lock.withLock { authorizations } }
  var presenceChecks: Int { lock.withLock { presence } }
  func denyAuthorization() { lock.withLock { shouldDenyAuthorization = true } }
  func hasOpenRouterAPIKey() throws -> Bool { lock.withLock { presence += 1; return key != nil } }
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

/// Holds one limits refresh inside its collector until the test releases it.
private actor LimitRefreshGate {
  private var arrivals = 0
  private var opened = false
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func hold() async {
    arrivals += 1
    arrivalWaiters.forEach { $0.resume() }
    arrivalWaiters = []
    guard !opened else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitForArrival() async {
    guard arrivals == 0 else { return }
    await withCheckedContinuation { arrivalWaiters.append($0) }
  }

  func open() {
    opened = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters = []
  }
}

private final class ConnectionRevisionFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var revision: UInt64 = 0
  var value: UInt64 { lock.withLock { revision } }
  func advance() { lock.withLock { revision += 1 } }
}
