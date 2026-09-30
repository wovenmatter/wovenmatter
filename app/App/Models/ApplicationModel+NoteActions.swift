import AppKit
import Foundation
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    func mutateNote(id: String, mutation: WorkspaceNoteMutation) async throws {
        try beginNoteAction(id: id)
        defer { noteActionIDs.remove(id) }
        guard let store = dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        guard await flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
        try checkNoteActionAdmission()
        let restoring: Bool = if case .restore = mutation { true } else { false }
        let revision = try await store.database.noteActionRevision(id: id, trashed: restoring)
        try checkNoteActionAdmission()
        guard dashboardStore === store else { throw ApplicationModelError.dashboardStoreUnavailable }
        if isBackendFrontend {
            _ = try await sendBackendCommand(.workspaceMutation(.note(id: id, mutation: mutation, expectedRevision: revision)))
        } else {
            try await store.mutateNote(id: id, mutation: mutation, expectedRevision: revision)
        }
        // Keep the admission fence through refresh. Existing write acknowledgements
        // reconcile drafts without adopting a stale response or resetting counters here.
        await refreshWorkspace()
    }

    func trashedNotes() async throws -> [WorkspaceTrashedNote] {
        if isBackendFrontend {
            guard let notes = try await sendBackendCommand(.trashedNotes).trashedNotes else {
                throw WorkspaceNoteMutationError.noteNotFound
            }
            return notes
        }
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        return try await dashboardStore.trashedNotes()
    }

    func exportNote(id: String, format: WorkspaceNoteExportFormat = .standard) async throws -> WorkspaceNoteExport {
        try beginNoteAction(id: id)
        defer { noteActionIDs.remove(id) }
        guard let store = dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        guard await flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
        try checkNoteActionAdmission()
        let revision = try await store.database.noteActionRevision(id: id)
        try checkNoteActionAdmission()
        guard dashboardStore === store else { throw ApplicationModelError.dashboardStoreUnavailable }
        if isBackendFrontend {
            guard let export = try await sendBackendCommand(.exportNote(id: id, format: format, expectedRevision: revision)).noteExport else {
                throw WorkspaceNoteMutationError.noteNotFound
            }
            return export
        }
        return try await store.exportNote(id: id, format: format, expectedRevision: revision)
    }

    private func beginNoteAction(id: String) throws {
        try checkNoteActionAdmission()
        guard !noteActionIDs.contains(id) else { throw WorkspaceNoteActionError.busy }
        // Commit any active text/cell field before closing local edit admission.
        if let window = NSApp.keyWindow, !window.makeFirstResponder(nil) {
            throw ApplicationModelError.noteDraftSaveFailed
        }
        noteActionIDs.insert(id)
    }

    private func checkNoteActionAdmission() throws {
        try Task.checkCancellation()
        guard !noteEditingSuspended, !backendStopping else { throw ApplicationModelError.noteDraftSaveFailed }
    }
}
