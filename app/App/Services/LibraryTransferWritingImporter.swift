import CompanionClient
import Foundation
import WovenMatterCore
import WovenMatterDashboardStore

/// Import the destination node's unacknowledged writing into staging without
/// acknowledging or changing its live replica. An aborted transfer leaves that
/// exact outbox, immutable journal, schedule receipts and saved files intact.
enum LibraryTransferWritingImporter {
    static func merge(store: MobileStore, database: WorkspaceDatabase, transferID: String) async throws {
        let state = await store.snapshot(), history = await store.journal.snapshot()
        let identity = try await database.companionLibraryIdentity()
        // A returning former central already retains its own native sessions in
        // this database. Their journal must not turn them into foreign sessions.
        let allOwned = history.workspaces.values.filter { WorkspaceJournal.isLocalExecutionOwner($0, deviceID: state.deviceID) }
        let owned = allOwned.filter { $0.ownerDeviceID != identity.hostDeviceID }
        let ownedIDs = Set(allOwned.map(\.id)), journalOwnedIDs = Set(owned.map(\.id))
        let registered = try await database.companionExecutionWorkspaces()
        for var workspace in owned {
            workspace.libraryID = identity.libraryID
            let prior = registered.first { $0.id == workspace.id }
            workspace.revision = prior?.revision ?? 0
            _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: prior?.revision), deviceID: identity.hostDeviceID)
        }
        var recoveredFolders: [String: String] = [:]
        for entry in state.outbox {
            let receipt = try await database.applyCompanionMutation(entry.mutation)
            if receipt.status != .accepted, let note = state.notes[entry.mutation.resourceID] {
                var recovered = note
                if let folder = note.folderID, let copy = recoveredFolders[folder] { recovered.folderID = copy }
                try await recoverNote(recovered, database: database, deviceID: state.deviceID, transferID: transferID)
            } else if receipt.status != .accepted, let folder = state.folders[entry.mutation.resourceID] {
                let id = LibraryTransferSQLite.recoveryID(transferID: transferID, table: "pending-folder", id: folder.id)
                _ = try await database.applyCompanionMutation(.init(deviceID: state.deviceID, kind: .createFolder, resourceID: id,
                    title: folder.name + " (recovered local folder)", folderExecution: folder.execution))
                recoveredFolders[folder.id] = id
            }
        }
        for conflict in state.conflicts.values { try await recoverNote(conflict.local, database: database, deviceID: state.deviceID, transferID: transferID) }
        let entries = history.entries.values.filter { journalOwnedIDs.contains($0.workspaceID) }.sorted {
            $0.workspaceID == $1.workspaceID ? $0.originSequence < $1.originSequence : $0.workspaceID < $1.workspaceID
        }
        var batch: [CompanionJournalEntry] = [], bytes = 0
        for raw in entries {
            let encoded = try JSONEncoder().encode(raw)
            let normalized = try state.workspaceID.map { try CompanionLibraryJSON.rewrite(encoded, from: $0, to: identity.libraryID) } ?? encoded
            let entry = try JSONDecoder().decode(CompanionJournalEntry.self, from: normalized)
            if batch.count == CompanionFederationProtocol.maximumBatchEntries || bytes + normalized.count > 7 * 1_024 * 1_024 {
                _ = try await database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: batch), deviceID: state.deviceID)
                batch = []; bytes = 0
            }
            batch.append(entry); bytes += normalized.count
        }
        if !batch.isEmpty { _ = try await database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: batch), deviceID: state.deviceID) }
        for mutation in await store.calendar.libraryTransferMutations() {
            let receipt = try await database.companionCalendarMutate(mutation, deviceID: state.deviceID)
            if receipt.status != .accepted {
                try await recoverCalendar(mutation.record, database: database, deviceID: state.deviceID, transferID: transferID)
            }
        }
        for conflict in await store.calendar.conflicts().values { try await recoverCalendar(conflict.local, database: database, deviceID: state.deviceID, transferID: transferID) }
        let runs = await store.calendar.pendingRuns()
        for index in stride(from: 0, to: runs.count, by: 200) {
            _ = try await database.companionCalendarPublishRuns(Array(runs[index..<min(index + 200, runs.count)]), deviceID: state.deviceID)
        }
        for record in try await store.dictations.pending() { try await database.saveDictation(record) }
        for original in await store.artifacts.manifests() where ownedIDs.contains(original.workspaceID) && !original.deleted {
            guard let file = await store.artifacts.localURL(id: original.id) else { continue }
            var manifest = original
            var prior = try await database.companionArtifactTransfer(id: manifest.id)
            if let existing = prior?.manifest {
                var comparable = manifest; comparable.revision = existing.revision
                if comparable != existing {
                    manifest.id = LibraryTransferSQLite.recoveryID(transferID: transferID, table: "pending-artifact", id: original.id)
                    manifest.title += " (recovered local artifact)"
                    prior = try await database.companionArtifactTransfer(id: manifest.id)
                }
            }
            var transfer = try await database.registerCompanionArtifact(.init(manifest: manifest, expectedRevision: prior?.manifest.revision), deviceID: state.deviceID)
            if !transfer.complete {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(transfer.nextOffset))
                while transfer.nextOffset < transfer.manifest.byteCount {
                    guard let data = try handle.read(upToCount: CompanionFederationProtocol.maximumArtifactChunkBytes), !data.isEmpty else {
                        throw CompanionAPIError(code: "artifact_incomplete", message: "A locally saved artifact is incomplete. Its original has been retained.")
                    }
                    transfer = try await database.appendCompanionArtifactChunk(.init(id: manifest.id, revision: transfer.manifest.revision, offset: transfer.nextOffset, data: data), deviceID: state.deviceID)
                }
                _ = try await database.commitCompanionArtifact(.init(id: manifest.id, revision: transfer.manifest.revision), deviceID: state.deviceID)
            }
        }
    }
    private static func recoverNote(_ note: CompanionNote, database: WorkspaceDatabase, deviceID: String, transferID: String) async throws {
        let id = LibraryTransferSQLite.recoveryID(transferID: transferID, table: "pending-note", id: note.id)
        if try await database.companionNote(id: id) != nil { return }
        let folders = try await database.companionSnapshot(bodyByteBudget: 0).folders
        let folder = note.folderID.flatMap { id in folders.contains(where: { $0.id == id }) ? id : nil }
        _ = try await database.applyCompanionMutation(.init(deviceID: deviceID, kind: .createNote, resourceID: id,
            folderID: folder, title: note.title + " (recovered local writing)", content: note.content))
    }
    private static func recoverCalendar(_ record: CompanionCalendarRecord, database: WorkspaceDatabase, deviceID: String, transferID: String) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let content = String(decoding: try encoder.encode(record), as: UTF8.self)
        let note = CompanionNote(id: LibraryTransferSQLite.recoveryID(transferID: transferID, table: "calendar-writing", id: record.id),
            title: "Calendar conflict: " + record.event.draft.title, content: try NoteDocument(blocks: [.richText(.init(text: content))]).encoded(), revision: 0)
        try await recoverNote(note, database: database, deviceID: deviceID, transferID: transferID)
    }
}
