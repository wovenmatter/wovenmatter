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
    @Test @MainActor func healthyMessageChecksNeverReloadCredentials() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = ProviderAccountCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
        let first = try await coordinator.prepare("local")
        for _ in 0..<100 {
            let current = try await coordinator.prepare("local")
            #expect(current.revision == first.revision)
        }
        #expect(await fixture.count() == 1)
    }
    @Test @MainActor func simultaneousMessagesShareOneRefresh() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = ProviderAccountCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<12 { group.addTask { try await coordinator.prepare("local").revision } }
            var values: [String?] = []
            for try await value in group { values.append(value) }
            #expect(Set(values.compactMap { $0 }).count == 1)
        }
        #expect(await fixture.count() == 1)
    }
    @Test @MainActor func changesDuringRefreshDoNotReturnStaleCredentials() async throws {
        let fixture = CredentialRefreshFixture()
        let revision = CredentialRevisionFixture()
        let coordinator = ProviderAccountCoordinator(
            refresh: { try await fixture.refresh($0) }, version: { revision.current() })
        let request = Task { try await coordinator.prepare("local") }
        try await Task.sleep(for: .milliseconds(5))
        revision.advance()
        _ = try await request.value
        #expect(await fixture.count() == 2)
        _ = try await coordinator.prepare("local")
        #expect(await fixture.count() == 2)
    }
    @Test @MainActor func rejectedAccessSharesOneRenewalAcrossConsumers() async throws {
        let fixture = RejectedCredentialFixture()
        let coordinator = ProviderAccountCoordinator(
            refresh: { await fixture.snapshot($0) },
            renewRejected: { try await fixture.renew($0, access: $1) }, version: { 0 })
        _ = try await coordinator.prepare("global")
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<12 {
                group.addTask { try await coordinator.renewRejectedAccess(provider: "xai", access: "old")?.access }
            }
            for try await access in group { #expect(access == "new") }
        }
        #expect(await fixture.renewals == 1)
        #expect(try await coordinator.prepare("local").credentials["xai"]?.access == "new")
        // A late failure from the former token cannot refresh the new account.
        #expect(try await coordinator.renewRejectedAccess(provider: "xai", access: "old")?.access == "new")
        #expect(await fixture.renewals == 1)
    }
    @Test func borrowedExportsNeverContainRefreshTokens() throws {
        let data = Data(
            #"{"type":"oauth","access":"fixture-access","refresh":"owner-secret","expires":9000000000000,"accountId":"fixture-account"}"#
                .utf8)
        let credential = try JSONDecoder().decode(DefaultAgentCredential.self, from: data)
        let export = credential.borrowing()
        #expect(export.borrowed)
        #expect(export.refresh == "")
        #expect(export.accountId == "fixture-account")
        #expect(!String(decoding: try JSONEncoder().encode(export), as: UTF8.self).contains("owner-secret"))
    }
    @Test @MainActor func revisionsAreStableWhenCredentialsDoNotChange() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = ProviderAccountCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
        let first = try await coordinator.prepare("local")
        coordinator.invalidate()
        let second = try await coordinator.prepare("local")
        #expect(first.revision == second.revision)
        #expect(await fixture.count() == 2)
    }
}

private final class DefaultAgentKeychainFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
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
                        guard values[account] != nil else { return errSecItemNotFound }
                        values[account] = attributes[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                add: { [self] attributes in
                    lock.withLock {
                        values[attributes[kSecAttrAccount as String] as! String] =
                            attributes[kSecValueData as String] as? Data
                        return errSecSuccess
                    }
                },
                delete: { [self] query in
                    lock.withLock {
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
    @Test @MainActor func endingAnOldSignInCannotReleaseANewerSignIn() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = ProviderAccountCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
        _ = try await coordinator.prepare("local")
        let old = try await coordinator.beginSignIn()
        coordinator.endSignIn(old)
        let new = try await coordinator.beginSignIn()
        coordinator.endSignIn(old)
        _ = try await coordinator.prepare("local")
        #expect(await fixture.count() == 1)
        coordinator.endSignIn(new)
        _ = try await coordinator.prepare("local")
        #expect(await fixture.count() == 2)
    }
}

private actor RejectedCredentialFixture {
    var access = "old"
    private(set) var renewals = 0
    func snapshot(_ scopes: [String]) -> [String: DefaultAgentPayload] {
        var credential = DefaultAgentCredential(type: "oauth")
        credential.access = access
        credential.expires = 9_000_000_000_000
        return Dictionary(
            uniqueKeysWithValues: scopes.map {
                ($0, DefaultAgentPayload(config: .init(), credentials: ["xai": credential], workspace: $0))
            })
    }
    func renew(_ provider: String, access: String) async throws {
        #expect(provider == "xai")
        #expect(access == "old")
        renewals += 1
        try await Task.sleep(for: .milliseconds(20))
        self.access = "new"
    }
}

extension DefaultAgentCredentialTests {
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
    @Test func accountsEnforceCapAndBorrowWithoutRefreshTokens() throws {
        let keychain = DefaultAgentKeychainFixture().access
        for i in 0..<4 { try ProviderConnectionAccounts.addKey("key-\(i)", provider: "openai", keychain: keychain) }
        #expect(throws: (any Error).self) { try ProviderConnectionAccounts.addKey("fifth", provider: "openai", keychain: keychain) }
        var credential = DefaultAgentCredential(type: "oauth")
        credential.access = "access"; credential.refresh = "private-refresh"; credential.accountId = "account"
        let account = try ProviderConnectionAccounts.addOAuth(credential, provider: "openai-codex", keychain: keychain)
        let borrowed = try #require(ProviderConnectionAccounts.borrowedAccounts(provider: "openai-codex", keychain: keychain).first)
        #expect(borrowed.credential.refresh == "")
        #expect(borrowed.credential.borrowed)
        #expect(try ProviderConnectionAccounts.credential(account.id, provider: "openai-codex", keychain: keychain)?.refresh == "private-refresh")
        try ProviderConnectionAccounts.remove(account.id, provider: "openai-codex", keychain: keychain)
        var renewed = credential; renewed.access = "late"
        #expect(try !ProviderConnectionAccounts.saveRenewed(renewed, replacing: credential, accountID: account.id, provider: "openai-codex", scope: "global", keychain: keychain))
        #expect(try DefaultAgentSupport.oauth("openai-codex", keychain: keychain) == nil)
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
