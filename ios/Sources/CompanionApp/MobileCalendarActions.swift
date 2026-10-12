import Foundation
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  func readLocalCalendar(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult? {
    guard let store else { return nil }
    switch request {
    case .calendar(let from, let to): return .calendar(try await store.calendar.events(from: from, to: to))
    case .scheduledTasks: return .scheduledTasks(await store.calendar.scheduledTasks())
    default: return nil
    }
  }
  func performLocalCalendar(_ action: CompanionWorkspaceAction) async -> Bool? {
    guard let store else { return nil }
    do {
      switch action {
      case .saveCalendar(let id, let revision, let draft):
        let previous = await store.calendar.record(id: id)
        let owner = previous?.ownerDeviceID ?? (draft.task?.workspaceID == deviceWorkspaceID ? state.deviceID : nil)
        _ = try await store.calendar.save(id: id, expectedRevision: revision, draft: draft, ownerDeviceID: owner)
      case .deleteCalendar(let id, let revision, let occurrence):
        try await store.calendar.delete(id: id, expectedRevision: revision, occurrence: occurrence)
      default: return nil
      }
      errorMessage = nil; await reload()
      if online { Task { await refresh() } }
      return true
    } catch { errorMessage = error.localizedDescription; return false }
  }
  func resolveCalendarConflict(_ id: String, keepLocal: Bool, copyID: String) async -> Bool {
    guard let calendar = store?.calendar else { return false }
    do {
      if keepLocal, let conflict = await calendar.conflicts()[id], conflict.remote?.deleted == true {
        _ = try await calendar.save(id: copyID, expectedRevision: nil, draft: conflict.local.event.draft,
          ownerDeviceID: conflict.local.ownerDeviceID, requestID: copyID)
        try await calendar.resolveConflict(id: id, keepLocal: false)
      } else { try await calendar.resolveConflict(id: id, keepLocal: keepLocal) }
      errorMessage = nil; await reload()
      if online { Task { await refresh() } }
      return true
    } catch { errorMessage = error.localizedDescription; return false }
  }
}
