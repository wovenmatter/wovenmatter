import Foundation
import LibraryClient
import WovenMatterShared

extension MobileModel {
  func readLocalCalendar(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult? {
    guard let store else { return nil }
    switch request {
    case .calendar(let from, let to): return .calendar(try await store.calendar.events(from: from, to: to))
    case .scheduledTasks:
      let names = Dictionary(executionWorkspaces.map { ($0.id.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
      return .scheduledTasks(await store.calendar.scheduledTasks(workspaceNames: names))
    default: return nil
    }
  }
  func performLocalCalendar(_ action: LibraryWorkspaceAction) async -> Bool? {
    guard let store else { return nil }
    do {
      switch action {
      case .saveCalendar(let id, let revision, let draft):
        let previous = await store.calendar.record(id: id)
        if let previous, let revision, previous.ownerDeviceID == state.deviceID, previous.event.draft.task != nil,
           let task = draft.task, task.workspaceID != deviceWorkspaceID {
          // Earlier builds ran tasks on this phone. Moving one to a Mac or Linux
          // agent replaces it rather than changing its owner in place.
          _ = try await store.calendar.reassign(id: id, expectedRevision: revision, draft: draft)
        } else {
          let owner = previous?.ownerDeviceID ?? (draft.task?.workspaceID == deviceWorkspaceID ? state.deviceID : nil)
          _ = try await store.calendar.save(id: id, expectedRevision: revision, draft: draft, ownerDeviceID: owner)
        }
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
