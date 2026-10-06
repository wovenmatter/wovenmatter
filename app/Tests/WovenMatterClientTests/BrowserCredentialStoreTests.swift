import Foundation
import Security
import Testing
@testable import WovenMatterClient

struct BrowserCredentialStoreTests {
  @Test func savesUpdatesAndReloadsWithoutPrompting() throws {
    let fixture = BrowserKeychainFixture()
    let first = fixture.store()
    try first.prepare(consented: true)
    try first.save(origin: "https://example.com", username: "alice", password: "fixture-one")
    try first.save(origin: "https://example.com", username: "bob", password: "fixture-two")
    try first.save(origin: "https://example.com", username: "alice", password: "fixture-updated")
    let restarted = fixture.store()
    try restarted.prepare(consented: true)
    let passwords = try restarted.savedPasswords(for: "https://example.com")
    #expect(passwords.map(\.username) == ["alice", "bob"])
    #expect(passwords.first?.password == "fixture-updated")
    #expect(try restarted.savedPasswords(for: "https://other.example.com").isEmpty)
    #expect(try restarted.savedPasswords(for: "https://example.com:8443").isEmpty)
    let production = fixture.store(scope: "production")
    try production.prepare(consented: true)
    #expect(try production.savedPasswords(for: "https://example.com").isEmpty)
    #expect(fixture.interactiveCalls == 0)
  }

  @Test func consentAndDenialNeverCreateReplacementSecrets() throws {
    let fixture = BrowserKeychainFixture()
    let store = fixture.store()
    #expect(throws: BrowserCredentialStore.AccessError.self) { try store.prepare(consented: false) }
    #expect(fixture.reads == 0)
    fixture.readStatus = errSecInteractionNotAllowed
    #expect(throws: BrowserCredentialStore.AccessError.self) { try store.prepare(consented: true) }
    #expect(fixture.writes == 0)
    #expect(fixture.interactiveCalls == 0)
  }

  @Test func failedSaveKeepsPriorPasswordAndRecoveryReloads() throws {
    let fixture = BrowserKeychainFixture()
    let store = fixture.store()
    try store.prepare(consented: true)
    try store.save(origin: "https://example.com", username: "alice", password: "original")
    fixture.writeStatus = errSecInteractionNotAllowed
    #expect(throws: BrowserCredentialStore.AccessError.self) {
      try store.save(origin: "https://example.com", username: "alice", password: "replacement")
    }
    #expect(try store.savedPasswords(for: "https://example.com").first?.password == "original")
    fixture.writeStatus = errSecSuccess
    try store.prepare(consented: true, authorize: true)
    try store.save(origin: "https://example.com", username: "alice", password: "replacement")
    #expect(try store.savedPasswords(for: "https://example.com").first?.password == "replacement")
  }

  @Test func validatesExactSecureOrigins() {
    #expect(BrowserCredentialStore.origin(for: "https://EXAMPLE.com:443/login?q=1") == "https://example.com")
    #expect(BrowserCredentialStore.origin(for: "https://example.com:8443/login") == "https://example.com:8443")
    #expect(BrowserCredentialStore.origin(for: "http://localhost:8123/login") == "http://localhost:8123")
    for url in ["http://example.com", "https://user:pass@example.com", "data:text/html,x", "about:blank", "file:///tmp/login.html"] {
      #expect(BrowserCredentialStore.origin(for: url) == nil)
    }
  }
}

private final class BrowserKeychainFixture: @unchecked Sendable {
  var values: [String: Data] = ["Chromium Safe Storage|Chromium": Data("synthetic-encryption-secret".utf8)]
  var allowed = true
  var reads = 0
  var writes = 0
  var interactiveCalls = 0
  var readStatus: OSStatus = errSecSuccess
  var writeStatus: OSStatus = errSecSuccess
  func key(_ query: [String: Any]) -> String {
    "\(query[kSecAttrService as String] ?? "")|\(query[kSecAttrAccount as String] ?? "")"
  }
  func store(scope: String = "dev") -> BrowserCredentialStore {
    BrowserCredentialStore(scope: scope, keychain: KeychainAccess(operations: .init(
      copyMatching: { [self] query in
        reads += 1; if allowed { interactiveCalls += 1 }
        if readStatus != errSecSuccess { return (readStatus, nil) }
        return values[key(query)].map { (errSecSuccess, $0 as CFData) } ?? (errSecItemNotFound, nil)
      },
      getInteractionAllowed: { [self] in (errSecSuccess, allowed) },
      setInteractionAllowed: { [self] newValue in allowed = newValue; return errSecSuccess },
      update: { [self] query, attributes in
        writes += 1; if allowed { interactiveCalls += 1 }
        if writeStatus != errSecSuccess { return writeStatus }
        guard values[key(query)] != nil else { return errSecItemNotFound }
        values[key(query)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
      },
      add: { [self] query in
        writes += 1; if allowed { interactiveCalls += 1 }
        if writeStatus != errSecSuccess { return writeStatus }
        guard values[key(query)] == nil else { return errSecDuplicateItem }
        values[key(query)] = query[kSecValueData as String] as? Data
        return errSecSuccess
      },
      delete: { _ in Issue.record("Browser store must not delete credentials"); return errSecParam }
    )))
  }
}
