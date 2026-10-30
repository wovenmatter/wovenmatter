import Foundation
import WovenMatterCore

extension WorkspaceDatabase {
  /// An authenticated direct execution owner supplied these original events.
  /// A full Mac replica may retain and relay them while the workspace's managing
  /// Mac is offline. Origin identity, sequence and fingerprint stay unchanged.
  /// This method is app-internal orchestration, never an HTTP publishing route.
  public func retainDirectPairedHistory(_ page: CompanionJournalPage, workspace: CompanionExecutionWorkspace) async throws {
    try await write { connection in
      let local = try connection.companionLibraryIdentityUnlocked()
      guard workspace.libraryID != local.libraryID else { return }
      guard page.libraryID == workspace.libraryID, !workspace.deleted,
            let registered = try connection.federationWorkspaceUnlocked(workspace.id),
            registered.libraryID == workspace.libraryID, registered.ownerDeviceID == workspace.ownerDeviceID,
            registered.executionDeviceID == workspace.executionDeviceID,
            page.entries.allSatisfy({ $0.workspaceID == workspace.id }),
            let origin = workspace.executionDeviceID ?? (workspace.kind == .linux ? nil : workspace.ownerDeviceID) else {
        throw CompanionAPIError(code: "wrong_owner", message: "Direct history does not match the registered execution owner.")
      }
      // Only the local envelope namespace changes. Entry bytes and their origin
      // namespace are the exact records validated by the direct transport.
      _ = try connection.ingestCompanionJournal(.init(libraryID: local.libraryID, entries: page.entries), deviceID: origin)
    }
  }
}
