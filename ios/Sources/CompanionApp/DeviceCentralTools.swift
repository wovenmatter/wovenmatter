import Foundation
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  /// The central endpoint authenticates an imported conversation's execution
  /// owner. Publish that exact local identity before dispatch, including when a
  /// background sync was already past its upload phase when this turn started.
  func publishDeviceToolCaller(_ conversationID: String) async throws {
    guard let engine, let store, executionRecords[conversationID] != nil, !fixture else {
      throw MobileConnectionError.offline
    }
    await flushLocalWrites()
    try await engine.synchronize()
    await reload()
    guard let record = executionRecords[conversationID], record.isTrashed != true else {
      throw DeviceExecutionError.unavailable("This device conversation is no longer available.")
    }
    try await adoptDeviceConversation(record, transcript: nil)
    let initial = await store.journal.snapshot()
    let required = Set(initial.pendingEntries.filter {
      $0.workspaceID == deviceWorkspaceID && $0.conversationID == conversationID && $0.kind == .conversation
    }.map(\.eventID))
    var outstanding = required
    var registration = initial.pendingRegistrations.contains(deviceWorkspaceID)
    var unchangedPasses = 0
    while registration || !outstanding.isEmpty {
      try Task.checkCancellation()
      try await engine.synchronize()
      let current = await store.journal.snapshot()
      let remaining = required.intersection(current.pendingEntries.map(\.eventID))
      let pendingRegistration = current.pendingRegistrations.contains(deviceWorkspaceID)
      if remaining == outstanding && pendingRegistration == registration {
        unchangedPasses += 1
        guard unchangedPasses <= 1 else {
          throw DeviceExecutionError.unavailable("The Mac has not acknowledged this device's conversation yet. Update the Mac app and finish library synchronization before using its tools.")
        }
      } else { unchangedPasses = 0 }
      outstanding = remaining; registration = pendingRegistration
    }
  }
}
