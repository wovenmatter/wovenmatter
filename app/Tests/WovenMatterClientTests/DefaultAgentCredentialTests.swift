import Foundation
import Security
import Testing
@testable import WovenMatterClient
import WovenMatterCore

private actor CredentialRefreshFixture {
    var calls = 0
    var fail = false
    func refresh(_ scopes: [String]) async throws -> [String: DefaultAgentPayload] {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        if fail { throw DefaultAgentError.message("Fixture unavailable") }
        return Dictionary(uniqueKeysWithValues: scopes.map {
            ($0, DefaultAgentPayload(config: .init(), credentials: ["openai": .init(type: "api_key", key: "fixture-secret")], workspace: $0))
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

@Suite("Default Agent credential coordination")
struct DefaultAgentCredentialTests {
    @Test @MainActor func healthyMessageChecksNeverReloadCredentials() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = DefaultAgentCredentialCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
        let first = try await coordinator.prepare("local")
        for _ in 0..<100 {
            let current = try await coordinator.prepare("local")
            #expect(current.revision == first.revision)
        }
        #expect(await fixture.count() == 1)
    }
    @Test @MainActor func simultaneousMessagesShareOneRefresh() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = DefaultAgentCredentialCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<12 { group.addTask { try await coordinator.prepare("local").revision } }
            var values: [String?] = []
            for try await value in group { values.append(value) }
            #expect(Set(values.compactMap { $0 }).count == 1)
        }
        #expect(await fixture.count() == 1)
    }
    @Test @MainActor func changesDuringRefreshDoNotReturnStaleCredentials() async throws {
        let fixture = CredentialRefreshFixture(), revision = CredentialRevisionFixture()
        let coordinator = DefaultAgentCredentialCoordinator(refresh: { try await fixture.refresh($0) }, version: { revision.current() })
        let request = Task { try await coordinator.prepare("local") }
        try await Task.sleep(for: .milliseconds(5))
        revision.advance()
        _ = try await request.value
        #expect(await fixture.count() == 2)
        _ = try await coordinator.prepare("local")
        #expect(await fixture.count() == 2)
    }
    @Test func borrowedExportsNeverContainRefreshTokens() throws {
        let data = Data(#"{"type":"oauth","access":"fixture-access","refresh":"owner-secret","expires":9000000000000,"accountId":"fixture-account"}"#.utf8)
        let credential = try JSONDecoder().decode(DefaultAgentCredential.self, from: data)
        let export = credential.borrowing()
        #expect(export.borrowed)
        #expect(export.refresh == "")
        #expect(export.accountId == "fixture-account")
        #expect(!String(decoding: try JSONEncoder().encode(export), as: UTF8.self).contains("owner-secret"))
    }
    @Test @MainActor func revisionsAreStableWhenCredentialsDoNotChange() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = DefaultAgentCredentialCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
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
        KeychainAccess(operations: KeychainOperations(
            copyMatching: { [self] query in lock.withLock {
                guard let data = values[query[kSecAttrAccount as String] as! String] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data as CFData)
            } },
            getInteractionAllowed: { (errSecSuccess, false) },
            setInteractionAllowed: { _ in errSecSuccess },
            update: { [self] query, attributes in lock.withLock {
                let account = query[kSecAttrAccount as String] as! String
                guard values[account] != nil else { return errSecItemNotFound }
                values[account] = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            } },
            add: { [self] attributes in lock.withLock {
                values[attributes[kSecAttrAccount as String] as! String] = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            } },
            delete: { [self] query in lock.withLock {
                values.removeValue(forKey: query[kSecAttrAccount as String] as! String)
                return errSecSuccess
            } }
        ))
    }
}

extension DefaultAgentCredentialTests {
    @Test func signOutAndReplacementAccountsWinOverLateRenewal() throws {
        let keychain = DefaultAgentKeychainFixture().access
        var original = DefaultAgentCredential(type: "oauth")
        original.access = "original"; original.refresh = "original-refresh"
        var renewed = original; renewed.access = "renewed"; renewed.refresh = "rotated-refresh"
        try DefaultAgentSupport.saveOAuth(original, provider: "xai", scope: "fixture", notify: false, keychain: keychain)
        #expect(try DefaultAgentSupport.saveRenewedOAuth(renewed, replacing: original, provider: "xai", scope: "fixture", keychain: keychain))
        #expect(try DefaultAgentSupport.oauth("xai", scope: "fixture", keychain: keychain) == renewed)
        // An old response cannot overwrite a newer sign-in.
        #expect(try !DefaultAgentSupport.saveRenewedOAuth(original, replacing: original, provider: "xai", scope: "fixture", keychain: keychain))
        try DefaultAgentSupport.saveKey("", provider: "oauth.xai", scope: "fixture", notify: false, keychain: keychain)
        #expect(try !DefaultAgentSupport.saveRenewedOAuth(renewed, replacing: original, provider: "xai", scope: "fixture", keychain: keychain))
        #expect(try DefaultAgentSupport.oauth("xai", scope: "fixture", keychain: keychain) == nil)
    }
    @Test @MainActor func endingAnOldSignInCannotReleaseANewerSignIn() async throws {
        let fixture = CredentialRefreshFixture()
        let coordinator = DefaultAgentCredentialCoordinator(refresh: { try await fixture.refresh($0) }, version: { 0 })
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
