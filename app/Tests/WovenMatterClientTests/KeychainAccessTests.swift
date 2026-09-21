import Foundation
import LocalAuthentication
import Security
import Testing
@testable import WovenMatterClient

@Suite("Noninteractive Keychain access")
struct KeychainAccessTests {
  @Test("reads and writes suppress both legacy and modern UI and restore after failures",
        arguments: [errSecSuccess, errSecAuthFailed])
  func allOperationsAreNoninteractive(status: OSStatus) {
    let fixture = PolicyFixture(operationStatus: status)
    let keychain = KeychainAccess(operations: fixture.operations)
    let query = [kSecAttrAccount as String: "fixture"]

    #expect(keychain.copyMatching(query).0 == status)
    #expect(keychain.update(query, [kSecValueData as String: Data([1])]) == status)
    #expect(keychain.add(query) == status)
    #expect(keychain.delete(query) == status)

    #expect(fixture.calls.count == 4)
    #expect(fixture.calls.allSatisfy { !$0.allowed && $0.contextDisallowsInteraction })
    #expect(fixture.policyChanges == [false, true, false, true, false, true, false, true])
    #expect(fixture.allowed)
  }

  @Test("explicit operations do not enable an already-disabled interaction policy")
  func explicitAccessPreservesDisabledPolicy() {
    let fixture = PolicyFixture(initiallyAllowed: false)
    let keychain = KeychainAccess(operations: fixture.operations)
    #expect(keychain.copyMatching([:], allowInteraction: true).0 == errSecSuccess)
    #expect(keychain.update([:], [:], allowInteraction: true) == errSecSuccess)
    #expect(keychain.add([:], allowInteraction: true) == errSecSuccess)
    #expect(keychain.delete([:], allowInteraction: true) == errSecSuccess)
    #expect(fixture.calls.count == 4)
    #expect(fixture.calls.allSatisfy { !$0.allowed })
    #expect(fixture.policyChanges.isEmpty)
    #expect(!fixture.allowed)
  }

  @Test("failed policy suppression stops every operation before credential access")
  func suppressionFailureStopsAllOperations() {
    let fixture = PolicyFixture(suppressionStatus: errSecNotAvailable)
    let keychain = KeychainAccess(operations: fixture.operations)
    #expect(keychain.copyMatching([:]).0 == errSecNotAvailable)
    #expect(keychain.update([:], [:]) == errSecNotAvailable)
    #expect(keychain.add([:]) == errSecNotAvailable)
    #expect(keychain.delete([:]) == errSecNotAvailable)
    #expect(fixture.calls.isEmpty)
    #expect(fixture.allowed)
  }

  @Test("restoration failure is returned instead of a successful credential result")
  func restorationFailureIsVisible() {
    let fixture = PolicyFixture(restorationStatus: errSecNotAvailable)
    let keychain = KeychainAccess(operations: fixture.operations)
    let result = keychain.copyMatching([:])
    #expect(result.0 == errSecNotAvailable)
    #expect(result.1 == nil)
    #expect(fixture.calls.count == 1)
    #expect(fixture.policyChanges == [false, true])
    #expect(!fixture.allowed)
  }
}

private final class PolicyFixture: @unchecked Sendable {
  struct Call: Sendable {
    let allowed: Bool
    let contextDisallowsInteraction: Bool
  }
  private let lock = NSLock()
  private var interactionAllowed: Bool
  private var operationCalls: [Call] = []
  private var changes: [Bool] = []
  private let operationStatus: OSStatus
  private let suppressionStatus: OSStatus
  private let restorationStatus: OSStatus

  init(
    initiallyAllowed: Bool = true,
    operationStatus: OSStatus = errSecSuccess,
    suppressionStatus: OSStatus = errSecSuccess,
    restorationStatus: OSStatus = errSecSuccess
  ) {
    interactionAllowed = initiallyAllowed
    self.operationStatus = operationStatus
    self.suppressionStatus = suppressionStatus
    self.restorationStatus = restorationStatus
  }

  var allowed: Bool { lock.withLock { interactionAllowed } }
  var calls: [Call] { lock.withLock { operationCalls } }
  var policyChanges: [Bool] { lock.withLock { changes } }

  var operations: KeychainOperations {
    KeychainOperations(
      copyMatching: { [self] query in (record(query), Data([1]) as CFData) },
      getInteractionAllowed: { [self] in (errSecSuccess, allowed) },
      setInteractionAllowed: { [self] value in
        lock.withLock {
          changes.append(value)
          let status = value ? restorationStatus : suppressionStatus
          if status == errSecSuccess { interactionAllowed = value }
          return status
        }
      },
      update: { [self] query, _ in record(query) },
      add: { [self] query in record(query) },
      delete: { [self] query in record(query) }
    )
  }

  private func record(_ query: [String: Any]) -> OSStatus {
    lock.withLock {
      operationCalls.append(Call(
        allowed: interactionAllowed,
        contextDisallowsInteraction:
          (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
      ))
      return operationStatus
    }
  }
}
