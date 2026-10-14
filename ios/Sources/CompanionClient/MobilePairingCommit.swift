import Foundation

/// Durable local setup precedes remote enrollment. A saved pending credential
/// resumes the same commit after a process exit or a lost confirmation response.
public enum MobilePairingCommit {
  @MainActor public static func complete(_ paired: MobileCredential, store: MobileStore,
    allowingLibraryChange: Bool = false,
    saveCredential: (MobileCredential) throws -> Void,
    confirm: () async throws -> Void) async throws -> MobileCredential {
    guard paired.deviceID == (await store.snapshot()).deviceID else { throw MobileConnectionError.invalidResponse }
    if !allowingLibraryChange { try await store.verifyWorkspace(paired.workspaceID) }
    if paired.confirmationPending == true { try saveCredential(paired) }
    try await store.prepareForPairing(paired.workspaceID)
    if paired.confirmationPending == true { try await confirm() }
    var committed = paired; committed.confirmationPending = nil
    try saveCredential(committed)
    return committed
  }
}
