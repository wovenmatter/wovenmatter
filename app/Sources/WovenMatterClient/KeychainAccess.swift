import Foundation
import LocalAuthentication
import Security

/// System operations are injectable so tests never need the user's Keychain.
public struct KeychainOperations: Sendable {
  public let copyMatching: @Sendable ([String: Any]) -> (OSStatus, CFTypeRef?)
  public let getInteractionAllowed: @Sendable () -> (OSStatus, Bool)
  public let setInteractionAllowed: @Sendable (Bool) -> OSStatus
  public let update: @Sendable ([String: Any], [String: Any]) -> OSStatus
  public let add: @Sendable ([String: Any]) -> OSStatus
  public let delete: @Sendable ([String: Any]) -> OSStatus

  public init(
    copyMatching: @escaping @Sendable ([String: Any]) -> (OSStatus, CFTypeRef?) = { query in
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      return (status, result)
    },
    getInteractionAllowed: @escaping @Sendable () -> (OSStatus, Bool) = {
      var allowed = DarwinBoolean(false)
      let status = SecKeychainGetUserInteractionAllowed(&allowed)
      return (status, allowed.boolValue)
    },
    setInteractionAllowed: @escaping @Sendable (Bool) -> OSStatus = {
      SecKeychainSetUserInteractionAllowed($0)
    },
    update: @escaping @Sendable ([String: Any], [String: Any]) -> OSStatus = {
      SecItemUpdate($0 as CFDictionary, $1 as CFDictionary)
    },
    add: @escaping @Sendable ([String: Any]) -> OSStatus = {
      SecItemAdd($0 as CFDictionary, nil)
    },
    delete: @escaping @Sendable ([String: Any]) -> OSStatus = {
      SecItemDelete($0 as CFDictionary)
    }
  ) {
    self.copyMatching = copyMatching
    self.getInteractionAllowed = getInteractionAllowed
    self.setInteractionAllowed = setInteractionAllowed
    self.update = update
    self.add = add
    self.delete = delete
  }
}

/// Noninteractive by default, including the legacy macOS login Keychain.
/// Interactive calls must come directly from an explicit credential action.
public struct KeychainAccess: Sendable {
  // Legacy login-keychain operations ignore LAContext's per-query UI policy.
  // The legacy setting is process-wide: every app Keychain call shares this
  // lock, and suppression covers only the synchronous system operation.
  private static let interactionLock = NSLock()
  private let operations: KeychainOperations

  public init(operations: KeychainOperations = KeychainOperations()) {
    self.operations = operations
  }

  public func copyMatching(
    _ query: [String: Any],
    allowInteraction: Bool = false
  ) -> (OSStatus, CFTypeRef?) {
    withInteractionPolicy(allowInteraction, failure: { ($0, nil) }) {
      operations.copyMatching(authenticationQuery(query, allowInteraction: allowInteraction))
    }
  }

  public func update(
    _ query: [String: Any],
    _ attributes: [String: Any],
    allowInteraction: Bool = false
  ) -> OSStatus {
    withInteractionPolicy(allowInteraction, failure: { $0 }) {
      operations.update(authenticationQuery(query, allowInteraction: allowInteraction), attributes)
    }
  }

  public func add(
    _ attributes: [String: Any],
    allowInteraction: Bool = false
  ) -> OSStatus {
    withInteractionPolicy(allowInteraction, failure: { $0 }) {
      operations.add(authenticationQuery(attributes, allowInteraction: allowInteraction))
    }
  }

  public func delete(
    _ query: [String: Any],
    allowInteraction: Bool = false
  ) -> OSStatus {
    withInteractionPolicy(allowInteraction, failure: { $0 }) {
      operations.delete(authenticationQuery(query, allowInteraction: allowInteraction))
    }
  }

  private func withInteractionPolicy<Result>(
    _ allowInteraction: Bool,
    failure: (OSStatus) -> Result,
    operation: () -> Result
  ) -> Result {
    Self.interactionLock.withLock {
      // Never enable a policy disabled by the caller or another subsystem.
      if allowInteraction { return operation() }
      let (policyStatus, wasAllowed) = operations.getInteractionAllowed()
      guard policyStatus == errSecSuccess else { return failure(policyStatus) }
      let suppressionStatus = operations.setInteractionAllowed(false)
      guard suppressionStatus == errSecSuccess else { return failure(suppressionStatus) }
      let result = operation()
      // The operation is synchronous and nonthrowing. Restore the exact
      // previous setting even when the Keychain operation itself failed.
      let restorationStatus = operations.setInteractionAllowed(wasAllowed)
      guard restorationStatus == errSecSuccess else { return failure(restorationStatus) }
      return result
    }
  }

  private func authenticationQuery(
    _ query: [String: Any],
    allowInteraction: Bool
  ) -> [String: Any] {
    guard !allowInteraction else { return query }
    let context = LAContext()
    context.interactionNotAllowed = true
    var query = query
    query[kSecUseAuthenticationContext as String] = context
    return query
  }
}
