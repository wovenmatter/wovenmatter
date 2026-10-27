import Foundation
import LocalAuthentication
import Security
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Provider credential probe policy")
struct ProviderCredentialProbeTests {




  @Test("blocked probes retain workspace scope and can preserve last-good limits")
  func unavailableRetainsScope() async {
    let blocked = await ProviderLimitCollector.credentialSensitiveAccount(
      provider: .codex,
      accountScopeID: "workspace-fixture",
      accountLabel: "Fixture workspace",
      keychainInteraction: .noninteractive,
      interactiveProvider: nil,
      now: now,
      directRead: { _ in nil },
      commandRead: { Issue.record("Unexpected CLI probe"); return fixtureAccount(.codex) }
    )
    #expect(blocked.accountScopeID == "workspace-fixture")
    #expect(blocked.accountLabel == "Fixture workspace")
    let prior = UsageLimitAccount(
      provider: .codex,
      accountScopeID: "workspace-fixture",
      accountLabel: "Fixture workspace",
      status: .available,
      quotaWindows: [.init(id: "daily", label: "Daily", usedPercent: 35, usageKnown: true,
                           windowMinutes: 1440, resetsAt: nil)],
      source: "Fixture cache",
      detail: "Last success",
      observedAt: now.addingTimeInterval(-60)
    )
    let retained = prior.retainingLastGood(after: blocked)
    #expect(retained.isStale)
    #expect(retained.quotaWindows == prior.quotaWindows)
    #expect(retained.refreshError == blocked.detail)
  }



  @Test("one explicit Claude Allow is reused by subsequent quiet refreshes")
  func claudeExplicitReadIsCached() throws {
    let fixture = ClaudeKeychainFixture()
    let cache = ClaudeUsageCredentialCache()
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    fixture.expectsInteraction = true
    try ProviderLimitCollector.authorizeClaudeCredentialAccess(
      credentialsURL: url, keychain: fixture.access, cache: cache
    )
    #expect(fixture.readCount == 1)
    #expect(fixture.policyChanges.isEmpty)

    // A later Keychain read would be denied, but a one-time Allow remains useful.
    fixture.status = errSecInteractionNotAllowed
    fixture.expectsInteraction = false
    for _ in 0..<10 {
      #expect(ProviderLimitCollector.claudeOAuthToken(
        credentialsURL: url, keychain: fixture.access, cache: cache
      ) == "fixture-token")
    }
    #expect(fixture.readCount == 1)
    #expect(fixture.policyChanges.isEmpty)

    fixture.expectsInteraction = true
    #expect(throws: ClaudeUsageCredentialError.self) {
      try ProviderLimitCollector.authorizeClaudeCredentialAccess(
        credentialsURL: url, keychain: fixture.access, cache: cache
      )
    }
    #expect(fixture.readCount == 2)
    #expect(ProviderLimitCollector.claudeOAuthToken(
      credentialsURL: url, keychain: fixture.access, cache: cache
    ) == "fixture-token")
    #expect(fixture.readCount == 2)

    fixture.status = errSecSuccess
    fixture.token = "replacement-token"
    fixture.expectsInteraction = true
    try ProviderLimitCollector.authorizeClaudeCredentialAccess(
      credentialsURL: url, keychain: fixture.access, cache: cache
    )
    #expect(fixture.readCount == 3)
    #expect(ProviderLimitCollector.claudeOAuthToken(
      credentialsURL: url, keychain: fixture.access, cache: cache
    ) == "replacement-token")
    #expect(fixture.readCount == 3)
    cache.receivedResponse(statusCode: 401, token: "fixture-token", credentialsURL: url)
    #expect(ProviderLimitCollector.claudeOAuthToken(
      credentialsURL: url, keychain: fixture.access, cache: cache
    ) == "replacement-token")
    #expect(fixture.readCount == 3)
    try Data(#"{"claudeAiOauth":{"accessToken":"file-token"}}"#.utf8).write(to: url)
    #expect(ProviderLimitCollector.claudeOAuthToken(
      credentialsURL: url, keychain: fixture.access, cache: cache
    ) == "file-token")
    #expect(fixture.readCount == 3)
  }



  private static let providers: [ProviderKind] = [.codex, .claude, .grok, .cursor]
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("passive refreshes never invoke a credential-reading child process",
        arguments: Self.providers)
  func passiveRefreshes(provider: ProviderKind) async {
    let probe = ProbeRecorder()
    for reason in [UsageRefreshReason.startup, .viewAppeared, .rangeChanged,
                   .manual, .periodic, .runCompleted] {
      let account = await collect(
        provider: provider,
        interaction: .resolve(
          refreshReason: reason,
          disclosureAcknowledged: true,
          explicitUserAction: true
        ),
        selected: provider,
        probe: probe
      )
      #expect(account.status == .unavailable)
      #expect(!account.detail.contains("Retry access"))
    }
    #expect(await probe.interactions == Array(repeating: .noninteractive, count: 6))
    #expect(await probe.commandReads == 0)
  }


  private func collect(
    provider: ProviderKind,
    interaction: UsageKeychainInteraction,
    selected: ProviderKind?,
    probe: ProbeRecorder
  ) async -> UsageLimitAccount {
    await ProviderLimitCollector.credentialSensitiveAccount(
      provider: provider,
      keychainInteraction: interaction,
      interactiveProvider: selected,
      now: now,
      directRead: { policy in await probe.recordDirect(policy); return nil },
      commandRead: { await probe.recordCommand(); return fixtureAccount(provider, source: "Fixture CLI") }
    )
  }
}

private actor ProbeRecorder {
  var interactions: [UsageKeychainInteraction] = []
  var commandReads = 0
  func recordDirect(_ interaction: UsageKeychainInteraction) { interactions.append(interaction) }
  func recordCommand() { commandReads += 1 }
}

private func fixtureAccount(_ provider: ProviderKind, source: String = "Fixture") -> UsageLimitAccount {
  UsageLimitAccount(provider: provider, accountLabel: "Fixture", status: .available,
                    source: source, detail: "Fixture", observedAt: Date(timeIntervalSince1970: 1_800_000_000))
}

private final class ClaudeKeychainFixture: @unchecked Sendable {
  // All operations run synchronously while KeychainAccess holds its shared lock.
  var interactionAllowed = true
  var policyChanges: [Bool] = []
  var readCount = 0
  var status: OSStatus
  var token = "fixture-token"
  var expectsInteraction = false

  init(status: OSStatus = errSecSuccess) { self.status = status }

  var access: KeychainAccess {
    KeychainAccess(operations: KeychainOperations(
      copyMatching: { [self] query in
        readCount += 1
        #expect(interactionAllowed == expectsInteraction)
        if !expectsInteraction {
          #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        }
        #expect(query[kSecAttrService as String] as? String == "Claude Code-credentials")
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token]])
        return (status, status == errSecSuccess ? data as CFData : nil)
      },
      getInteractionAllowed: { [self] in (errSecSuccess, interactionAllowed) },
      setInteractionAllowed: { [self] allowed in
        policyChanges.append(allowed)
        interactionAllowed = allowed
        return errSecSuccess
      },
      update: { _, _ in Issue.record("Unexpected credential update"); return errSecParam },
      add: { _ in Issue.record("Unexpected credential add"); return errSecParam },
      delete: { _ in Issue.record("Unexpected credential delete"); return errSecParam }
    ))
  }
}
