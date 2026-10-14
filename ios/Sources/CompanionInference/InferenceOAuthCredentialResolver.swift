import Foundation
import CryptoKit

/// Shared per-process refresh coordination. New logins and deletion always beat an in-flight refresh.
public actor InferenceOAuthCredentialResolver {
  public static let shared = InferenceOAuthCredentialResolver()
  private let client: InferenceOAuthClient
  private let now: @Sendable () -> Date
  private struct Refresh { let id: UUID; let task: Task<InferenceOAuthCredential, Error> }
  private var refreshing: [String: Refresh] = [:]
  public init(transport: any InferenceOAuthHTTPTransport = InferenceOAuthURLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
    self.now = now; client = .init(transport: transport, now: now, sleep: { try await Task.sleep(for: .seconds($0)) })
  }
  public func resolve(connection: InferenceConnection, credentials: any InferenceCredentialReading) async throws -> InferenceOAuthCredential {
    guard connection.route == .direct, InferenceOAuthSession.supports(connection.provider) else { throw InferenceOAuthError.unsupportedProvider }
    guard let raw = try await credentials.read(connectionID: connection.id) else { throw InferenceOAuthError.signInRequired }
    let saved = try InferenceOAuthCredential.decode(raw)
    guard saved.provider == connection.provider, saved.accountID == connection.accountID else { throw InferenceOAuthError.accountChanged }
    try Task.checkCancellation()
    if saved.expires > now().timeIntervalSince1970 * 1000 { return saved }
    guard let updating = credentials as? any InferenceCredentialUpdating else { throw InferenceOAuthError.signInRequired }
    let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    let key = updating.credentialStoreID + "\u{0}" + connection.id + "\u{0}" + digest
    let task: Task<InferenceOAuthCredential, Error>, revision: UUID
    if let active = refreshing[key] { task = active.task; revision = active.id }
    else {
      let client = client, now = now
      revision = UUID()
      task = Task {
        // A caller may have read the old item just before another refresh completed.
        // Reuse that exact binding's newer credential instead of spending its old refresh token again.
        guard let current = try await updating.read(connectionID: connection.id) else { throw InferenceOAuthError.credentialChanged }
        if current != raw {
          let newer = try InferenceOAuthCredential.decode(current)
          guard newer.provider == saved.provider, newer.accountID == saved.accountID, newer.bindingID == saved.bindingID,
            newer.expires > now().timeIntervalSince1970 * 1000 else { throw InferenceOAuthError.credentialChanged }
          return newer
        }
        let refreshed = try await client.refresh(saved)
        guard refreshed.provider == saved.provider, refreshed.accountID == saved.accountID, refreshed.bindingID == saved.bindingID else { throw InferenceOAuthError.accountChanged }
        let replacement = try refreshed.serialized()
        guard try await updating.compareAndSwap(connectionID: connection.id, expected: raw, replacement: replacement) else { throw InferenceOAuthError.credentialChanged }
        return refreshed
      }
      refreshing[key] = Refresh(id: revision, task: task)
    }
    do {
      // A single cancelled model request must not abandon a rotating refresh needed by other callers.
      let value = try await task.value
      if refreshing[key]?.id == revision { refreshing[key] = nil }; try Task.checkCancellation()
      guard try await credentials.read(connectionID: connection.id) == value.serialized() else { throw InferenceOAuthError.credentialChanged }
      return value
    } catch { if refreshing[key]?.id == revision { refreshing[key] = nil }; throw error }
  }
}
