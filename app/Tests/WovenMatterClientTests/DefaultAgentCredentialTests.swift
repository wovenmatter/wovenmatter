#if canImport(Security)
import Foundation
import Security
import Testing
import WovenMatterCore

@testable import WovenMatterClient

private actor CredentialRefreshFixture {
    var calls = 0
    var fail = false
    func refresh(_ scopes: [String]) async throws -> [String: DefaultAgentPayload] {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        if fail { throw DefaultAgentError.message("Fixture unavailable") }
        return Dictionary(
            uniqueKeysWithValues: scopes.map {
                (
                    $0,
                    DefaultAgentPayload(
                        config: .init(), credentials: ["openai": .init(type: "api_key", key: "fixture-secret")],
                        workspace: $0)
                )
            })
    }
    func count() -> Int { calls }
}
private final class CredentialRevisionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func current() -> UInt64 { lock.withLock { value } }
    func advance() { lock.withLock { value += 1 } }
}

@Suite("Built-in credential coordination")
struct DefaultAgentCredentialTests {


    @Test @MainActor func accountMetadataReadsAreOffMainAndReuseCredentialRevision() async throws {
        let reads = CredentialRevisionFixture()
        let revision = CredentialRevisionFixture()
        let store = ProviderConnectionStore(read: { _ in
            #expect(!Thread.isMainThread)
            reads.advance()
            return [:]
        }, version: { revision.current() })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = try await store.accounts(scope: "global") } }
            try await group.waitForAll()
        }
        #expect(reads.current() == 1)
        _ = try await store.perform(invalidatesAccounts: false) { true }
        _ = try await store.accounts(scope: "global")
        #expect(reads.current() == 1)
        revision.advance()
        _ = try await store.accounts(scope: "global")
        #expect(reads.current() == 2)
        _ = try await store.accounts(scope: "local")
        #expect(reads.current() == 3)
    }

    @Test @MainActor func preferenceChangesReuseCredentialsAndUpdatePayloadRevision() async throws {
        let fixture = CredentialRefreshFixture()
        let preferences = CredentialRevisionFixture()
        let scopes = CredentialRevisionFixture()
        let coordinator = ProviderAccountCoordinator(
            refresh: { try await fixture.refresh($0) }, version: { 0 },
            configurationVersion: { preferences.current() }, scopeVersion: { scopes.current() },
            reconfigure: { value in
                var updated = value
                updated.config.defaultModel = "openai/preferred"
                return updated
            })
        let first = try await coordinator.prepare("local")
        coordinator.invalidate()
        let unchanged = try await coordinator.prepare("local")
        #expect(unchanged.revision == first.revision)
        #expect(await fixture.count() == 2)
        preferences.advance()
        let updated = try await coordinator.prepare("local")
        #expect(await fixture.count() == 2)
        #expect(updated.config.defaultModel == "openai/preferred")
        #expect(updated.credentials == first.credentials)
        #expect(updated.revision != first.revision)
        scopes.advance()
        _ = try await coordinator.prepare("local")
        #expect(await fixture.count() == 3)
    }

    @Test func accountMigrationSelectionOrderingAndRemovalPreserveCanonicalKey() throws {
        let keychain = DefaultAgentKeychainFixture().access
        try DefaultAgentSupport.saveKey("legacy", provider: "openrouter", keychain: keychain)
        let legacy = try #require(ProviderConnectionAccounts.list(provider: "openrouter", keychain: keychain).first)
        #expect(legacy.createdAt == nil)
        #expect(legacy.isSelected)
        let second = try ProviderConnectionAccounts.addKey("second", provider: "openrouter", keychain: keychain)
        #expect(try DefaultAgentSupport.key("openrouter", keychain: keychain) == "legacy")
        try ProviderConnectionAccounts.select(second.id, provider: "openrouter", keychain: keychain)
        #expect(try DefaultAgentSupport.key("openrouter", keychain: keychain) == "second")
        #expect(try ProviderConnectionAccounts.credential(legacy.id, provider: "openrouter", keychain: keychain)?.key == "legacy")
        try ProviderConnectionAccounts.move(second.id, offset: -1, provider: "openrouter", keychain: keychain)
        #expect(try ProviderConnectionAccounts.list(provider: "openrouter", keychain: keychain).first?.id == second.id)
        try ProviderConnectionAccounts.remove(second.id, provider: "openrouter", keychain: keychain)
        #expect(try DefaultAgentSupport.key("openrouter", keychain: keychain) == "legacy")
    }

    @Test(arguments: ["openai-codex", "claude-subscription", "xai"])
    func subscriptionsKeepCanonicalAccountAndDiscardLegacyBackups(provider: String) throws {
        let keychain = DefaultAgentKeychainFixture().access
        func credential(_ id: String) -> DefaultAgentCredential {
            var value = DefaultAgentCredential(type: provider == "claude-subscription" ? "native" : "oauth")
            value.accountId = id; value.access = id; value.expires = 9000000000000
            return value
        }
        let first = credential("first"), selected = credential("selected")
        try DefaultAgentSupport.saveOAuth(selected, provider: provider, scope: "global", keychain: keychain)
        let entries: [[String: Any]] = try [("first", first, false), ("selected", selected, true)].map { id, value, chosen in
            ["account": ["id": id, "label": id, "isSelected": chosen],
             "credential": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))]
        }
        try DefaultAgentSupport.saveKey(String(decoding: JSONSerialization.data(withJSONObject: ["entries": entries]), as: UTF8.self),
            provider: "accounts." + provider, keychain: keychain)
        #expect(try ProviderConnectionAccounts.list(provider: provider, keychain: keychain).map(\.id) == ["selected"])
        #expect(try DefaultAgentSupport.oauth(provider, keychain: keychain) == selected)
        let stored = try #require(try DefaultAgentSupport.key("accounts." + provider, keychain: keychain))
        #expect(!stored.contains("first"))
        if provider != "claude-subscription" {
            #expect(throws: (any Error).self) { try ProviderConnectionAccounts.addOAuth(first, provider: provider, keychain: keychain) }
        } else {
            #expect(throws: (any Error).self) { try ProviderConnectionAccounts.addNative(profile: "first", provider: provider, keychain: keychain) }
        }
        try ProviderConnectionAccounts.remove("selected", provider: provider, keychain: keychain)
        #expect(try ProviderConnectionAccounts.borrowedAccounts(provider: provider, keychain: keychain).isEmpty)
        #expect(try DefaultAgentSupport.oauth(provider, keychain: keychain) == nil)
    }

    @Test func accountsEnforceCapAndBorrowWithoutRefreshTokens() throws {
        let keychain = DefaultAgentKeychainFixture().access
        for i in 0..<4 { try ProviderConnectionAccounts.addKey("key-\(i)", provider: "openai", keychain: keychain) }
        #expect(throws: (any Error).self) { try ProviderConnectionAccounts.addKey("fifth", provider: "openai", keychain: keychain) }
        let credential = try JSONDecoder().decode(DefaultAgentCredential.self, from: Data(
            #"{"type":"oauth","access":"access","refresh":"private-refresh","expires":9000000000000,"accountId":"account"}"#.utf8))
        let account = try ProviderConnectionAccounts.addOAuth(credential, provider: "openai-codex", keychain: keychain)
        let borrowed = try #require(ProviderConnectionAccounts.borrowedAccounts(provider: "openai-codex", keychain: keychain).first)
        #expect(borrowed.credential.refresh == "")
        #expect(borrowed.credential.borrowed)
        #expect(borrowed.credential.accountId == "account")
        #expect(!String(decoding: try JSONEncoder().encode(borrowed.credential), as: UTF8.self).contains("private-refresh"))
        #expect(try ProviderConnectionAccounts.credential(account.id, provider: "openai-codex", keychain: keychain)?.refresh == "private-refresh")
        try ProviderConnectionAccounts.remove(account.id, provider: "openai-codex", keychain: keychain)
        var renewed = credential; renewed.access = "late"
        #expect(try !ProviderConnectionAccounts.saveRenewed(renewed, replacing: credential, accountID: account.id, provider: "openai-codex", scope: "global", keychain: keychain))
        #expect(try DefaultAgentSupport.oauth("openai-codex", keychain: keychain) == nil)
    }

    @Test func controlResponsesAreBoundedDuringRead() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 33))
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        #expect(throws: DefaultAgentError.self) {
            try DefaultAgentControl.readResponse(from: pipe.fileHandleForReading, maximumBytes: 32)
        }
        let valid = Pipe()
        let response = Data("{\"result\":{}}\n".utf8)
        try valid.fileHandleForWriting.write(contentsOf: response)
        try valid.fileHandleForWriting.close()
        defer { try? valid.fileHandleForReading.close() }
        #expect(
            try DefaultAgentControl.readResponse(from: valid.fileHandleForReading, maximumBytes: response.count)
                == response)
    }
    @Test @MainActor func changesDuringRefreshDoNotReturnStaleCredentials() async throws {
        let fixture = CredentialRefreshFixture()
        let revision = CredentialRevisionFixture()
        let coordinator = ProviderAccountCoordinator(
            refresh: { try await fixture.refresh($0) }, version: { revision.current() }, configurationVersion: { 0 }, scopeVersion: { 0 }, reconfigure: { $0 })
        let request = Task { try await coordinator.prepare("local") }
        try await Task.sleep(for: .milliseconds(5))
        revision.advance()
        _ = try await request.value
        #expect(await fixture.count() == 2)
        _ = try await coordinator.prepare("local")
        #expect(await fixture.count() == 2)
    }
}

private final class DefaultAgentKeychainFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    /// Writes to this account fail, as a locked or denied Keychain would.
    var failing: String? {
        get { lock.withLock { failingAccount } }
        set { lock.withLock { failingAccount = newValue } }
    }
    private var failingAccount: String?
    var stored: [String: Data] { lock.withLock { values } }
    var access: KeychainAccess {
        KeychainAccess(
            operations: KeychainOperations(
                copyMatching: { [self] query in
                    lock.withLock {
                        guard let data = values[query[kSecAttrAccount as String] as! String] else {
                            return (errSecItemNotFound, nil)
                        }
                        return (errSecSuccess, data as CFData)
                    }
                },
                getInteractionAllowed: { (errSecSuccess, false) },
                setInteractionAllowed: { _ in errSecSuccess },
                update: { [self] query, attributes in
                    lock.withLock {
                        let account = query[kSecAttrAccount as String] as! String
                        if account == failingAccount { return errSecInteractionNotAllowed }
                        guard values[account] != nil else { return errSecItemNotFound }
                        values[account] = attributes[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                add: { [self] attributes in
                    lock.withLock {
                        if attributes[kSecAttrAccount as String] as? String == failingAccount { return errSecInteractionNotAllowed }
                        values[attributes[kSecAttrAccount as String] as! String] =
                            attributes[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                delete: { [self] query in
                    lock.withLock {
                        if query[kSecAttrAccount as String] as? String == failingAccount { return errSecInteractionNotAllowed }
                        values.removeValue(forKey: query[kSecAttrAccount as String] as! String)
                        return errSecSuccess
                    }
                }
            ))
    }
}

extension DefaultAgentCredentialTests {
    @Test func signOutAndReplacementAccountsWinOverLateRenewal() throws {
        let keychain = DefaultAgentKeychainFixture().access
        var original = DefaultAgentCredential(type: "oauth")
        original.access = "original"
        original.refresh = "original-refresh"
        var renewed = original
        renewed.access = "renewed"
        renewed.refresh = "rotated-refresh"
        try DefaultAgentSupport.saveOAuth(
            original, provider: "xai", scope: "fixture", notify: false, keychain: keychain)
        #expect(
            try DefaultAgentSupport.saveRenewedOAuth(
                renewed, replacing: original, provider: "xai", scope: "fixture", keychain: keychain))
        #expect(try DefaultAgentSupport.oauth("xai", scope: "fixture", keychain: keychain) == renewed)
        // An old response cannot overwrite a newer sign-in.
        #expect(
            try !DefaultAgentSupport.saveRenewedOAuth(
                original, replacing: original, provider: "xai", scope: "fixture", keychain: keychain))
        try DefaultAgentSupport.saveKey("", provider: "oauth.xai", scope: "fixture", notify: false, keychain: keychain)
        #expect(
            try !DefaultAgentSupport.saveRenewedOAuth(
                renewed, replacing: original, provider: "xai", scope: "fixture", keychain: keychain))
        #expect(try DefaultAgentSupport.oauth("xai", scope: "fixture", keychain: keychain) == nil)
    }
}

extension DefaultAgentCredentialTests {
    @Test func interruptedAccountSelectionNeverReassignsSecretsToAnotherIdentity() throws {
        let keychain = DefaultAgentKeychainFixture().access
        let first = try ProviderConnectionAccounts.addKey("first", provider: "openai", keychain: keychain)
        let second = try ProviderConnectionAccounts.addKey("second", provider: "openai", keychain: keychain)
        let encoded = try #require(try DefaultAgentSupport.key("accounts.openai", keychain: keychain))
        var transaction = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let previous = try #require(transaction["entries"] as? [[String: Any]])
        var next = previous
        for index in next.indices {
            var account = next[index]["account"] as! [String: Any]
            account["isSelected"] = account["id"] as? String == second.id
            next[index]["account"] = account
        }
        transaction["entries"] = next
        transaction["pendingPreviousEntries"] = previous
        try DefaultAgentSupport.saveKey(String(decoding: JSONSerialization.data(withJSONObject: transaction), as: UTF8.self), provider: "accounts.openai", keychain: keychain)
        // Simulate interruption before the canonical write: recover the old
        // selection, retaining both secrets under their original identities.
        let accounts = try ProviderConnectionAccounts.list(provider: "openai", keychain: keychain)
        #expect(accounts.first(where: \.isSelected)?.id == first.id)
        #expect(try ProviderConnectionAccounts.credential(first.id, provider: "openai", keychain: keychain)?.key == "first")
        #expect(try ProviderConnectionAccounts.credential(second.id, provider: "openai", keychain: keychain)?.key == "second")
    }
}


extension DefaultAgentCredentialTests {
    @Test func chatSettingsInheritanceDoesNotChooseCredentials() throws {
        let keychain = DefaultAgentKeychainFixture().access
        let device = try ProviderConnectionAccounts.addKey("device-key", provider: "openai", label: "Device", keychain: keychain)
        // A legacy per-workspace account is never read: sign-ins are the device's own.
        _ = try ProviderConnectionAccounts.addKey("workspace-key", provider: "openai", scope: "local", label: "Local", keychain: keychain)
        let fallback = try ProviderConnectionAccounts.addKey("router-key", provider: "openrouter", label: "Router", keychain: keychain)
        var settings = DefaultAgentSettingsScope()
        settings.global.models = ["openai/shared-model"]
        let inherited = try DefaultAgentSupport.snapshot(workspace: "local", settings: settings, keychain: keychain)
        #expect(inherited.config.models == settings.global.models)
        #expect(inherited.credentialAccounts?["openai"]?.map(\.id) == [device.id])
        #expect(inherited.credentials["openai"]?.key == "device-key")
        settings.workspaces["local"] = settings.global
        settings.workspaces["local"]?.models = ["openai/local-model"]
        let independent = try DefaultAgentSupport.snapshot(workspace: "local", settings: settings, keychain: keychain)
        #expect(independent.config.models == ["openai/local-model"])
        #expect(independent.credentials == inherited.credentials)
        #expect(independent.credentialAccounts == inherited.credentialAccounts)
        #expect(independent.credentialAccounts?["openrouter"]?.first?.id == fallback.id)
        #expect(independent.unlockKey == nil)
    }

    @Test func anotherDevicesWorkspaceGetsItsChatSettingsWithoutCredentials() throws {
        var settings = DefaultAgentSettingsScope()
        settings.global.models = ["openai/shared-model"]
        let payload = try DefaultAgentSupport.configurationPayload(workspace: "fixture-remote", settings: settings)
        #expect(payload.config.models == ["openai/shared-model"])
        #expect(payload.credentials.isEmpty && payload.credentialAccounts == nil && payload.unlockKey == nil)
        #expect(payload.revision?.count == 64)
        let body = String(decoding: try payload.data(), as: UTF8.self)
        #expect(!body.contains("credentialAccounts") && !body.contains("unlockKey"))
    }

    private func oauth(_ id: String) -> DefaultAgentCredential {
        var value = DefaultAgentCredential(type: "oauth"); value.access = id; value.refresh = id + "-refresh"; value.accountId = id; value.expires = 9000000000000
        return value
    }
    private func keys(_ provider: String, _ scope: String, _ keychain: KeychainAccess) throws -> [String?] {
        try ProviderConnectionAccounts.list(provider: provider, scope: scope, keychain: keychain).map {
            try ProviderConnectionAccounts.credential($0.id, provider: provider, scope: scope, keychain: keychain)?.key
        }
    }

    @Test func migrationKeepsWhatThisMacUsedFirstForEveryKindOfProvider() throws {
        let fixture = DefaultAgentKeychainFixture(), keychain = fixture.access
        let remote = "0f0e0d0c-0b0a-4908-8706-050403020100"
        // API keys in both scopes: the local ones were used first, the device ones follow.
        _ = try ProviderConnectionAccounts.addKey("shared-key", provider: "openai", label: "Shared", keychain: keychain)
        _ = try ProviderConnectionAccounts.addKey("shared-backup", provider: "openai", label: "Shared backup", keychain: keychain)
        _ = try ProviderConnectionAccounts.addKey("local-backup", provider: "openai", scope: "local", label: "Local backup", keychain: keychain)
        let localPrimary = try ProviderConnectionAccounts.addKey("local-key", provider: "openai", scope: "local", label: "Local", keychain: keychain)
        try ProviderConnectionAccounts.select(localPrimary.id, provider: "openai", scope: "local", keychain: keychain)
        _ = try ProviderConnectionAccounts.addKey("shared-key", provider: "openai", scope: "local", label: "Duplicate", keychain: keychain)
        // OpenRouter's device key is the Usage item.
        _ = try ProviderConnectionAccounts.addKey("router-shared", provider: "openrouter", keychain: keychain)
        _ = try ProviderConnectionAccounts.addKey("router-local", provider: "openrouter", scope: "local", keychain: keychain)
        // Subscriptions in both scopes: one slot, so the local one is used and the device one is kept aside.
        _ = try ProviderConnectionAccounts.addOAuth(oauth("device-chatgpt"), provider: "openai-codex", keychain: keychain)
        _ = try ProviderConnectionAccounts.addOAuth(oauth("local-chatgpt"), provider: "openai-codex", scope: "local", keychain: keychain)
        _ = try ProviderConnectionAccounts.addOAuth(oauth("local-grok"), provider: "xai", scope: "local", keychain: keychain)
        _ = try ProviderConnectionAccounts.addNative(profile: "default", provider: "claude-subscription", label: "Shared Claude", keychain: keychain)
        _ = try ProviderConnectionAccounts.addNative(profile: "local-profile", provider: "claude-subscription", scope: "local", label: "Local Claude", keychain: keychain)
        // Copies held for a Linux host stay until that host reports its own vault.
        _ = try ProviderConnectionAccounts.addKey("remote-key", provider: "openai", scope: remote, keychain: keychain)
        try DefaultAgentSupport.saveKey("vault-key", provider: "encryption-key", scope: remote, notify: false, keychain: keychain)

        try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain)

        #expect(try ProviderConnectionAccounts.list(provider: "openai", keychain: keychain).map(\.label) == ["Local", "Local backup", "Duplicate", "Shared backup"])
        #expect(try ProviderConnectionAccounts.list(provider: "openai", keychain: keychain).first?.isSelected == true)
        #expect(try DefaultAgentSupport.key("openai", keychain: keychain) == "local-key")
        #expect(try keys("openrouter", "global", keychain) == ["router-local", "router-shared"])
        #expect(try DefaultAgentSupport.key("openrouter", keychain: keychain) == "router-local")
        #expect(try DefaultAgentSupport.oauth("openai-codex", keychain: keychain)?.refresh == "local-chatgpt-refresh")
        #expect(try DefaultAgentSupport.oauth("xai", keychain: keychain)?.refresh == "local-grok-refresh")
        let claude = try ProviderConnectionAccounts.list(provider: "claude-subscription", keychain: keychain)
        #expect(claude.map(\.label) == ["Local Claude"])
        #expect(try ProviderConnectionAccounts.nativeProfile(claude[0].id, provider: "claude-subscription", keychain: keychain) == "local-profile")
        // The device subscriptions that no longer fit are kept, refresh token and profile marker included.
        let preserved = ProviderConnectionAccounts.preservedScope
        #expect(try DefaultAgentSupport.oauth("openai-codex", scope: preserved, keychain: keychain)?.refresh == "device-chatgpt-refresh")
        #expect(try ProviderConnectionAccounts.list(provider: "openai-codex", scope: preserved, keychain: keychain).count == 1)
        let keptClaude = try ProviderConnectionAccounts.list(provider: "claude-subscription", scope: preserved, keychain: keychain)
        #expect(try keptClaude.map { try ProviderConnectionAccounts.nativeProfile($0.id, provider: "claude-subscription", scope: preserved, keychain: keychain) } == ["default"])
        // Local items go only once all of them read back from the device list.
        for provider in ["openai", "openrouter", "openai-codex", "xai", "claude-subscription"] {
            #expect(try ProviderConnectionAccounts.list(provider: provider, scope: "local", keychain: keychain).isEmpty)
            #expect(try DefaultAgentSupport.key("accounts." + provider, scope: "local", keychain: keychain) == nil)
        }
        #expect(try DefaultAgentSupport.key("openai", scope: remote, keychain: keychain) == "remote-key")
        #expect(try DefaultAgentSupport.key("encryption-key", scope: remote, keychain: keychain) == "vault-key")
        // Running it again changes nothing at all.
        let once = fixture.stored
        try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain)
        #expect(fixture.stored == once)
        #expect(try DefaultAgentSupport.key("openai", keychain: keychain) == "local-key")
    }

    /// Once a host keeps its own vault, what this Mac kept for that workspace (its
    /// subscriptions with their refresh tokens, its keys, the vault key) is moved
    /// aside, read back first, and never deleted.
    @Test func whatThisMacKeptForAnUpdatedHostIsMovedAsideNotDeleted() throws {
        let fixture = DefaultAgentKeychainFixture(), keychain = fixture.access
        let remote = "0f0e0d0c-0b0a-4908-8706-050403020100"
        _ = try ProviderConnectionAccounts.addKey("remote-key", provider: "openai", scope: remote, keychain: keychain)
        _ = try ProviderConnectionAccounts.addOAuth(oauth("workspace-chatgpt"), provider: "openai-codex", scope: remote, keychain: keychain)
        try DefaultAgentSupport.saveKey("vault-key", provider: "encryption-key", scope: remote, notify: false, keychain: keychain)
        _ = try ProviderConnectionAccounts.addKey("device-key", provider: "openai", keychain: keychain)
        let original = fixture.stored.filter { $0.key.hasPrefix(remote + ".") }
        #expect(!original.isEmpty)

        try ProviderConnectionAccounts.setAsideHostCopies(scope: remote, keychain: keychain)

        let aside = ProviderConnectionAccounts.preservedScope(forHost: remote)
        #expect(fixture.stored.keys.allSatisfy { !$0.hasPrefix(remote + ".") })
        for (account, value) in original {
            #expect(fixture.stored[aside + "." + account.dropFirst(remote.count + 1)] == value, "\(account)")
        }
        #expect(try DefaultAgentSupport.oauth("openai-codex", scope: aside, keychain: keychain)?.refresh == "workspace-chatgpt-refresh")
        #expect(try keys("openai", aside, keychain) == ["remote-key"])
        #expect(try DefaultAgentSupport.key("encryption-key", scope: aside, keychain: keychain) == "vault-key")
        #expect(try DefaultAgentSupport.key("openai", keychain: keychain) == "device-key")
        // Again: nothing changes.
        let once = fixture.stored
        try ProviderConnectionAccounts.setAsideHostCopies(scope: remote, keychain: keychain)
        #expect(fixture.stored == once)
        // An item whose copy cannot be written stays where it is.
        let other = "1f0e0d0c-0b0a-4908-8706-050403020100"
        try DefaultAgentSupport.saveKey("other-vault-key", provider: "encryption-key", scope: other, notify: false, keychain: keychain)
        fixture.failing = ProviderConnectionAccounts.preservedScope(forHost: other) + ".encryption-key"
        #expect(throws: (any Error).self) { try ProviderConnectionAccounts.setAsideHostCopies(scope: other, keychain: keychain) }
        fixture.failing = nil
        #expect(try DefaultAgentSupport.key("encryption-key", scope: other, keychain: keychain) == "other-vault-key")
    }

    /// The same subscription account in both scopes: the copy being replaced is
    /// always kept, and a token that can no longer sign in never replaces one that can.
    @Test func aSameAccountSubscriptionKeepsTheTokenThatStillWorks() throws {
        for localDead in [true, false] {
            let fixture = DefaultAgentKeychainFixture(), keychain = fixture.access
            var local = oauth("same-account"); local.access = "local-access"; local.refresh = localDead ? "" : "local-refresh"; local.expires = localDead ? 1 : 9000000000000
            var device = oauth("same-account"); device.access = "device-access"; device.refresh = "device-refresh"
            _ = try ProviderConnectionAccounts.addOAuth(device, provider: "openai-codex", keychain: keychain)
            _ = try ProviderConnectionAccounts.addOAuth(local, provider: "openai-codex", scope: "local", keychain: keychain)

            try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain)

            let used = try DefaultAgentSupport.oauth("openai-codex", keychain: keychain)
            #expect(used?.refresh == (localDead ? "device-refresh" : "local-refresh"), "local dead: \(localDead)")
            #expect(try ProviderConnectionAccounts.list(provider: "openai-codex", keychain: keychain).count == 1)
            // Whatever was in the device slot before is kept, refresh token included.
            #expect(try DefaultAgentSupport.oauth("openai-codex", scope: ProviderConnectionAccounts.preservedScope, keychain: keychain)?.refresh == "device-refresh")
            // And the local token is never lost: in the device list, or still where it was.
            let localNow = try DefaultAgentSupport.oauth("openai-codex", scope: "local", keychain: keychain)
            #expect(localDead ? localNow?.access == "local-access" : localNow == nil)
            let once = fixture.stored
            try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain)
            #expect(fixture.stored == once)
        }
    }

    /// No payload to any host carries this Mac's credentials, account lists or borrowed access.
    @Test func noHostPayloadEverCarriesCredentials() throws {
        let fixture = DefaultAgentKeychainFixture(), keychain = fixture.access
        let scope = "0f0e0d0c-0b0a-4908-8706-050403020100"
        _ = try ProviderConnectionAccounts.addKey("device-key", provider: "anthropic", keychain: keychain)
        _ = try ProviderConnectionAccounts.addKey("workspace-key", provider: "openai", scope: scope, keychain: keychain)
        let payload = try DefaultAgentSupport.configurationPayload(workspace: scope, settings: .init())
        #expect(payload.credentials.isEmpty && payload.credentialAccounts == nil && payload.unlockKey == nil)
        let body = String(decoding: try payload.data(), as: UTF8.self)
        #expect(!body.contains("device-key") && !body.contains("workspace-key"))
    }

    @Test func migrationOverTheKeyCapKeepsEveryKey() throws {
        let fixture = DefaultAgentKeychainFixture(), keychain = fixture.access
        for index in 1...4 { _ = try ProviderConnectionAccounts.addKey("shared-\(index)", provider: "anthropic", keychain: keychain) }
        for index in 1...3 { _ = try ProviderConnectionAccounts.addKey("local-\(index)", provider: "anthropic", scope: "local", keychain: keychain) }
        let before = try keys("anthropic", "global", keychain)

        try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain)

        #expect(try keys("anthropic", "global", keychain) == ["local-1", "local-2", "local-3", "shared-1"])
        #expect(try DefaultAgentSupport.key("anthropic", keychain: keychain) == "local-1")
        // The device keys that no longer fit stay readable, byte for byte, beside it.
        #expect(try keys("anthropic", ProviderConnectionAccounts.preservedScope, keychain) == before)
        #expect(try ProviderConnectionAccounts.list(provider: "anthropic", scope: "local", keychain: keychain).isEmpty)
        let once = fixture.stored
        try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain)
        #expect(fixture.stored == once)
    }

    @Test func migrationThatFailsMidwayLeavesEverySignInInPlace() throws {
        let fixture = DefaultAgentKeychainFixture(), keychain = fixture.access
        _ = try ProviderConnectionAccounts.addKey("shared-key", provider: "openai", keychain: keychain)
        _ = try ProviderConnectionAccounts.addKey("local-key", provider: "openai", scope: "local", keychain: keychain)
        _ = try ProviderConnectionAccounts.addOAuth(oauth("device-grok"), provider: "xai", keychain: keychain)
        _ = try ProviderConnectionAccounts.addOAuth(oauth("local-grok"), provider: "xai", scope: "local", keychain: keychain)
        // The Keychain refuses the device's Grok slot part-way through.
        fixture.failing = "global.oauth.xai"
        #expect(throws: (any Error).self) { try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain) }
        // Nothing was lost: Grok is unchanged in both scopes, and what was moved is in the device list.
        #expect(try DefaultAgentSupport.oauth("xai", keychain: keychain)?.refresh == "device-grok-refresh")
        #expect(try DefaultAgentSupport.oauth("xai", scope: "local", keychain: keychain)?.refresh == "local-grok-refresh")
        #expect(try ProviderConnectionAccounts.list(provider: "xai", scope: "local", keychain: keychain).count == 1)
        #expect(Set(try keys("openai", "global", keychain).compactMap { $0 } + (try keys("openai", "local", keychain).compactMap { $0 })) == ["shared-key", "local-key"])
        // Retried at the next start, it completes.
        fixture.failing = nil
        try ProviderConnectionAccounts.migrateToDeviceSignIns(keychain: keychain)
        #expect(try DefaultAgentSupport.oauth("xai", keychain: keychain)?.refresh == "local-grok-refresh")
        #expect(try DefaultAgentSupport.oauth("xai", scope: ProviderConnectionAccounts.preservedScope, keychain: keychain)?.refresh == "device-grok-refresh")
        #expect(try keys("openai", "global", keychain) == ["local-key", "shared-key"])
        #expect(try ProviderConnectionAccounts.list(provider: "xai", scope: "local", keychain: keychain).isEmpty)
    }
}
#endif
