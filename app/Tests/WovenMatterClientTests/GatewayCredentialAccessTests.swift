import CryptoKit
import Foundation
import Security
import Testing
@testable import WovenMatterClient

@Suite("Gateway credential access")
struct GatewayCredentialAccessTests {
  @Test func openClawReconnectsReuseCredentialsAndSkipUnchangedWrites() throws {
    let value = OpenClawGatewayCredentials(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation, deviceToken: "saved")
    let fixture = CredentialFixture(data: try JSONEncoder().encode(value))
    let store = OpenClawGatewayKeychain(service: "fixture", keychain: fixture.access)
    for _ in 0..<20 {
      #expect(try store.credentials(for: "scope") == value)
      try store.save(value, for: "scope")
    }
    #expect(try store.authorizeCredentials(for: "scope") == value)
    #expect(fixture.readCount == 1)
    #expect(fixture.writeCount == 0)
    #expect(fixture.interactiveReads == 0)
  }

  @Test func deniedOpenClawReadDoesNotRotateIdentityOrRepeatUntilExplicitRetry() throws {
    let value = OpenClawGatewayCredentials(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    let fixture = CredentialFixture(data: try JSONEncoder().encode(value))
    fixture.readStatus = errSecInteractionNotAllowed
    let store = OpenClawGatewayKeychain(service: "fixture", keychain: fixture.access)
    for _ in 0..<10 {
      #expect(throws: (any Error).self) { try store.credentials(for: "scope") }
    }
    #expect(fixture.readCount == 1)
    #expect(fixture.writeCount == 0)
    fixture.readStatus = errSecSuccess
    #expect(try store.authorizeCredentials(for: "scope") == value)
    #expect(try store.credentials(for: "scope") == value)
    #expect(fixture.readCount == 2)
    #expect(fixture.interactiveReads == 1)
  }

  @Test func firstOpenClawIdentityCreationAndTokenRotationRemainSilent() throws {
    let fixture = CredentialFixture(data: nil)
    let store = OpenClawGatewayKeychain(service: "fixture", keychain: fixture.access)
    var value = try store.credentials(for: "new-scope")
    let identity = value.privateKey
    value.deviceToken = "new-token"
    try store.save(value, for: "new-scope")
    #expect(try store.credentials(for: "new-scope").privateKey == identity)
    try store.save(value, for: "new-scope")
    #expect(fixture.readCount == 1)
    #expect(fixture.writeCount == 3) // failed update + add, then one rotation update
    #expect(fixture.interactiveReads == 0 && fixture.interactiveWrites == 0)
  }

  @Test func failedTokenPersistenceRetainsIdentityForAnExplicitRetry() throws {
    let initial = OpenClawGatewayCredentials(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation, deviceToken: "old")
    let fixture = CredentialFixture(data: try JSONEncoder().encode(initial))
    let store = OpenClawGatewayKeychain(service: "fixture", keychain: fixture.access)
    var updated = try store.credentials(for: "scope")
    updated.deviceToken = "rotated"
    fixture.writeStatus = errSecInteractionNotAllowed
    #expect(throws: (any Error).self) { try store.save(updated, for: "scope") }
    for _ in 0..<10 {
      #expect(throws: (any Error).self) { try store.credentials(for: "scope") }
    }
    #expect(fixture.readCount == 1 && fixture.writeCount == 1)
    fixture.writeStatus = errSecSuccess
    #expect(try store.authorizeCredentials(for: "scope") == updated)
    #expect(try store.credentials(for: "scope") == updated)
    #expect(updated.privateKey == initial.privateKey)
    #expect(fixture.interactiveWrites == 1)
  }

  @Test func remoteReadsAreCachedAndDeniedAccessRequiresExplicitRetry() async throws {
    let fixture = CredentialFixture(data: Data("saved-token".utf8))
    let store = RemoteWorkspaceCredentialStore(keychain: fixture.access)
    let id = UUID()
    for _ in 0..<10 { #expect(try await store.token(for: id) == "saved-token") }
    #expect(fixture.readCount == 1 && fixture.interactiveReads == 0)
    await store.clearCachedTokens()
    fixture.readStatus = errSecInteractionNotAllowed
    for _ in 0..<10 {
      await #expect(throws: RemoteWorkspaceClientError.self) { try await store.token(for: id) }
    }
    #expect(fixture.readCount == 2)
    fixture.readStatus = errSecSuccess
    #expect(try await store.authorizeToken(for: id) == "saved-token")
    #expect(try await store.token(for: id) == "saved-token")
    #expect(fixture.readCount == 3 && fixture.interactiveReads == 1)
    try await store.save(token: "replacement", for: id)
    #expect(try await store.token(for: id) == "replacement")
    try await store.deleteToken(for: id, allowInteraction: false)
    #expect(try await store.token(for: id) == nil)
    #expect(fixture.interactiveWrites == 1) // explicit save, never rollback deletion
  }
}

/// In-memory operations: these tests never create or read real Keychain items.
private final class CredentialFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private var allowed = true
  private var reads = 0, writes = 0, allowedReads = 0, allowedWrites = 0
  private var readResult: OSStatus = errSecSuccess
  private var writeResult: OSStatus = errSecSuccess
  init(data: Data?) { self.data = data }
  var readCount: Int { lock.withLock { reads } }
  var writeCount: Int { lock.withLock { writes } }
  var interactiveReads: Int { lock.withLock { allowedReads } }
  var interactiveWrites: Int { lock.withLock { allowedWrites } }
  var readStatus: OSStatus {
    get { lock.withLock { readResult } }
    set { lock.withLock { readResult = newValue } }
  }
  var writeStatus: OSStatus {
    get { lock.withLock { writeResult } }
    set { lock.withLock { writeResult = newValue } }
  }
  var access: KeychainAccess {
    KeychainAccess(operations: KeychainOperations(
      copyMatching: { [self] _ in lock.withLock {
        reads += 1
        if allowed { allowedReads += 1 }
        guard readResult == errSecSuccess else { return (readResult, nil) }
        return data.map { (errSecSuccess, $0 as CFData) } ?? (errSecItemNotFound, nil)
      } },
      getInteractionAllowed: { [self] in lock.withLock { (errSecSuccess, allowed) } },
      setInteractionAllowed: { [self] value in lock.withLock { allowed = value; return errSecSuccess } },
      update: { [self] _, attributes in lock.withLock {
        recordWrite()
        guard writeResult == errSecSuccess else { return writeResult }
        guard data != nil else { return errSecItemNotFound }
        data = attributes[kSecValueData as String] as? Data
        return errSecSuccess
      } },
      add: { [self] attributes in lock.withLock {
        recordWrite()
        guard writeResult == errSecSuccess else { return writeResult }
        data = attributes[kSecValueData as String] as? Data
        return errSecSuccess
      } },
      delete: { [self] _ in lock.withLock {
        recordWrite()
        guard writeResult == errSecSuccess else { return writeResult }
        data = nil
        return errSecSuccess
      } }
    ))
  }
  private func recordWrite() {
    writes += 1
    if allowed { allowedWrites += 1 }
  }
}
