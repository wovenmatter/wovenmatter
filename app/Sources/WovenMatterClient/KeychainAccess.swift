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
  /// Only Settings > General's deliberate recovery action enables this scope.
  /// Task-local authorization follows actor calls without authorizing other tasks.
  @TaskLocal public static var isCredentialAuthorizationActive = false
  private static let systemPolicy = KeychainInteractionPolicy(operations: .init())
  private let policy: KeychainInteractionPolicy
  private var operations: KeychainOperations { policy.operations }

  public init() { policy = Self.systemPolicy }
  public init(operations: KeychainOperations) {
    policy = KeychainInteractionPolicy(operations: operations)
  }
  init(policy: KeychainInteractionPolicy) { self.policy = policy }

  /// Suppress unwrapped library calls too (notably Chromium's asynchronous
  /// OSCrypt worker). No Keychain items are read or modified by this operation.
  @discardableResult
  public static func enforceCentralAuthorization() -> OSStatus {
    systemPolicy.enforceCentralAuthorization()
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
    policy.perform(allowInteraction: allowInteraction, failure: failure, operation: operation)
  }

  private func authenticationQuery(
    _ query: [String: Any],
    allowInteraction: Bool
  ) -> [String: Any] {
    guard !policy.allowsInteraction(allowInteraction) else { return query }
    let context = LAContext()
    context.interactionNotAllowed = true
    var query = query
    query[kSecUseAuthenticationContext as String] = context
    return query
  }
}

/// Shared by every system operation; fixtures use an isolated instance.
final class KeychainInteractionPolicy: @unchecked Sendable {
  let operations: KeychainOperations
  private let lock = NSRecursiveLock()
  private var centralized = false
  private var originalInteractionAllowed = false
  private var enforcementFailure: OSStatus?

  init(operations: KeychainOperations) { self.operations = operations }

  func allowsInteraction(_ requested: Bool) -> Bool {
    lock.withLock { requested && (!centralized || KeychainAccess.isCredentialAuthorizationActive) }
  }

  func enforceCentralAuthorization() -> OSStatus {
    lock.withLock {
      if centralized && enforcementFailure == nil { return errSecSuccess }
      centralized = true
      let (status, allowed) = operations.getInteractionAllowed()
      guard status == errSecSuccess else { enforcementFailure = status; return status }
      originalInteractionAllowed = allowed
      let result = operations.setInteractionAllowed(false)
      enforcementFailure = result == errSecSuccess ? nil : result
      return result
    }
  }

  func perform<Result>(allowInteraction: Bool, failure: (OSStatus) -> Result,
                       operation: () -> Result) -> Result {
    lock.withLock {
      if let status = enforcementFailure { return failure(status) }
      let interactive = allowsInteraction(allowInteraction)
      // Preserve the original behavior for clients that do not install the app
      // policy, including tests and command-line entry points.
      if interactive && !centralized { return operation() }
      let (status, prior) = operations.getInteractionAllowed()
      guard status == errSecSuccess else { return failure(status) }
      // Never override a policy that was disabled before Woven installed its own.
      let desired = interactive && originalInteractionAllowed
      let changed = operations.setInteractionAllowed(desired)
      guard changed == errSecSuccess else { return failure(changed) }
      let result = operation()
      let restored = operations.setInteractionAllowed(prior)
      guard restored == errSecSuccess else { return failure(restored) }
      return result
    }
  }
}
